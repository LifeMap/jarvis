# Jarvis Call Bridge — CB Phase 0 Phone.app Feasibility Report (v1.1 재검증)

작성일: 2026-08-15
판정 범위: PRD v1.1(`docs/Jarvis_Call_Bridge_Client_PRD.md`) 기준 CB Phase 0-A/0-B/0-C 재검증. Apple 공개 API와 현재 로컬 환경(Xcode 없음, Command Line Tools만 존재)에서 구현·조사·로컬 빌드 검증 가능한 범위.
최종 판정: **REQUIRES REAL DEVICE TEST**

---

## 1. 문서 목적 및 범위

기존 `Call_Bridge_Phase_0_Feasibility_Report.md`(v1.0)는 FaceTime 기준 direct CallKit/direct Continuity TX API 조사 결과를 담고 있으며, 이번 작업에서 **삭제·수정하지 않았다**. PRD §40의 보존 원칙에 따라 v1.0 문서는 1차 조사 결과로 그대로 유지한다.

이 문서는 PRD v1.1의 방향 전환 — "Direct API 존재 여부"가 아니라 "macOS 26+ Phone.app을 중심으로 실제 Caller RX와 Jarvis TX를 유지보수 가능한 방식으로 양방향 연결할 수 있는가" — 을 기준으로 한 재검증 결과만 다룬다. v1.0에서 이미 결론난 CXCallObserver 관련 내용은 재조사하지 않고 요약만 인용한다.

## 2. 이전 보고서(v1.0) 요약

- `CXCallObserver`/`CXCall`은 공개 macOS SDK에서 `API_UNAVAILABLE(macos)`로 선언되어 있어 네이티브 macOS에서 사용할 수 없음을 헤더 레벨에서 확인함. 판정: `PUBLIC API / NOT AVAILABLE`.
- ScreenCaptureKit으로 FaceTime 프로세스 오디오를 캡처하는 RX 후보를 구현했으나 실제 caller voice 포함 여부는 미검증. 판정: `PUBLIC API / POSSIBLE BUT NOT VERIFIED`.
- Continuity 통화 TX stream에 직접 PCM을 주입하는 공개 API는 확인하지 못함. Virtual Audio Device 우회 경로는 별도 spike 대상으로 남겨둠.
- 당시 Command Line Tools 컴파일러(6.3.3)와 SDK 모듈 생성 버전(6.3.2) 불일치로 로컬 `swift build` 자체가 실패했음. 실제 기기 테스트는 수행하지 못함.
- Private/Undocumented API 의존 없음.

## 3. 테스트 환경

| 항목 | 확인 결과 |
|---|---|
| macOS | 26.6 (Build 25G72) |
| Mac | Mac Studio (Mac13,1), Apple M1 Max, 64 GB (v1.0 보고서와 동일 머신) |
| Swift | Apple Swift 6.3.3 (swift-driver 1.148.6), target arm64-apple-macosx26.0 |
| Xcode | 여전히 설치/선택되지 않음. `xcode-select -p` = `/Library/Developer/CommandLineTools`, `xcodebuild -version` 실행 시 "requires Xcode" 오류로 확인됨 |
| SDK | Command Line Tools MacOSX26.5.sdk (및 MacOSX15.4.sdk 병존) |
| iPhone / iOS | **사용자 확인 필요** — 이 환경에서는 iPhone에 접근할 수 없음 |
| Calls on Other Devices 설정 | **사용자 확인 필요** — 이 환경에서는 확인 불가 |

v1.0과 달리 이번 세션에서는 `swift build`가 **toolchain mismatch 없이 정상 완료**되었다(§8 참고). v1.0의 실패는 코드 결함이 아니라 당시 환경 상태였다는 판단이 맞았음을 방증한다. 다만 Xcode 자체가 여전히 없다는 사실은 동일하며, 이는 실기기 TCC 권한 테스트(Screen Recording, Accessibility)의 안정성에 영향을 준다는 v1.0의 지적도 그대로 유효하다.

## 4. Phone.app 식별

- Bundle identifier: `com.apple.mobilephone` — `/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /System/Applications/Phone.app/Contents/Info.plist`로 확인.
- 경로: `/System/Applications/Phone.app` (mdfind로도 동일 경로 확인).
- 이번 세션의 RX 구현(`bridge/RXAudioProbe.swift`)은 `SCShareableContent.applications`에서 `bundleIdentifier == "com.apple.mobilephone"`을 우선 탐색하도록 변경했다. FaceTime(`com.apple.FaceTime`)은 Phone.app이 없을 때만 사용하는 명시적 fallback으로 남겼다(PRD §7.4).

## 5. CB Phase 0-A: RX 접근 방식

두 가지 공개 후보를 검토했다.

