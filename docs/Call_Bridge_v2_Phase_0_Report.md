# CB v2 Phase 0 — Clean Slate & Architecture Skeleton Report

작성일: 2026-08-15
PRD 기준 버전: v2.1 (`docs/Jarvis_Call_Bridge_Client_PRD.md`)
최종 판정: **REQUIRES REAL DEVICE TEST**

이 문서는 v1.x용 `Call_Bridge_Phase_0_Feasibility_Report.md`, `Call_Bridge_Phase_0_PhoneApp_Feasibility_Report.md`와 별개의 새 문서다. 두 문서 모두 삭제/수정하지 않았다.

## Environment

| 항목 | 값 |
|---|---|
| macOS | 26.6 (Build 25G72) |
| Architecture | arm64 (Apple Silicon) |
| Swift | Apple Swift 6.3.3 (swift-driver 1.148.6) |
| Xcode | 26.6 (Build 17F113) |

## Scope

### 이번 Phase에서 구현한 것

- `bridge/Package.swift`, `bridge/Info.plist` — SwiftPM 실행형 타겟 `JarvisCallBridge`, macOS 14+, `CFBundleIdentifier = com.jarvis.callbridge` (기존 v1 feasibility app `com.jarvis.callbridge.feasibility`와 분리)
- `BridgeState` enum — PRD §8 전체 상태(`disabled`~`error`)를 선언만 하고, Phase 0 runtime에서는 `disabled`/`armed`만 도달 가능
- `BridgeStateMachine` — `allowedTransitions`로 `disabled↔armed`만 허용, 그 외 전이는 거부 후 로그만 남기고 상태 불변. Work Mode 토글이 audio route mutation을 절대 호출하지 않는다는 것을 spy로 테스트 가능하도록 `AudioRouteMutating?` 의존성을 주입받되, production 코드 경로에서는 아무것도 호출하지 않음
- `PhoneAppDiscovery` — `com.apple.mobilephone` 존재/실행 여부를 `NSWorkspace`/`NSRunningApplication` public API로 읽기 전용 관찰. 5초 간격 polling (busy-polling 없음), click/launch/focus 없음
- `AccessibilityStatus` — `AXIsProcessTrusted()` 읽기 전용 확인 + 사용자가 명시적으로 누르는 "Grant Accessibility…" 버튼에서만 `AXIsProcessTrustedWithOptions`로 macOS 표준 권한 프롬프트 요청. `AXUIElementPerformAction` 사용 없음
- `CallControlService` protocol — Phase 2용 placeholder. `answer()` 등 동작 메서드는 선언하지 않음
- `AudioRouteManager.swift` — `AudioRouteSnapshot`(struct), `AudioRouteReading`(읽기 프로토콜) + `CoreAudioRouteReader`(공개 CoreAudio `AudioObjectGetPropertyData`로 default input/output/system-output 및 장치 이름 읽기 전용 조회) + `AudioRouteMutating`(Phase 1+용 placeholder 프로토콜, 어디서도 실제로 호출되지 않음)
- `BridgeViewModel` — 위 컴포넌트들을 UI용으로 조합하는 orchestrator. 오디오/캡처 상태는 전혀 갖지 않음
- `ContentView` (SwiftUI) — Work Mode 토글, Bridge State, Phone.app, Accessibility, Audio Route(Input/Output/System Output), "Call Audio Driver: Not installed — Phase 1", "Realtime: Not implemented — Phase 4", 상태 메시지, 로그 뷰. v1 feasibility UI(`Start Test` 등)는 재사용하지 않고 완전히 새로 작성
- `Scripts/build-app.sh` — `.build/Jarvis Call Bridge.app` 패키징 스크립트 (v1의 `CFBundleExecutable` 누락 버그를 이번엔 처음부터 포함해 방지)
- `Tests/JarvisCallBridgeTests/` — `BridgeStateMachineTests`, `AudioRouteManagerTests`, `PhoneAppDiscoveryTests` (8개 테스트, 아래 참고)

### 의도적으로 구현하지 않은 것 (§2 금지 목록 그대로 준수)

HAL Audio Driver, Jarvis Call Capture/Inject device, Virtual Mic, AudioServerPlugIn, ScreenCaptureKit, system/Phone.app audio capture, AudioUnit 기반 capture, Default Input/Output/System Output 변경, CoreAudio route 변경, POSIX shared memory/mmap, Realtime AI, OpenAI Realtime, STT/TTS, 녹음(rx/tx/merged.m4a), 자동 전화 수신, Accessibility 클릭 액션, Human Takeover, iPhone Handoff automation, Jarvis API Tool Call, R2, Call history backend, SIP/070/Twilio — 전부 코드에 없음.

## v1 코드 재사용 여부

