# Jarvis Call Bridge — CB Phase 0 Feasibility Report

작성일: 2026-08-15  
판정 범위: Apple 공개 API와 현재 Codex 환경에서 구현·조사 가능한 범위  
최종 판정: **REQUIRES REAL DEVICE TEST**

## 1. 테스트 환경

| 항목 | 확인 결과 |
|---|---|
| macOS | 26.6 (Build 25G72) |
| Mac | Mac Studio (Mac13,1), Apple M1 Max, 64 GB |
| Swift | Apple Swift 6.3.3 |
| Xcode | 설치/선택되지 않음. Command Line Tools만 활성화됨 |
| SDK | Command Line Tools macOS SDK (Swift 6.3.2로 생성) |
| iPhone / iOS | Codex 환경에서 확인 불가 |
| Continuity 설정 | Codex 환경에서 확인 불가 |

현재 Command Line Tools의 컴파일러(6.3.3)와 SDK 모듈 생성 버전(6.3.2)이 일치하지 않아 로컬 빌드는 toolchain mismatch로 중단됐다. 전체 Xcode가 설치된 실제 Mac에서 빌드 검증이 필요하다. 이 실패는 Call Bridge 코드의 기능 판정이 아니라 개발 환경 판정이다.

## 2. 조사한 Apple/macOS 공개 API

### CallKit / `CXCallObserver`

- Apple 문서의 `CXCallObserver`는 active call 변경 관찰 인터페이스다.
- 그러나 설치된 공개 macOS SDK의 `CXCallObserver.h`와 `CXCall.h`는 둘 다 `API_UNAVAILABLE(macos, tvos)`로 선언돼 있다. 지원 대상은 iOS, Mac Catalyst, watchOS이며 네이티브 macOS 앱에서는 사용할 수 없다.
- 따라서 FaceTime 프로세스 또는 창의 존재를 ringing/active/ended로 추정하는 코드는 작성하지 않았다. 그것은 통화 상태 검출이 아니기 때문이다.
- 판정은 `PUBLIC API / NOT AVAILABLE`이다.