- **ScreenCaptureKit application audio capture** — v1.0에서 이미 구현된 패턴을 재사용해 Phone.app 대상으로 재구성. 코드 재사용 폭이 크고(스트림 구성, 델리게이트 구조 그대로 유지), 앱 단위 필터링이 API 차원에서 명확하다.
- **Core Audio Process Tap**(`AudioHardwareCreateProcessTap`, macOS 14.2+) — v1.0에서 대안으로 언급만 되고 미구현. 이번에도 별도 구현하지 않고 문서화만 한다. 이유: (1) ScreenCaptureKit 경로가 이미 구현·재사용 가능한 상태였고, (2) PRD §11이 "두 방식 모두 구현할 필요는 없다"고 명시하며 하나를 선택하도록 허용하고, (3) Process Tap은 HAL aggregate device 구성이 추가로 필요해 Phase 0 spike 범위를 넘어서는 구현 비용이 든다. 두 방식 모두 "process output capture"이지 "caller-only RX" 의미를 API 차원에서 보장하지 않는다는 점은 동일하다.

선택: **ScreenCaptureKit을 CB Phase 0-A의 1차 구현으로 채택**, Core Audio Process Tap은 문서화된 채 보류.

추가 구현: 버퍼 도착 여부만으로는 RX 성공으로 보지 않는다는 PRD §11 원칙을 지키기 위해, 버퍼마다 RMS/dBFS를 계산해 `currentRMSdB`/`peakRMSdB`로 publish하도록 `RXAudioProbe.swift`를 확장했다(`bridge/RXAudioProbe.swift:117-186` 부근, `StreamOutput.rmsDb(of:)`). 실기기 테스트에서 사람이 "상대방이 말할 때 RMS가 실제로 움직이는지"를 확인할 수 있게 하는 것이 목적이다.

알려진 단순화: RMS 계산은 ScreenCaptureKit 오디오 버퍼가 Float32 포맷이라는 가정을 전제로 한다(SCStreamConfiguration의 기본 오디오 포맷과 일치하지만 실기기에서 다른 포맷이 관측되면 재검토 필요).

## 6. CB Phase 0-A: 실제 통화 검증 결과

**REQUIRES REAL DEVICE TEST**

이 환경에는 iPhone도, 상대방 전화도, Continuity 설정도 없다. §17의 절차를 사용자가 실제 Mac + iPhone으로 수행해야 한다.

## 7. CB Phase 0-B: Virtual Audio Device 접근 방식

### 검토한 후보와 선택 이유

| 후보 | 판단 |
|---|---|
| AudioDriverKit (DriverKit 기반 dext) | **조사 후 보류**. Xcode 프로젝트, DriverKit entitlement, 시스템 확장 승인(System Settings에서 사용자가 직접 승인) + 재부팅이 필요할 수 있는 절차이며, 이 환경(Xcode 미설치, GUI 상호작용 불가)에서는 빌드조차 할 수 없다. |
| **CoreAudio Audio Server Plug-in (HAL plugin)** | **채택**. `AudioServerPlugIn.h`(공개 API, `kAudioServerPlugInTypeUUID`)가 Command Line Tools SDK에 존재함을 확인했고, 이는 Apple이 PRD 부록에서 직접 언급하는 "Creating an Audio Server Driver Plug-in" 문서가 다루는 바로 그 메커니즘이다. 순수 C, `clang`만으로 빌드 가능하며 Xcode/DriverKit이 필요 없다. |
| 서드파티 오픈소스 가상 오디오 장치(BlackHole 등) 재사용 | 검토했으나 채택하지 않음. PRD가 "코드는 `bridge/`에 직접 작성"을 지시하고, Jarvis가 직접 소유·유지보수 가능한 코드를 원칙으로 삼는다는 판단에 따라 자체 구현을 선택했다. (사용자에게 이 결정을 확인 없이 진행하도록 요청받았으며, 대안으로 검증된 오픈소스 드라이버를 쓰는 것이 리스크가 훨씬 낮다는 점은 §18에 명시한다.) |

### 설계