없음. `bridge/`는 작업 시작 시점에 `.swiftpm` IDE 메타데이터만 남아있었고(실제 소스 없음), git 로그상 `02a539e call bridge 최초버전-재개발 예정` 커밋으로 v1이 이미 history에 보존되어 있음을 확인했다. `RXAudioProbe`, `ScreenCaptureKit` 캡처, `JarvisVirtualMic`, `HALPlugin/`, shared memory ring, `Start Test` orchestration, diagnostic WAV capture 등 v1 파일/코드는 하나도 가져오지 않았다. v1 조사에서 얻은 사실(Phone.app bundle id, CallKit 불가, Accessibility 후보 등)만 참고했다.

## Architecture

```
bridge/
├─ Package.swift
├─ Info.plist
├─ Sources/JarvisCallBridge/
│  ├─ App/            JarvisCallBridgeApp.swift, BridgeViewModel.swift
│  ├─ State/           BridgeState.swift, BridgeStateMachine.swift
│  ├─ Call/            PhoneAppDiscovery.swift, AccessibilityStatus.swift, CallControlService.swift
│  ├─ System/          AudioRouteManager.swift (Snapshot/Reading/Mutating/CoreAudioRouteReader)
│  ├─ Logging/         BridgeLogger.swift
│  └─ UI/              ContentView.swift
├─ Scripts/build-app.sh
└─ Tests/JarvisCallBridgeTests/
   ├─ BridgeStateMachineTests.swift
   ├─ AudioRouteManagerTests.swift
   └─ PhoneAppDiscoveryTests.swift
```

State machine: `disabled ↔ armed`만 실제 도달 가능. `ringing`/`preparing`/`answering`/`activeAI`/`activeHumanMac`/`handoffToIPhone`/`restoring`/`error`는 enum에 선언되어 있으나 `allowedTransitions`에 없어 `requestTransition(to:)` 호출 시 거부되고 상태는 불변으로 유지된다(테스트로 검증).

Work Mode: ON → `armed` 진입, Phone.app readiness/Accessibility 상태 확인, 오디오 관련 동작 없음. OFF → `disabled`, 동일하게 오디오 미개입.

Phone.app discovery: `com.apple.mobilephone`을 `NSWorkspace.urlForApplication`/`NSRunningApplication.runningApplications`로만 조회. launch/focus/click 없음.

Accessibility status: `AXIsProcessTrusted()` 읽기 전용. 명시적 버튼을 누를 때만 시스템 프롬프트 요청.

Audio route read-only abstraction: `CoreAudioRouteReader.currentSnapshot()`이 `kAudioObjectSystemObject`에서 `kAudioHardwarePropertyDefaultInputDevice`/`...OutputDevice`/`...SystemOutputDevice`를 `AudioObjectGetPropertyData`로 읽고, 각 장치의 `kAudioObjectPropertyName`도 읽어온다. Setter/mutation 함수 없음 — `AudioRouteMutating`은 Phase 1+용 프로토콜 선언만 존재하고 실제 구현체가 어디에도 연결되어 있지 않다.

## Build

| 항목 | 결과 |
|---|---|
| `swift build` | **PASS** |
| Warnings | **0** |
| `.app` 패키징 (`Scripts/build-app.sh`) | **PASS** — `.build/Jarvis Call Bridge.app` |
| Headless 실행 확인 | **PASS** — `open`으로 실행 후 3초+ 정상 유지, 정상 종료(quit) 확인 |
| `CFBundleExecutable` | Info.plist에 처음부터 포함(v1 세션에서 겪었던 누락 버그를 알고 있었으므로 재발 방지) |
| 실제 SwiftUI 창 렌더링의 시각적 확인 | **미확인** — 이 에이전트 환경에서 `screencapture`가 "could not create image from display" 오류로 실패해 스크린샷을 얻지 못했다(Screen Recording 권한 부재로 추정). 프로세스가 크래시 없이 유지된 것은 확인했으나, 실제 창이 정상적으로 그려지는지는 사용자가 실기기 테스트 시 직접 육안으로 확인해야 한다. |

## Automated Tests

| Test Suite | 개수 | 결과 |
|---|---|---|
| `BridgeStateMachineTests` | 5 | PASS |
| `AudioRouteManagerTests` | 2 | PASS |
| `PhoneAppDiscoveryTests` | 1 | PASS |
| **합계** | **8** | **8 passed, 0 failed** |

검증 내용:
- 초기 상태 `disabled`
- Work Mode ON → `armed`, OFF → `disabled`
- `disabled`에서 `ringing`/`activeAI`/`handoffToIPhone`로의 전이 거부 및 상태 불변
- `armed`에서 `preparing`으로의 전이 거부 및 상태 불변
- **`AudioRouteMutationSpy`를 주입한 상태에서 Work Mode ON/OFF 양쪽 모두 `spy.callCount == 0`** — Work Mode 토글이 감사 가능한 형태로 audio route를 절대 건드리지 않음을 증명
- `CoreAudioRouteReader`로 실제 시스템에서 연속 두 번 snapshot을 읽어 동일함을 확인(진짜 CoreAudio 접근이 이 환경에서 동작함을 확인 — 실패 시 skip 처리하도록 방어했으나 실제로는 정상 동작)
- `PhoneAppDiscovery.bundleIdentifier == "com.apple.mobilephone"` 상수 고정 확인