참고: [CXCallObserver](https://developer.apple.com/documentation/callkit/cxcallobserver)

### ScreenCaptureKit

- `SCShareableContent`로 실행 중인 FaceTime 앱을 찾고, `SCContentFilter`로 해당 앱을 포함한 뒤 `SCStreamOutputType.audio`의 `CMSampleBuffer`를 받는 공개 경로를 구현했다.
- Apple 문서는 ScreenCaptureKit이 선택한 화면/앱의 오디오를 sample buffer로 제공한다고 명시한다.
- 이 경로는 **FaceTime 프로세스 출력 오디오 캡처**다. 실제 Continuity 통화에서 caller RX가 포함되는지, 벨소리/시스템 효과음과 분리되는지, DRM 또는 시스템 보호로 무음 처리되는지는 실기기에서 확인해야 한다.
- 따라서 현재 판정은 `PUBLIC API / POSSIBLE BUT NOT VERIFIED`다.

참고: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

### Core Audio process tap

- macOS 14.2부터 `AudioHardwareCreateProcessTap`과 `CATapDescription`으로 특정 프로세스 또는 프로세스 그룹의 **outgoing audio**를 캡처할 수 있다.
- Apple 샘플은 tap을 HAL aggregate device의 입력으로 구성하는 방식을 설명한다.
- ScreenCaptureKit RX 실험의 대안이지만, 이 API도 FaceTime이 재생하는 caller audio를 캡처할 가능성만 제공할 뿐 caller-only RX 의미를 보장하지 않는다.
- 판정은 `PUBLIC API / POSSIBLE BUT NOT VERIFIED`다.

참고: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

### AVAudioEngine

- 440 Hz 진단음을 생성하고 기본 출력 장치로 재생하는 데 사용했다.
- 일반 출력 재생은 Mac speaker/headphone 출력이며 Continuity 통화의 송신 입력이 아니다.
- Continuity call TX stream에 직접 buffer를 쓰는 공개 API는 조사한 CallKit, AVFoundation, ScreenCaptureKit, Core Audio 문서에서 확인하지 못했다.
- 별도의 가상 오디오 장치를 만들고 사용자가 그 장치를 FaceTime microphone/input으로 선택하는 경로는 기술적으로 별도 검증할 수 있지만, 이는 직접 Continuity TX API가 아니며 드라이버/라우팅/서명·배포 복잡도가 추가된다.

참고: [Core Audio](https://developer.apple.com/documentation/coreaudio/)

## 3. 구현한 접근 방식

`bridge/`에 직접 다음 책임을 분리한 최소 SwiftUI 앱을 구성했다.

- Call state: macOS 공개 CallKit observer가 없음을 UI와 로그에 명시하는 capability gate
- RX audio: FaceTime 프로세스로 필터링한 ScreenCaptureKit audio sample buffer probe
- TX audio: 로컬 출력 경로가 통화 주입과 다름을 확인하기 위한 1초 440 Hz 진단음
- Orchestration: start/stop과 cleanup
- UI: 상태, buffer count, source process, 로그
- Logging: 실제 buffer의 sample rate, channel count, frame count, audio duration, PTS

앱은 RX buffer가 들어와도 이를 자동으로 Continuity caller RX `PASS`로 표시하지 않는다. TX 진단음 역시 항상 `Local Output Only`로 표시한다.

## 4. Continuity Call Detection 결과

**FAIL / NOT AVAILABLE**

- `CXCallObserver`는 네이티브 macOS에서 명시적으로 unavailable이다.
- 조사한 공개 API에서 Continuity 셀룰러 통화의 ringing/active/ended 또는 caller 정보를 제공하는 대체 인터페이스를 찾지 못했다.
- FaceTime 실행 여부와 window presence는 통화 상태로 취급하지 않는다.

공개 API 분류: **PUBLIC API / NOT AVAILABLE**

## 5. RX Capture 결과

**IMPLEMENTED / NOT VERIFIED**

- FaceTime 실행 프로세스 탐색 구현
- FaceTime 앱으로 필터링한 ScreenCaptureKit audio stream 구현
- 실제 `CMSampleBuffer` 수신 횟수와 포맷/타이밍 로그 구현
- microphone capture나 전체 시스템 audio를 RX 성공으로 취급하지 않음
- 실제 통화의 caller speech가 buffer에 포함되는지는 미검증
- caller audio 외 FaceTime 출력과의 의미적 분리는 미검증

공개 API 분류: **PUBLIC API / POSSIBLE BUT NOT VERIFIED**

## 6. TX Injection 결과

**FAIL / NOT AVAILABLE (direct public API path)**

- 일반 `AVAudioEngine` 출력은 구현했지만 통화 TX 성공으로 취급하지 않는다.
- Continuity 통화의 송신 audio stream에 제3자 앱이 직접 PCM을 주입하는 공개 API는 확인하지 못했다.
- 가상 audio input device를 구현/설치하고 FaceTime input으로 명시적으로 선택하는 우회 경로는 별도 spike 대상이다. 현재 Phase 0 앱에는 driver를 포함하지 않았다.

공개 API 분류: **PUBLIC API / NOT AVAILABLE** — Continuity TX에 대한 직접 API 기준  
대안 분류: **UNKNOWN / NEEDS FURTHER TEST** — 공개 Core Audio driver/virtual-device + 수동 라우팅 기준

## 7. RX/TX Separation 결과

**UNKNOWN / NOT VERIFIED**

- RX 후보는 FaceTime process output capture다.
- TX 직접 주입 경로가 확보되지 않아 독립성, feedback, 동시성, 향후 별도 녹음 및 barge-in 적합성을 판정할 수 없다.
- 실제 virtual input path를 구성한 뒤 RX capture에 TX가 어느 수준으로 재유입되는지 계측해야 한다.

## 8. Call End / Cleanup 결과

**UNVERIFIED / NO CALL-END API**

- 공개 macOS call-ended callback은 구현할 수 없었다.
- ScreenCaptureKit stream stop 및 참조 해제 구현
- AVAudioPlayerNode / AVAudioEngine stop 구현
- Stop Test 후 UI idle 복귀 구현
- ScreenCaptureKit 자체 오류/종료와 수동 Stop Test cleanup은 가능하지만 실제 통화 종료와 연동되지 않는다.

## 9. 실제 iPhone 셀룰러 통화로 검증한 항목

없음. Codex 실행 환경에서는 iPhone, 상대방 전화, Continuity 설정 및 실제 통화 조작을 사용할 수 없다.

## 10. 코드만 구현되고 실제 기기에서 검증되지 않은 항목

- FaceTime 프로세스 audio buffer 수신
- buffer에 caller speech가 실제 포함되는지
- buffer format, callback interval, 체감 latency
- 수동 stop 시 stream cleanup
- 앱 재실행 없이 다음 통화 처리

## 11. 실패한 항목

- 공개 API를 통한 직접 Continuity TX injection 경로를 찾지 못함
- 공개 API를 통한 Continuity call state detection 경로를 찾지 못함
- 현재 머신에서 toolchain/SDK 불일치로 전체 컴파일 검증 실패
- 실제 기기 테스트를 수행하지 못함

## 12. 발견한 Apple/macOS 제약

1. `CXCallObserver`와 `CXCall`은 네이티브 macOS에서 사용할 수 없다.
2. Continuity 셀룰러 call state와 caller 정보를 제3자 macOS 앱에 제공하는 공개 API가 확인되지 않았다.
3. 시스템/프로세스 audio capture는 출력 캡처이며, caller-only RX라는 통화 의미를 보장하지 않는다.
4. system audio capture에는 사용자의 권한 승인이 필요하다.
5. Continuity/FaceTime call input에 직접 PCM을 쓰는 공개 API가 확인되지 않았다.
6. 가상 audio device 방식은 직접 API가 아니고 사용자 라우팅, driver 설치/서명, 장치 전환 및 echo 검증이 필요하다.

## 13. Private/Undocumented API 의존 여부

없음. 구현은 ScreenCaptureKit, AVFoundation, CoreMedia 공개 API만 사용한다. CallKit은 macOS에서 unavailable임을 SDK 헤더로 확인한 후 구현에서 제거했다. Private Framework, hooking, process injection, reverse engineering은 사용하지 않았다.

## 14. 알려진 문제

- Swift Package 실행 파일은 안정적인 TCC 권한 테스트에 불리할 수 있다. 실제 테스트는 전체 Xcode에서 고정 bundle identifier로 서명된 macOS app bundle을 권장한다.
- FaceTime이 실행되지 않으면 RX probe는 시작하지 않는다.
- 첫 system audio/screen capture 권한 승인 후 앱 재시작이 필요할 수 있다.
- 여러 display 환경에서는 첫 display를 filter anchor로 사용한다.
- RX callback timestamp는 capture PTS이며 end-to-end 전화 latency 측정값이 아니다.
- TX 버튼은 기본 출력 진단 전용이다.

## 15. 실제 Mac + iPhone 테스트 절차

### 사전 준비

1. 전체 Xcode를 설치하고 `xcode-select`가 Xcode Developer 디렉터리를 가리키는지 확인한다.
2. iPhone과 Mac이 같은 Apple Account로 로그인되어 있고 Wi-Fi/Bluetooth가 켜져 있는지 확인한다.
3. iPhone의 다른 기기 통화 허용과 Mac FaceTime의 iPhone 통화 설정을 활성화한다.
4. Xcode에서 macOS App target을 만들고 `bridge/`의 Swift 파일과 `Info.plist` usage description을 추가해 서명한다.
5. 앱을 실행하고 System Settings에서 Screen & System Audio Recording 권한을 승인한다. 요구되면 앱을 재실행한다.

### Test A — Call detection limitation confirmation

1. 앱에서 **Start Test**를 누른다.
2. 다른 전화로 iPhone 셀룰러 번호에 전화한다.
3. Mac FaceTime에 수신 UI가 나타나는지 확인한다.
4. 앱이 `[CALL] PUBLIC API / NOT AVAILABLE`을 유지하는지 확인한다.
5. Mac에서 통화를 받는다.

예상 결과: 앱 상태는 `Public API Not Available`을 유지한다. FaceTime UI에는 통화가 보여도 앱은 이를 call state로 오인하지 않는다. Call Detection은 `FAIL / NOT AVAILABLE`이다.

### Test B — Caller RX buffer

1. 통화가 Mac에서 active인 상태를 유지한다.
2. 상대방에게 10초간 숫자를 읽어 달라고 한다.
3. RX 상태가 `Active / Buffers Received`인지 확인한다.
4. 로그의 sample rate, channels, frames, buffer count 증가를 기록한다.
5. 상대방이 말할 때와 침묵할 때 buffer amplitude를 별도 디버그 계측하거나 후속 임시 모니터로 청취해 caller speech 포함 여부를 확인한다.

예상 결과: buffer count가 계속 증가하고 상대방 발화가 buffer에 포함돼야 RX 후보 경로가 확인된다. buffer가 없거나 caller voice가 없으면 RX는 `FAIL`이다. caller voice가 있으나 다른 FaceTime 출력과 분리되지 않으면 `CONDITIONAL` 제약이다.

### Test C — TX injection

1. 통화 중 **Play 1s Diagnostic Tone**을 누른다.
2. 상대방 전화에서 tone이 들리는지 확인한다.
3. Mac speaker의 acoustic coupling으로 들린 것인지 구분하기 위해 Mac 출력 볼륨을 0으로 하거나 headphone을 사용해 반복한다.

예상 결과: 현재 구현은 default output이므로 상대방이 직접 듣지 못하는 것이 정상이다. speaker 음향 유입은 TX PASS가 아니다. 직접 TX는 현재 `FAIL / NOT AVAILABLE`로 유지한다.

### Test D — End and cleanup

1. 상대방 전화에서 통화를 종료한다.
2. 통화 종료만으로 RX stream이 자동 종료되지 않는 제약을 확인한다.
3. **Stop Test**로 resource를 정리한 후 다시 **Start Test**를 누르고 두 번째 전화를 반복한다.

예상 결과: 자동 call-end 감지는 없지만 수동 cleanup 후 두 번째 통화에서 RX buffer probe를 다시 시작할 수 있어야 한다.

### 반드시 보존할 증거

- macOS/iOS/FaceTime 버전과 설정
- 앱 로그 전문
- 각 단계 화면 캡처
- 상대방이 TX를 들었는지 여부와 speaker/headphone 조건
- RX buffer가 caller speech임을 확인한 방법
- 첫 통화와 두 번째 통화 결과

## 16. Phase 0 최종 판정 및 Phase 1 진행 가능 여부

| Gate | 현재 판정 |
|---|---|
| Call Detection | FAIL |
| RX Capture | UNVERIFIED |
| TX Injection | FAIL (direct public API) |
| RX/TX Separation | UNVERIFIED |
| Call End Detection | FAIL |

**Overall: REQUIRES REAL DEVICE TEST**

현재 상태에서는 **Phase 1 진행 불가**다. RX 후보 경로는 실제 통화에서 검증해야 하며, call-state detection과 TX 직접 주입이 공개 API로 제공되지 않는 문제를 해결해야 한다. Phase 1을 열려면 다음이 모두 필요하다.

1. 유지보수 가능한 call-state detection 경로를 증명한다.
2. 유지보수 가능한 공개 API 기반 TX 경로를 실제 통화로 증명하거나, 공개 Core Audio virtual-device 방식의 설치·라우팅·상대방 청취·RX/TX 분리를 별도 spike로 증명하고 그 운영 제약을 수용한다.

둘 다 불가능하면 PRD의 중단 조건에 따라 CB Phase 0은 `FAIL`로 종료해야 한다.