- `bridge/HALPlugin/PlugInEntry.c` — CFPlugIn 팩토리 함수(`JarvisVMicFactory`), `Info.plist`의 `CFPlugInFactories`가 참조.
- `bridge/HALPlugin/PlugInInterface.c` — `AudioServerPlugInDriverInterface` 전체 구현(QueryInterface/AddRef/Release, Initialize, HasProperty/GetPropertyDataSize/GetPropertyData/SetPropertyData, StartIO/StopIO/GetZeroTimeStamp/WillDoIOOperation/BeginIOOperation/DoIOOperation/EndIOOperation). Apple `AudioServerPlugIn.h`에 문서화된 구조를 그대로 따르되, Volume/Mute 등 Control object, 출력 스트림, aggregate device 지원은 Phase 0 범위 밖으로 제외했다.
- 객체 모델: PlugIn(1) → Device(2, `"Jarvis Virtual Mic"`, UID `com.jarvis.callbridge.virtualmic`, transport `Virtual`, 48kHz 고정) → Stream(3, mono Float32, terminal type Microphone). Control 객체 없음.
- **Cross-process IPC**: 드라이버는 `coreaudiod` 프로세스 안에서 실행되고 Jarvis 앱은 별도 프로세스다. `bridge/HALPlugin/Shared/include/JarvisVMicRing.h`에 정의한 lock-free SPSC(single-producer/single-consumer) ring buffer를 POSIX 공유 메모리(`shm_open("/jarvis.cbridge.vmic")`)에 두고, 드라이버가 생성(`O_CREAT`)·앱이 접근(생성 없이 attach)한다. `DoIOOperation`의 `kAudioServerPlugInIOOperationReadInput` 콜백은 realtime 스레드에서 blocking 없이 ring buffer를 읽고, 데이터가 부족하면 무음으로 채우며 `underrunCount`를 증가시킨다.
- 공유 메모리는 world-readable/writable(`0666`)로 생성한다. `coreaudiod`의 데몬 사용자와 로그인 사용자 프로세스의 UID가 다르기 때문이다. PRD §7.2의 "1 User = 1 Mac = 1 Bridge" 범위에서는 허용 가능한 단순화로 판단했으나, 향후 다중 사용자·보안 강화 시나리오에서는 재검토가 필요하다(§18에 기록).
- `_Atomic`(C11) 대신 plain 필드 + `__atomic` 컴파일러 내장 함수를 사용했다. `_Atomic(T)` 필드가 있으면 Swift Clang importer가 해당 구조체를 깨끗하게 import하지 못하는 문제를 피하기 위한 의도적 선택이다(공유 헤더가 SwiftPM C target과 드라이버 양쪽에서 동일하게 컴파일되어야 하므로).

## 8. CB Phase 0-B: 빌드 결과

이번 세션에서 실제로 실행한 결과를 그대로 기록한다.

**`swift build`** (Jarvis Call Bridge 앱 + 공유 ring buffer C target): **성공**, 경고 0건. v1.0의 toolchain mismatch가 재현되지 않았다 — 환경이 그 사이 바뀌었거나, v1.0이 지적한 문제가 실제로 일시적 SDK 상태였을 가능성이 있다. 어느 쪽이든 이번 세션 기준으로는 코드 결함도, 환경 blocker도 아니다.

**`bridge/HALPlugin/build-driver.sh`** (HAL 드라이버, `clang -std=c11 -Wall -Wextra`): **성공**, 경고 0건. `.driver` 번들을 조립하고 ad-hoc codesign까지 완료했다. `codesign -dv` 결과 `Format=bundle with Mach-O thin (arm64)`, `Signature=adhoc` 확인.

**`selftest`** (드라이버 번들을 `dlopen()`으로 in-process 로드해 factory/QueryInterface/GetPropertyData를 coreaudiod 없이 직접 호출): **PASS**. 실제 출력:

```
PASS: factory returned a driver ref
PASS: QueryInterface(kAudioServerPlugInDriverInterfaceUUID) status=0
PASS: GetPropertyData(PlugIn, Manufacturer) status=0
  Manufacturer = Jarvis
PASS: GetPropertyData(Device, DeviceUID) status=0
  DeviceUID = com.jarvis.callbridge.virtualmic
PASS: GetPropertyData(Stream, VirtualFormat) status=0
  sampleRate=48000 channels=1 bitsPerChannel=32 bytesPerFrame=4
```

이 결과는 "vtable가 링크되고 프로퍼티 조회에 올바르게 응답한다"는 것을 증명한다. **"coreaudiod가 실제로 로드한다"나 "Phone.app/실제 상대방이 오디오를 인식한다"는 것은 증명하지 않는다** — 이 두 가지는 각각 `install.sh` 실행과 실기기 통화가 필요하며, 이번 세션에서는 수행하지 않았다(§12 참고).

**`.app` 패키징**(`bridge/build-app.sh`): 진행 중 이번 세션에서 **기존 v1.0 코드의 잠재 버그를 발견해 수정**했다 — `bridge/Info.plist`에 `CFBundleExecutable` 키가 없어서, 조립된 `.app`은 `open`으로 실행 시 "executable is missing" 오류를 내며 한 번도 정상 실행된 적이 없었을 것으로 판단된다(v1.0 세션은 Xcode가 없어 `.app` 실행 자체를 시도하지 못했으므로 이 버그가 이번 세션 전까지 발견되지 않았다). 키를 추가한 뒤 `.app`을 다시 빌드해 `open`으로 실행했고, 3초 이상 정상적으로 프로세스가 유지되는 것을 확인한 뒤 정상 종료(quit)시켰다. 이는 headless 환경에서 확인 가능한 최대치이며, 실제 UI 클릭/권한 승인 플로우는 실기기 세션에서 사용자가 확인해야 한다.