## Safety Verification

다음을 코드 검토와 빌드 결과로 명시적으로 확인한다.

- ScreenCaptureKit 사용: **없음** (import 자체가 없음)
- Audio capture: **없음**
- HAL driver: **없음** (`HALPlugin/` 재작성하지 않았고 `AudioServerPlugIn` import 없음)
- Virtual Mic: **없음**
- Shared Memory: **없음** (`shm_open`/`mmap` 코드 없음)
- Audio route mutation: **없음** — `AudioRouteMutating`을 구현/호출하는 코드가 프로덕션 경로에 전혀 없고, 테스트에서 spy로 0회 호출을 증명
- Accessibility click action: **없음** — `AXUIElementPerformAction` 사용 없음, `AXIsProcessTrusted`/`AXIsProcessTrustedWithOptions`만 사용
- Auto-answer: **없음**

이번 세션에서 실행한 명령은 `swift build`, `swift test`, `Scripts/build-app.sh`, `open`(앱 실행/종료), `screencapture`(권한 없어 실패), `git status`/`log`(읽기 전용)뿐이다. `sudo`, HAL driver 설치, `/Library/Audio/Plug-Ins/HAL` 수정, `coreaudiod` kill/restart, TCC reset, system settings 변경, Phone.app/FaceTime kill, `git commit`/`push`/`tag`/`reset --hard`/`clean -fd`, 다른 top-level 프로젝트(`admin/`, `api/`, `web/`) 수정은 전혀 수행하지 않았다.

## Real Device Validation

**STATUS = WAITING FOR REAL DEVICE VALIDATION**

### 사용자 실기기 테스트 절차

**사전 준비**
```sh
cd bridge
./Scripts/build-app.sh
open ".build/Jarvis Call Bridge.app"
```

**TEST A — Work Mode OFF**
1. 앱 실행, Work Mode **OFF** 상태 유지 (기본값)
2. 다른 전화기에서 iPhone 번호로 전화
3. Mac Phone.app에 정상 착신 표시되는지 확인

**TEST B — Work Mode ON / ARMED**
1. 앱에서 Work Mode 토글을 **ON**
2. Bridge State가 **Armed**로 바뀌는지 확인
3. 다른 전화기에서 iPhone 번호로 전화
4. Mac Phone.app에 정상 착신 표시되는지 확인
5. Bridge가 전화에 대해 아무 행동도 하지 않는지 확인 (자동 수신 없음, UI에 별도 팝업 없음)
6. Audio Route(Input/Output/System Output) 행이 통화 전후로 동일한지 확인

**최종 Acceptance**: TEST B를 실제 착신으로 **최소 10회 반복**, 매번 다음을 모두 만족해야 한다.
- Mac에 정상 착신 표시
- iPhone 정상 착신
- Bridge 때문에 착신이 사라지지 않음
- Bridge가 자동으로 받지 않음
- Audio Route 변경 없음 (앱 UI의 Input/Output/System Output 값이 통화 전후 동일)

### 결과 기록 (사용자 전달, 2026-08-15)

사용자가 Mac Studio + 실제 iPhone으로 직접 수행한 결과:

- Work Mode **OFF** 상태에서 Mac Studio Phone.app 착신 **정상**
- Work Mode **ON / ARMED** 상태에서도 Phone.app 착신 **정상**
- ARMED 상태에서 **여러 차례 반복 착신 정상** (다만 최초 요구한 **10회 연속**을 전부 채우지는 않음)
- 전화가 오는 동안 **Audio Route 변경 없음**
- v1에서 관찰됐던 "Bridge 활성화 시 Mac 착신이 사라지는 현상"이 v2에서는 **재현되지 않음**

| 회차 | Mac 착신 | iPhone 착신 | 자동수신 없음 | Route 불변 | 비고 |
|---|---|---|---|---|---|
| 1~N (10회 미만) | PASS | PASS | PASS | PASS | 정확한 반복 횟수는 사용자 보고에 세부 기록되지 않음 — 아래 판정에 반영 |

## Phase Result

**CONDITIONAL PASS**

핵심 invariant("ARMED가 native incoming call을 방해하지 않는다")는 실제 착신으로 확인됐고 v1에서 발견됐던 회귀도 재현되지 않았다. 다만 PRD §17/§38이 요구하는 **10회 연속** acceptance를 전부 채우지 못했으므로 무조건 PASS로 과장하지 않고 CONDITIONAL PASS로 기록한다. CB v2 Phase 1(Dual Loopback Audio Driver)은 이 CONDITIONAL PASS를 게이트로 진행한다 — PRD §38 Phase Gate 원칙에 따라 남은 반복 횟수를 마저 채우는 것을 막지는 않되, 결과가 뒤집힐 경우 즉시 재검토가 필요하다는 점을 기록해 둔다.