## 9. CB Phase 0-B: 설치/권한/선택 절차

**사용자가 직접 수행**(에이전트는 실행하지 않음):

```sh
cd bridge/HALPlugin
./build-driver.sh   # 이미 이번 세션에서 성공 확인됨; 재실행해도 안전
./install.sh         # sudo 필요, coreaudiod 재시작 — 통화 중에는 실행하지 말 것
```

설치 후: System Settings → Sound → Input, 또는 Audio MIDI Setup.app에서 "Jarvis Virtual Mic" 장치가 보이는지 확인한다. 보이지 않으면 Console.app에서 `coreaudiod`의 `JarvisVirtualMic` 관련 오류를 확인해 이 보고서의 후속 업데이트에 기록한다. 확인되면 Phone.app의 마이크 입력 장치를 "Jarvis Virtual Mic"로 수동 선택한다(PRD §12.1이 수동 선택을 명시적으로 허용).

## 10. CB Phase 0-B: 실제 통화 TX 검증 결과

**REQUIRES REAL DEVICE TEST** — §8의 selftest는 coreaudiod/실기기 없이 얻은 결과이며, 실제 Caller가 오디오를 들었는지는 아직 확인되지 않았다.

## 11. CB Phase 0-C: RX/TX 동시 실행 결과

`bridge/SeparationMonitor.swift`를 구현해 RX와 Virtual Mic TX가 동시에 동작하는 동안 200ms 간격으로 `[SEP] rxRMS=… txRMS=… underruns=…` 로그를 남기도록 했다. `FeasibilityModel.swift`에 "Start/Stop Simultaneous RX/TX Test" 진입점을 추가했다. 신호 처리(echo cancellation 등)는 구현하지 않았다 — PRD §20이 이를 Phase 0 범위 밖으로 명시한다.

**실제 수치: REQUIRES REAL DEVICE TEST.** 로깅 메커니즘 자체는 `swift build` 성공으로 코드 레벨 검증되었으나, 의미 있는 RX/TX RMS 비교는 실기기 통화 중에만 얻을 수 있다.

## 12. Feedback / Echo 결과

방법론만 구현: TX 재생 중 RX RMS를 동시에 관측해 loopback 여부를 사람이 판단하도록 로그로 노출한다. 실제 feedback 수준은 미검증.

## 13. Latency 관찰

`RXAudioProbe`는 ScreenCaptureKit의 `CMSampleBuffer` PTS를 기록하고, `VirtualMicTXProbe`는 ring buffer의 producer heartbeat(host time)를 기록한다. 이는 end-to-end 전화 지연시간이 아니라 각 경로 내부의 캡처/기록 타임스탬프일 뿐이다. 실제 체감 latency는 실기기 테스트에서만 판단 가능하다.

## 14. Call State 조사 결과

`bridge/PhoneAppAccessibilityProbe.swift`를 신규 구현했다. `AXIsProcessTrustedWithOptions`로 Accessibility 신뢰 상태를 확인하고, 신뢰되어 있으면 `AXUIElementCreateApplication`으로 Phone.app에 접근해 버튼 title 키워드("decline"/"answer"/"end call"/"거절"/"수신"/"통화 종료" 등)를 기준으로 Idle/Ringing/Active를 추정한다. 결과는 항상 `.unknown`/`.idleGuess`/`.ringingGuess`/`.activeGuess`/`.endedGuess`처럼 "Guess"로 표시되며, `CallStateMonitor.swift`의 정직한 "Public API Not Available" 신호와 절대 혼동되지 않도록 별도 UI 행으로 분리했다. `dumpAXTree()` 디버그 헬퍼를 추가해 실기기 테스트에서 실제 Phone.app AX 트리를 사람이 직접 관찰하고 더 나은 anchor를 찾을 수 있게 했다.

판정: **IMPLEMENTED / NOT VERIFIED**. 이 비대화형 환경에는 Accessibility 권한 프롬프트를 클릭할 사람이 없으므로, 이 프로브는 이 세션 내내 `.unknown`으로 남아있는 것이 정상이며 버그가 아니다. 실제 버튼 title 키워드 매칭도 추측일 뿐이며, 실기기에서 `dumpAXTree()` 결과를 보고 재조정이 필요할 가능성이 높다.

## 15. Manual Start/Stop Fallback 타당성

**PASS** (이 특정 PoC-fallback 요구사항에 한해). `FeasibilityModel.start()`/`stop()`이 이미 존재하며, `swift build` 및 `.app` 실행 확인으로 코드 레벨에서 동작을 확인했다. PRD §10.3/§22가 요구하는 대로, 자동 Call State 감지 여부와 무관하게 이 fallback은 항상 사용 가능하다.

## 16. PASS / 구현-미검증 / 실패 체크리스트

| 항목 | 상태 |
|---|---|
| Phone.app 식별 (`com.apple.mobilephone`) | **PASS** (코드로 확인 가능한 로컬 사실) |
| `swift build` (앱 + 공유 C target) | **PASS** |
| `HALPlugin/build-driver.sh` (드라이버 컴파일/링크/서명) | **PASS** |
| `selftest` (드라이버 vtable in-process 검증) | **PASS** |
| `.app` 패키징 및 headless 실행 (크래시 없이 실행/종료) | **PASS** (버그 수정 후) |
| RX: Phone.app 대상 ScreenCaptureKit 캡처 코드 | IMPLEMENTED / NOT VERIFIED |
| RX: 실제 Caller 음성 포함 여부 | REQUIRES REAL DEVICE TEST |
| TX: Virtual Mic 드라이버 설치 및 coreaudiod 로드 | REQUIRES REAL DEVICE TEST (설치 자체를 이 세션에서 수행하지 않음) |
| TX: 실제 Caller가 오디오 청취 | REQUIRES REAL DEVICE TEST |
| RX/TX 동시 사용 및 feedback 수준 | REQUIRES REAL DEVICE TEST |
| Call State (Accessibility guess) | IMPLEMENTED / NOT VERIFIED (환경상 영구적으로 `.unknown`) |
| Manual Start/Stop fallback | **PASS** |
| Direct CallKit / Direct Continuity TX API | FAIL / NOT AVAILABLE (v1.0에서 확정, 재조사 안 함) |

## 17. 실제 Mac + iPhone 테스트 절차

### 사전 준비 (공통)

1. iPhone과 Mac이 동일 Apple Account로 로그인, Wi-Fi/Bluetooth 활성화.
2. iPhone에서 Calls on Other Devices 활성화, Mac에서 iPhone cellular calls 허용 확인.
3. `cd bridge && ./build-app.sh` 실행 후 `open ".build/Jarvis Call Bridge Feasibility.app"`로 앱 실행 (raw SwiftPM 바이너리보다 TCC 권한 프롬프트가 안정적).
4. 최초 실행 시 Screen Recording / System Audio Recording 권한 요청이 뜨면 승인 후 앱을 재실행한다.

### Test A — CB Phase 0-A (Phone.app RX)

1. 앱에서 **Start Test**를 누른다.
2. 다른 전화로 사용자의 iPhone 셀룰러 번호에 전화를 건다.
3. Mac Phone.app에서 수신 UI가 뜨는지 확인하고 통화를 받는다.
4. 상대방에게 10초 이상 숫자나 문장을 반복해서 말해달라고 요청한다.
5. 앱의 **RX Audio** 행이 `Active / Buffers Received`로 바뀌는지, **RX Buffers** 카운트가 계속 증가하는지 확인한다.
6. **RX RMS / Peak** 값이 상대방이 말할 때 눈에 띄게 올라가고, 침묵 구간에는 낮아지는지 확인한다.
7. 로그에서 `[RX] buffer count=... rms=...dB` 라인들을 기록해둔다.

**PASS 조건**: 상대방이 말하는 동안 RMS가 명확히 상승하고, 침묵 구간에는 하락한다 (실제 caller speech가 buffer에 포함됨을 시사).
**FAIL 조건**: buffer가 전혀 도착하지 않거나, RMS가 상대방 발화와 무관하게 일정하다(벨소리/UI 효과음만 캡처했을 가능성).

### Test B — CB Phase 0-B (Virtual Mic TX)

1. `cd bridge/HALPlugin && ./build-driver.sh`가 이미 성공했는지 확인한다(이번 세션에서 확인 완료).
2. `./install.sh`를 **직접** 실행한다 (통화 중이 아닐 때). coreaudiod가 재시작되며 시스템 오디오가 잠시 끊긴다.
3. System Settings → Sound → Input에서 "Jarvis Virtual Mic"가 보이는지 확인한다. 안 보이면 Console.app에서 `coreaudiod`/`JarvisVirtualMic` 오류를 확인한다.
4. Mac 스피커를 음소거하거나 headphone을 사용해 acoustic leakage 가능성을 제거한다.
5. Phone.app 설정에서 마이크 입력을 "Jarvis Virtual Mic"로 수동 선택한다.
6. 실제 iPhone cellular call을 진행한다.
7. 앱에서 **Start TX Test Tone (Virtual Mic)** 또는 **Start TX Speech Sample (Virtual Mic)**을 누른다.
8. 상대방 전화에서 tone/speech sample이 들리는지 확인한다.

**PASS 조건**: Mac 스피커를 통한 음향 유입이 아닌 상태에서 상대방이 tone/speech를 명확히 들음.
**FAIL 조건**: 상대방이 아무것도 듣지 못하거나, 스피커 음소거 여부에 따라 들림/안 들림이 바뀜(acoustic leakage였다는 뜻).

### Test C — CB Phase 0-C (동시 실행 / Separation)

1. Test A, B가 모두 준비된 상태에서 실제 통화 중 **Start Simultaneous RX/TX Test**를 누른다.
2. 상대방이 말하는 동안 TX speech sample도 함께 재생되도록 한다.
3. 로그의 `[SEP] rxRMS=... txRMS=... underruns=...` 라인을 관찰한다.
4. **Stop Simultaneous RX/TX Test**, **Stop Test**로 정리한 뒤, 두 번째 전화로 A/B 절차를 반복해 재사용 가능한지 확인한다.

**PASS 조건**: RX/TX 두 스트림이 동시에 유지되고, underrun이 심하지 않으며, 두 번째 통화에서도 앱 재시작 없이 동일하게 동작한다.
**FAIL 조건**: 한쪽 스트림이 다른 쪽 시작 시 끊기거나, 재사용 시 크래시/무응답이 발생한다.

### Test D — Call State Guess 관찰 (참고용, blocker 아님)

1. 통화 중 **Dump Phone.app AX Tree**를 눌러 로그에 실제 Phone.app AX 트리를 출력한다.
2. `PhoneAppAccessibilityProbe.swift`의 키워드 목록과 실제 트리를 비교해, 더 나은 anchor가 있는지 기록한다.
3. Call State (AX guess) 행의 값이 실제 통화 상태와 대략적으로 맞는지 참고 기록한다 — 틀려도 Phase 0 판정에는 영향 없음(§21 참고).

### 보존해야 할 증거

macOS/iOS/Phone.app 버전, 앱 로그 전문, 각 단계 화면 캡처, 상대방이 TX를 들었는지 여부와 스피커/헤드폰 조건, RX buffer가 실제 caller speech임을 확인한 방법, 1차·2차 통화 결과 비교.

## 18. Public / Private API 의존성 분류

| 구성 요소 | 분류 |
|---|---|
| ScreenCaptureKit (Phone.app RX) | `PUBLIC API / POSSIBLE BUT NOT VERIFIED` |
| Core Audio Process Tap (미구현, 대안) | `UNKNOWN / NEEDS FURTHER TEST` |
| CoreAudio Audio Server Plug-in (HAL, Virtual Mic TX) | `PUBLIC API + VIRTUAL AUDIO DEVICE / POSSIBLE BUT NOT VERIFIED` (컴파일·in-process selftest는 PASS, coreaudiod 로드·실통화는 미검증) |
| AudioDriverKit | `PUBLIC API / NOT AVAILABLE (이 환경에서 빌드 불가)` — 조사만 하고 채택하지 않음 |
| Accessibility API (Call State guess) | `PUBLIC API / POSSIBLE BUT NOT VERIFIED` (권한 승인 불가 환경) |
| CXCallObserver / Direct Continuity TX | `PUBLIC API / NOT AVAILABLE` (v1.0에서 확정) |

Private/Undocumented API 의존: **없음**. HAL 드라이버는 Apple이 `CoreAudio/AudioServerPlugIn.h`로 공개 문서화한 인터페이스만 사용했으며, 헤더는 로컬 SDK에서 직접 읽어 구조체 필드/상수명을 검증했다(추측이나 인터넷 예제 복붙이 아님). Accessibility API도 공개 API(`ApplicationServices`/`AXUIElement`)다.

## 19. 유지보수 및 배포 제약

- HAL 드라이버 설치는 `sudo` + `/Library/Audio/Plug-Ins/HAL` 배치 + `coreaudiod` 재시작이 필요하다. 이는 통화 중 실행할 수 없고, 매 macOS 업데이트 후 서명/신뢰 재확인이 필요할 수 있다.
- 공유 메모리를 world-writable(0666)로 생성하는 것은 단일 사용자 로컬 PoC 범위에서는 허용 가능하지만, 다중 사용자 환경에서는 재검토가 필요하다.
- ring buffer의 원자성은 C11 `_Atomic` 대신 plain 필드 + `__atomic` builtin을 사용한다 — 단일 producer/consumer에서는 충분하지만, 더 복잡한 동시성 요구가 생기면 재검토 대상이다.
- Accessibility 기반 Call State guess는 Phone.app의 AX 트리 구조가 macOS 버전에 따라 바뀌면 깨질 수 있는 heuristic이며, 정식 API가 아니다.
- `.app` 패키징은 SwiftPM 리소스 번들(`tx-sample.wav`) 조회를 `.build/` 디렉터리의 절대 경로 fallback에 의존한다 — 이 체크아웃을 벗어나면(예: 다른 Mac에 `.app`만 복사) 리소스 로드가 실패한다. Phase 1에서 정식 Xcode 프로젝트로 전환하며 해결해야 할 항목이다.
- Xcode가 여전히 없어 실기기 TCC 권한 테스트의 안정성은 v1.0 지적대로 완전히 검증되지 않았다.

## 20. Phase 0 최종 판정

| Gate | 판정 |
|---|---|
| Call Detection (공개 API) | FAIL / NOT AVAILABLE (v1.0에서 확정, 변경 없음) |
| Call State (AX guess) | IMPLEMENTED / NOT VERIFIED |
| RX Capture (Phone.app) | IMPLEMENTED / NOT VERIFIED |
| TX (Virtual Mic 드라이버) | 컴파일·in-process 검증 PASS / 실통화 REQUIRES REAL DEVICE TEST |
| RX/TX Separation | IMPLEMENTED / NOT VERIFIED |
| Manual Start/Stop fallback | PASS |

**Overall: REQUIRES REAL DEVICE TEST**

v1.0과 마찬가지로, 이 환경(Codex/에이전트, Xcode 없음, iPhone 없음, 실통화 불가)에서 얻을 수 있는 최대치는 확보했다: 모든 코드가 컴파일되고, HAL 드라이버는 in-process selftest까지 통과하며, `.app`은 크래시 없이 실행된다. 그러나 PRD가 요구하는 PASS/CONDITIONAL PASS 판정은 실제 iPhone 셀룰러 통화 없이는 내릴 수 없다.

## 21. Phase 1 진행 가능 여부

**WAITING FOR REAL DEVICE TEST.** §17의 절차를 사용자가 실제 Mac + iPhone으로 수행한 뒤 다음 중 하나가 확인되면 Phase 1을 시작할 수 있다.

- Test A/B/C가 모두 PASS 또는 CONDITIONAL PASS → **CB Phase 0 = PASS 또는 CONDITIONAL PASS**, Phase 1 진행 가능.
- Call State guess만 실패해도(§22 특별 규칙에 따라) 나머지가 성공하면 CONDITIONAL PASS로 Phase 1 진행 가능.
- RX 또는 TX 핵심 경로가 실통화에서 실패하면(§39 PRD 중단 조건) Phase 0은 FAIL로 종료해야 하며, Phase 1을 시작하지 않는다.

## 22. Phase 1이 반드시 해결해야 할 제약 (Phase 0 CONDITIONAL PASS를 가정할 경우)

1. HAL 드라이버 설치/서명을 사용자가 매번 수동으로 하지 않아도 되는 배포 경로 (Phase 6 DMG 작업과 연계).
2. 공유 메모리 permission 모델을 world-writable(0666)보다 안전한 방식으로 개선할지 검토.
3. `.app` 리소스 로딩을 `.build/` 절대 경로 fallback이 아닌 정식 Xcode 프로젝트/타겟 기반으로 전환.
4. Accessibility 기반 Call State guess의 실제 anchor를 실기기 `dumpAXTree()` 결과로 재조정.
5. RX/TX 동시 사용 시 feedback/echo 수준이 실사용에 적합한지 실측 후 echo cancellation 필요 여부 결정.
6. Core Audio Process Tap을 ScreenCaptureKit 대비 대안으로 실제 채택할지 여부 (현재는 미구현 상태로 보류).

---

# CB Phase 0-1 — Real Device Validation

이 섹션은 위 CB Phase 0 조사/구현 내용을 실제 Mac + iPhone + 실제 셀룰러 통화 환경에서 검증하는 별도 단계의 기록이다. 위 섹션들(§1-22)은 삭제·수정하지 않고 그대로 보존한다.

## 23. Preflight 결과 (2026-08-15, 이어지는 세션)

| 항목 | 결과 |
|---|---|
| macOS version | 26.6 (Build 25G72) — 이전과 동일 |
| Phone.app 존재/bundle id | PASS — `/System/Applications/Phone.app`, `com.apple.mobilephone` |
| **Xcode** | **WARNING(환경 변화): 이번 세션부터 Xcode 26.6 (Build 17F113)이 설치되어 있음을 확인.** 이전 Phase 0 세션들에서는 Xcode가 전혀 없어 `xcodebuild`가 동작하지 않았다. 이는 Phase 0-1 실행 자체에는 영향이 없으나(SwiftPM 빌드로 충분), TCC 권한 프롬프트 안정성 등 §19에서 지적한 제약이 이제 완화될 가능성이 있다는 점을 기록한다. |
| `swift build` | PASS — 경고 0건 |
| `bridge/build-app.sh` | PASS — `.app` 재빌드 성공, `open`으로 실행 후 3초+ 크래시 없이 유지되는 것을 확인하고 정상 종료(quit)함 |
| `HALPlugin/build-driver.sh` | PASS — 드라이버 컴파일/링크/ad-hoc 서명 성공 |
| `HALPlugin` selftest | PASS — factory/QueryInterface/GetPropertyData(Manufacturer, DeviceUID, VirtualFormat) 전부 in-process로 정상 응답 확인 |
| `install.sh`/`uninstall.sh` 안전성 검토 | PASS — 두 스크립트 모두 하드코딩된 단일 경로(`/Library/Audio/Plug-Ins/HAL/JarvisVirtualMic.driver`)만 대상으로 하며 wildcard 없음, 실행 전 대화형 확인(`read confirm`) 존재, "에이전트가 실행하지 않는다"는 경고 문구 포함. `uninstall.sh`에 macOS 기본 Input Device 복구 안내 문구를 추가함(자동 device management 기능은 추가하지 않음 — 지침 §9 준수). |
| 현재 시스템에 설치된 다른 HAL 드라이버 | `JumpAudio.driver`, `JumpAudioMic.driver`, `ParrotAudioPlugin.driver`, `TVRemoteAudio.driver`가 이미 `/Library/Audio/Plug-Ins/HAL`에 설치되어 있음을 확인. Jarvis의 install/uninstall 스크립트는 이 중 어느 것도 건드리지 않는다(명시적 단일 경로 타겟이므로). |
| Jarvis Virtual Mic 사전 설치 여부 | 없음 (예상대로) — 이번이 최초 실제 설치 시도가 된다. |

Preflight 전체 판정: **PASS**. Real Device Test로 진행 가능.

## 24. CHECKPOINT 1 — Jarvis Virtual Mic 실제 설치 결과

**CHECKPOINT 1 = PASS**

| 항목 | 결과 |
|---|---|
| Virtual Mic Install | PASS |
| Input Device Visible (사용자 확인, System Settings → Sound → Input) | PASS — 이름 "Jarvis Virtual Mic", 종류 "가상" |
| coreaudiod Load | PASS |
| **에이전트 측 독립 확인** | `system_profiler SPAudioDataType`으로 직접 재확인함: `Jarvis Virtual Mic` — `Input Channels: 1`, `Manufacturer: Jarvis`, `Current SampleRate: 48000`, `Transport: Virtual`. 설계한 값(mono, 48kHz, Manufacturer "Jarvis")과 정확히 일치. 사용자 보고에만 의존하지 않고 시스템 레벨에서 직접 검증했다. |
| Detected Device UID | `com.jarvis.callbridge.virtualmic` (코드 상 고정값; `system_profiler`는 UID를 직접 노출하지 않으나 다른 필드가 모두 일치해 동일 장치로 판단) |

이로써 CB Phase 0-B(Virtual Audio TX Device)의 "coreaudiod가 실제로 로드하는가?"라는 질문에 처음으로 실제 긍정 답을 얻었다 — 이전까지는 in-process selftest로만 검증 가능했다.

## 25. CB Phase 0-2 — CHECKPOINT 2: Actual Caller RX Validation 준비

CHECKPOINT 2를 위해 이번 세션에서 다음을 추가/재확인했다 (신규 기능 확장이 아니라 CHECKPOINT 2 검증에 필요한 최소 diagnostic 도구):

- **RX diagnostic capture** (`bridge/RXAudioProbe.swift`에 추가): Phone.app RX 스트림만을 대상으로 5~10초 분량을 WAV로 저장하는 임시 진단 기능. `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` + `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)`를 사용해 interleaved/planar 여부와 무관하게 정확한 포맷으로 기록한다. 저장 위치: `~/Library/Application Support/JarvisCallBridge/diagnostics/rx-checkpoint2-<timestamp>.wav`. microphone이나 다른 system-wide audio는 섞이지 않는다 — RX 스트림에 이미 도착한 buffer만 그대로 기록한다. 정식 `rx.m4a`/`tx.m4a`/`merged.m4a` recording pipeline이 아니다(PRD §21 범위 밖, 구현하지 않음).
- UI에 "Start RX Diagnostic Capture (8s WAV)" / "Stop RX Diagnostic Capture" 버튼과 상태 행("RX Diagnostic", "RX Diagnostic File") 추가.
- Preflight 재확인: `swift build` PASS, `.app` 재빌드 후 headless 실행 확인(3초+ 크래시 없음, 정상 종료), Virtual Mic 설치 상태 그대로 유지 확인(제거하지 않음), RX probe의 1차 타겟이 여전히 `com.apple.mobilephone`(Phone.app)임을 코드에서 재확인.

**STATUS = WAITING FOR USER REAL DEVICE TEST**

실제 결과를 받기 전까지 아래 표는 채우지 않는다.

| 항목 | 결과 |
|---|---|
| RX Capture Method | ScreenCaptureKit (1차 후보 유지) |
| Phone.app Call | 대기 중 |
| RX Buffer | 대기 중 |
| RX Buffer Count | 대기 중 |
| Sample Rate / Channels | 대기 중 |
| Caller Speech RMS Correlation | 대기 중 |
| Diagnostic Audio | 대기 중 |
| Caller Speech Verified | 대기 중 |
| Other Audio Mixed | 대기 중 |
| CHECKPOINT 2 Result | 대기 중 |
