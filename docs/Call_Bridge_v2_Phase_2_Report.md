# CB v2 Phase 2 Report — Incoming Call Lifecycle & Accessibility Auto Answer

작성일: 2026-08-15
최종 판정 (에이전트 단계): **IMPLEMENTATION/BUILD/TESTS COMPLETE — REQUIRES MANUAL VALIDATION**

## Environment

| 항목 | 값 |
|---|---|
| macOS | 26.6 (Build 25G72) |
| Architecture | arm64 (Apple Silicon) |
| Swift | Apple Swift 6.3.3 (swift-driver 1.148.6) |
| Xcode | 26.6 |

## Previous Phase Gate

- **Phase 0**: CONDITIONAL PASS — 실제 착신 검증됨(10회 미만이지만 여러 차례 반복 성공, v1 회귀 없음)
- **Phase 1**: **PASS** — 실제 Mac Studio에서 Capture/Inject loopback correlation ≥0.998, cross-device isolation, 10/10 lifecycle stress, default route 불변 전부 확인 (`docs/Call_Bridge_v2_Phase_1_Report.md` 최종 업데이트 완료)

## Scope

### Implemented

- `CallLifecycleState`(idle/ringing/answering/active/ending/ended/unknown) — `BridgeState`(Work Mode 준비 상태)와 완전히 분리된 모델. `CallSession`으로 동일 착신 dedup
- `AccessibilityScanning` protocol + `AXElementSnapshot`/`CallStateEvidence` 값 타입 — 실제 AX 프레임워크를 테스트 경계 밖으로 격리(mock 가능)
- `SystemAccessibilityClient` — 실제 구현. Phone.app(`com.apple.mobilephone`) + Notification Center(`com.apple.notificationcenterui`) 두 후보 프로세스를 bounded depth(6)·bounded node count(600/process)로 스캔. 읽기 전용, click 없음
- `AnswerCandidateResolver` — evidence 기반 confidence(high/medium/low) 스코어링. 복수 후보가 동시에 "high"급으로 나오면 전부 downgrade(ambiguity → no action, PRD §13)
- `AutoAnswerController` — 지연 타이머(기본 3초, Immediate/1/3/5초 지원), 매 cycle 전체 조건 재검증, session당 최대 1회 press, 실패 시 재시도 없음
- `CallLifecycleTracker` — evidence 기반 ringing→active(§19: 최소 2개 독립 evidence), active→idle(§20: debounce), 수동 응답과 자동 응답을 동일하게 인식
- `IncomingCallObserver` — bounded polling(기본 750ms) 오케스트레이션 + 읽기 전용 diagnostic dump("Dump Incoming AX Snapshot")
- UI: Call state/Caller/Candidates, Auto Answer ON/OFF + Delay 선택, 카운트다운, 마지막 시도 결과, 진단 dump 버튼
- Structured logging (`[CALL]`, `[AUTOANSWER]`, `[AX-DUMP]`)
- 신규 unit test 24개 시나리오 전부 커버 (mock 기반, 실제 AX 호출 없음)

### Not Implemented (계획대로 구현하지 않음)

Phone.app audio routing, Capture/Inject activation, 실제 RX/TX, Realtime AI, recording, Human Takeover, iPhone Handoff 처리, Jarvis Agent Tool Call, Memory, R2, SIP/070/Twilio. Work Mode ON 자체가 driver를 activate하지 않으며, 이번 Phase의 어떤 call lifecycle 이벤트(ringing/answering/active/ending)도 driver activate나 audio route 변경을 수행하지 않는다.

## Accessibility Architecture

```
IncomingCallObserver (bounded poll, 750ms)
  ├─ SystemAccessibilityClient.scanCallRelevantElements()
  │    └─ AnswerCandidateResolver.resolve() → [AnswerCandidate] (high/medium/low)
  ├─ SystemAccessibilityClient.currentCallStateEvidence()
  ├─ CallLifecycleTracker.update(hasAnyCandidate:, evidence:) → CallLifecycleState
  └─ AutoAnswerController.evaluate(candidates:, workModeArmed:)
       └─ (high-confidence, 유일, enabled, 미시도) 일 때만 → 지연 타이머 → SystemAccessibilityClient.press()
```

**실제 착신 UI가 어느 프로세스에 있는지는 미확정이다** (PRD §10). `SystemAccessibilityClient`는 Phone.app과 Notification Center 둘 다 스캔하도록 구현했지만, 어느 쪽이 실제 "받기" 버튼을 갖고 있는지, confidence 스코어링 threshold(현재 high=5점, medium=3점)가 실제 UI에 적합한지는 **전부 미검증**이다. `IncomingCallObserver.dumpDiagnosticSnapshot()`(UI의 "Dump Incoming AX Snapshot" 버튼)이 CHECKPOINT 2에서 실제 착신 시 이 정보를 얻기 위한 도구다 — 결과에 따라 `AnswerCandidateResolver`의 키워드/스코어링만 조정하면 되도록 로직을 한 곳에 격리해뒀다.

Event-driven `AXObserver`(PRD §9의 1순위)가 아니라 bounded polling(750ms)을 채택했다 — 실제 알림 구조를 모르는 상태에서 어떤 notification 이름을 구독해야 할지 알 수 없기 때문이며, event-driven으로 주장하지 않고 그대로 기록한다. Busy-polling은 아니다(750ms 고정 간격, full-tree crawl 아님, bounded depth/node count).

## Safety

- **No ScreenCaptureKit**: 사용 없음
- **No audio route mutation**: 이번 Phase의 어떤 파일도 `CoreAudio`를 import하지 않음 (`CallLifecycleState.swift`, `AccessibilityScanning.swift`, `AnswerCandidate.swift`, `AutoAnswerController.swift`, `CallLifecycleTracker.swift`, `IncomingCallObserver.swift`, `SystemAccessibilityClient.swift` 전부 CoreAudio 의존성 없음) — 구조적으로 불가능
- **No driver activation**: 위와 동일한 이유로 구조적으로 불가능. `BridgeStateMachine`만 `AudioRouteMutating`/`AudioDriverActivating`을 갖고 있고, call lifecycle 컴포넌트들은 그것들을 참조조차 하지 않음
- **No Realtime**: 관련 코드 없음
- **No recording**: 관련 코드 없음
- **No private APIs**: `ApplicationServices`(AXUIElement 공개 API)만 사용
- **No coordinate clicking**: `AXUIElementPerformAction(kAXPressAction)` 단 한 곳(`SystemAccessibilityClient.press(_:)`)에서만 AX action 수행. CGEvent/AppleScript/cliclick 없음

## Automated Tests

| Suite | 개수 | 결과 |
|---|---|---|
| `BridgeStateMachineTests` (Phase 0/1 유지) | 6 | PASS |
| `AudioRouteManagerTests` (Phase 0 유지) | 2 | PASS |
| `PhoneAppDiscoveryTests` (Phase 0 유지) | 1 | PASS |
| `LoopbackBufferTests` (Phase 1 유지) | 5 | PASS |
| `AnswerCandidateResolverTests` (신규) | 6 | PASS |
| `CallLifecycleTrackerTests` (신규) | 8 | PASS |
| `AutoAnswerControllerTests` (신규) | 11 | PASS |
| `IncomingCallObserverTests` (신규) | 3 | PASS |
| **합계** | **42** | **42 passed, 0 failed** |

PRD §28이 요구한 24개 시나리오 매핑:

1~2 Work Mode/ARMED: `IncomingCallObserverTests.testWorkModeOffKeepsObserverInactive...` + 기존 `BridgeStateMachineTests`
3 incoming→ringing: `testArmedWithIncomingCandidateReachesRinging`
4 dedup: `testDuplicateIncomingDetectionsKeepSameSession`
5~11 Auto Answer 게이트(off/medium/low/ambiguous/timer 스케줄): `AutoAnswerControllerTests`의 각 해당 테스트
12 정확히 1회 press: `testHighConfidenceSingleCandidatePressesExactlyOnce`
13 dedup press: `testDuplicateEventsForSameCallNeverPressMoreThanOnce`
14 실패 시 재시도 없음: `testPressFailureDoesNotRetry`
15~17 manual/auto 응답 경로, 종료: `CallLifecycleTrackerTests`
18 debounce: `testTemporaryEvidenceDisappearanceDuringDebounceDoesNotEndCall`
19 unknown 상태에서 action 금지: `testUnknownStateDoesNotAutoTransition` + `AutoAnswerControllerTests.testUnknownStateNeverPresses`
20~24 driver/route 비개입: 기존 `testWorkModeTogglingNeverActivatesAudioDriver`/`...NeverMutatesAudioRoute` + 신규 `IncomingCallObserverTests.testFullCallLifecycleNeverActivatesDriverOrMutatesRoute`(ringing→press→active→end 전체를 spy와 함께 실행)

## Build

| 항목 | 결과 |
|---|---|
| `swift build` | **PASS**, 경고 0 |
| `swift test` | **PASS** — 42/42 |
| `Scripts/build-app.sh` + headless 실행 | **PASS** — 3초+ 크래시 없이 유지, 정상 종료 |
| Phase 1 driver regression 확인 (`JarvisAudioDriverTool status`) | **PASS** — 앱 실행 전후 Capture/Inject `hidden=true active=false` 그대로, route `Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커` 불변 |

## CHECKPOINT 2 — 1차 실기기 결과 (2026-08-15, 사용자 보고)

| 항목 | 결과 |
|---|---|
| iPhone 실제 셀룰러 착신 | PASS |
| Apple Continuity native 착신 UI 표시 | PASS |
| Work Mode ON / Auto Answer OFF 상태 유지 | PASS |
| Native 착신 방해 없음 | PASS |
| **Jarvis Ringing 감지** | **FAIL** — UI에 `Call State: Idle`, `Candidates: 0 found` |
| Filtered AX dump (`Dump Incoming AX Snapshot`) | `0 call-relevant element(s) found`, evidence 전부 false |
| Audio driver | inactive 유지 (영향 없음) |
| Audio route | 불변 (영향 없음) |

**CHECKPOINT 2 = BLOCKED / INVESTIGATION REQUIRED** (Phase 2 전체 실패로 판정하지 않음 — checkpoint 단위 discovery 이슈).

기존 필터링된 스캔이 `com.apple.mobilephone`/`com.apple.notificationcenterui` 두 프로세스만 검사했는데 0개가 나왔다 — 두 프로세스 중 실제로 착신 UI를 갖고 있지 않거나, 있어도 필터/스코어링이 놓치고 있다는 뜻이다. 리졸버를 추측으로 고치지 말라는 지시에 따라 리졸버는 변경하지 않고, 아래의 진단 도구를 먼저 추가했다.

## CHECKPOINT 2 Diagnostic Fix

### Added

- **`[AX-AUTH] trusted=...`**: `AccessibilityStatus.refresh()`가 매 refresh마다(변경 시에만이 아니라) 명시적으로 로깅하도록 변경
- **`Dump Raw AX Discovery Snapshot`** (신규, 기존 필터링된 dump와 별개로 유지): `AXRawDiscovery.walk` — call 관련 키워드로 전혀 필터링하지 않는 순수·테스트 가능한 bounded walk 알고리즘(`AXRawNode` 프로토콜로 실제 AX 프레임워크와 분리) + `SystemAccessibilityClient.performRawDiscovery`가 이를 실제 AX로 감싼다.
  - `NSWorkspace.shared.runningApplications`로 **모든** 실행 중 앱을 열거(공개 API, 특정 프로세스로 제한하지 않음)하고 각각의 pid/name/bundle/activationPolicy/windowCount/focusedWindow/axReadable을 기록
  - 창을 가진 프로세스만 bounded depth(6)·bounded per-process node(500)·bounded total node(3000)로 raw dump — role/title/keyword 무관하게 전부 기록
  - 민감할 수 있는 긴 텍스트/전화번호처럼 보이는 값은 `AXRedaction`으로 마스킹
  - truncation 발생 시 명시적으로 보고
- **`Start/Stop AX Event Diagnostics`** (신규, 보조 진단): 직전 raw discovery에서 발견된 창 보유 프로세스들에 `AXObserver`를 bounded 시간(기본 45초) 동안만 등록해 `kAXWindowCreatedNotification`/`kAXFocusedWindowChangedNotification`/`kAXApplicationActivatedNotification`/`kAXUIElementDestroyedNotification`/`kAXValueChangedNotification`을 `[AX-EVENT]`로 로깅. 액션 수행 없음, 자동 종료.
- `AnswerCandidateResolver`/`CallLifecycleTracker`/`AutoAnswerController`는 **변경하지 않음** (지시사항 §10 그대로 준수).

### Safety (재확인)

- AXPress 없음 (raw discovery/event diagnostics 둘 다 read-only, press 기능 자체가 없음 — `AXRawNode` 프로토콜에 mutating 멤버가 아예 없음)
- 좌표 클릭/CGEvent/AppleScript 없음
- ScreenCaptureKit 없음
- audio route mutation 없음 — 신규 파일(`AXRawDiscovery.swift`, `AccessibilityRawDiagnosticsProviding.swift`, `AXEventDiagnosticsSession.swift`, `SystemAccessibilityClient.swift` 확장분) 어디에도 CoreAudio import 없음 → 구조적으로 불가능
- driver activation 없음 — 동일한 이유로 구조적으로 불가능
- Realtime/recording 없음
- Jarvis Call Capture/Inject: inactive 유지 확인 (앱 실행 후 `JarvisAudioDriverTool status`로 재확인)
- Default Input/Output/System Output: 불변 확인

### Tests

새 테스트 9개 추가 (`AXRawDiscoveryTests` 7개 + `SystemAccessibilityClientDiagnosticsTests` 2개), 기존 42개 전부 유지 — **합계 51개, 51 passed, 0 failed**.

| # | 항목 | 커버 |
|---|---|---|
| 1 | raw diagnostic이 performPress를 호출하지 않음 | `testWalkCapturesPressabilityAsDataWithoutPressing` (+ `AXRawNode`가 애초에 press 기능이 없다는 타입 레벨 보증) |
| 2 | raw diagnostic이 focus를 변경하지 않음 | 구조적 보증(`AXRawNode`는 `{ get }` 전용) + 위 테스트의 `wasMutated` 플래그 |
| 3 | maximum depth 준수 | `testWalkRespectsMaximumDepth` |
| 4 | maximum node count 준수 | `testWalkRespectsMaximumNodeCount` |
| 5 | unknown/unlocalized role/title 표현 가능 | `testWalkHandlesUnknownAndUnlocalizedAttributes` |
| 6 | call 키워드에 의존하지 않음 | `testWalkDoesNotFilterByCallRelatedKeywords` |
| 7 | AX 권한 없으면 스캔 안 함 | `testUntrustedProcessNeverScans` (실제 `SystemAccessibilityClient`를 대상으로, 실제 신뢰 상태와 비교) |
| 8 | 기존 observer/resolver 테스트 불변 | 기존 42개 전부 그대로 유지·통과 |
| 9~10 | driver activation/route mutation 카운트 0 | 구조적 보증(신규 파일 어디에도 CoreAudio import 없음) + 기존 `IncomingCallObserverTests.testFullCallLifecycleNeverActivatesDriverOrMutatesRoute` |

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 51/51
- `Scripts/build-app.sh` + headless 실행: PASS, 크래시 없음
- Phase 1 driver regression 재확인: PASS (Capture/Inject `hidden=true active=false`, route 불변)

## CHECKPOINT 2 — 2차 실기기 결과 (2026-08-15, 사용자 보고)

| 항목 | 결과 |
|---|---|
| Accessibility 권한 | **PASS** — Granted |
| Work Mode ON / Auto Answer OFF 상태 유지 | PASS |
| Native 착신 UI 표시 | **PASS** |
| Raw AX diagnostic 실행 여부 | **PASS** — 실행은 됨 |
| **진단 결과의 실사용 가능성** | **NO** |

**원인**: `AXApplication` 루트부터 걷는 이전 구현이 Notification Center/Finder/Google Chrome/Notes/iTerm2/ChatGPT/NAVER Whale/KakaoTalk 등 착신과 무관한 앱의 전체 트리를 함께 훑었고, 공유 global node cap(3000)이 먼저 열거된 프로세스에서 소진되었으며, 게다가 요소 단위 로그가 `BridgeLogger`의 500줄 cap을 통해 기록되어 앞선(중요할 수 있는) 로그가 밀려났다.

**중요**: 이 결과는 **"Accessibility로 착신 UI를 볼 수 없다"는 증거가 아니다.** 이는 **진단 수집 전략 자체가 너무 광범위했다는 증거**다 — 사용자가 명시적으로 지적한 대로, 진단 도구의 한계로 기록하며 Phase 2 실패나 리졸버 문제로 판정하지 않는다.

## CHECKPOINT 2 Diagnostic Fix #2 — Window-Only Discovery + Dedicated Snapshot Export

### Motivation (privacy minimization)

`AXApplication` 루트 대신 각 프로세스의 `AXWindow`만 순회하도록 재설계했다. 이는 진단 실패의 직접 원인(전체 앱 트리 crawl → node cap 소진)을 고치는 동시에, 메뉴바/브라우저 탭/채팅 히스토리처럼 착신 통화와 무관한 앱 콘텐츠가 애초에 진단 결과에 등장할 수 없도록 만드는 privacy-minimization 조치이기도 하다 — window 바깥 데이터는 구조적으로 도달 불가능하다(`AXMenuBar`는 `AXApplication`의 형제 attribute이지 어떤 window의 자손도 아니므로, window를 root로 넘기는 순간 자동으로 배제된다).

### Added

- **`AXDiagnosticSnapshot`** (신규, `Call/AXDiagnosticSnapshot.swift`) — `BridgeLogger`와 완전히 분리된 전용 보관소. 프로세스 인벤토리·윈도우 목록·요소 전부·truncation 메타데이터를 보유하며, `renderText()`가 전체 상세를 문자열로 렌더링한다. `BridgeLogger`에는 `summaryLine`(processes=N windows=N nodes=N excludedMenuNodes=N truncated=true/false) 한 줄만 기록되고, 요소 단위 상세는 절대 로거를 거치지 않는다 — 500줄 cap에 의한 유실이 구조적으로 불가능해졌다.
- **Window-only walk** (`AXRawDiscovery.walk`, `SystemAccessibilityClient.performRawDiscovery`): 각 windowed 프로세스마다 (1) non-recursive 프로세스 인벤토리를 먼저 전부 열거하고, (2) 프로세스별이 아니라 **윈도우별로** `AXWindow` 요소를 root로 bounded walk(`maxDepthPerWindow=8`, `maxNodesPerWindow=500`) 수행. 각 윈도우는 이전 윈도우가 얼마나 소진했는지와 무관하게 **항상 자신의 전체 500-node 예산**을 받는다 — 이전의 `min(maxNodesPerProcess, remainingBudget)` 버그(첫 프로세스가 전체 예산을 먼저 소진)를 제거했다. `maxTotalNodes=5000`은 오직 "더 이상 새 윈도우를 스캔하지 않는다"는 전역 상한 역할만 하며, 개별 윈도우 예산을 줄이지 않는다.
- **`AXMenuBar`/`AXMenu`/`AXMenuItem` 서브트리 명시적 배제**: `AXRawDiscovery.walk`가 해당 role을 만나면 기록도, 재귀도 하지 않고 `excludedMenuNodeCount`만 증가시킨다.
- **"Copy Raw AX Snapshot" / "Save Raw AX Snapshot…"** (신규 버튼, `AXSnapshotExport.defaultFileName()` → `jarvis-ax-snapshot-YYYYMMDD-HHmmss.txt`) — 기존 "Copy All Logs"/"Save Logs…"와 별개로 유지, 두 개념을 섞지 않음.
- **Start/Stop AX Event Diagnostics 버튼 상태 버그 수정**: "Stop"이 세션이 없어도 항상 눌리던 문제를 고쳤다. `AXEventDiagnosticsSession`에 `isRunning`/`onStopped` 콜백을 추가하고 `BridgeViewModel.isEventDiagnosticsRunning`으로 전달, `ContentView`의 두 버튼이 실제 세션 상태(`.disabled`)를 반영하도록 바인딩. Event Diagnostics 기능 자체는 확장하지 않음.
- `AnswerCandidateResolver`/`CallLifecycleTracker`/`AutoAnswerController`는 **변경하지 않음** (지시사항 그대로 준수).

### Safety (재확인)

- AXPress 없음 — window-only walk도 동일하게 `AXRawNode`(`{ get }` 전용) 위에서만 동작, mutating 멤버 자체가 없음
- focus/app 활성화 변경 없음, 좌표 클릭/CGEvent/AppleScript 없음, ScreenCaptureKit 없음, private framework 없음
- audio route mutation/driver activation 없음 — 신규·수정 파일(`AXRawDiscovery.swift`, `AXDiagnosticSnapshot.swift`, `AXSnapshotExport.swift`, `AccessibilityRawDiagnosticsProviding.swift`, `AXEventDiagnosticsSession.swift`, `SystemAccessibilityClient.swift`, `BridgeViewModel.swift`, `ContentView.swift`) 어디에도 CoreAudio import 없음 → 구조적으로 불가능
- Realtime/recording 없음
- Auto Answer는 OFF 유지, `AnswerCandidateResolver`/confidence 스코어링/`CallLifecycleTracker`/`AutoAnswerController` 로직 전부 무변경

### Tests

새 테스트 14개 추가(`AXRawDiscoveryTests` +7, `SystemAccessibilityClientDiagnosticsTests` +1, `AXDiagnosticSnapshotTests` 신규 4, `AXEventDiagnosticsSessionTests` 신규 2), 기존 54개 전부 유지 — **합계 68개, 68 passed, 0 failed**.

| # | 항목 | 커버 |
|---|---|---|
| 1 | window root ≠ app root (형제 데이터 격리) | `testWalkRootIsIsolatedFromSiblingData` |
| 2 | `AXMenuBar` 서브트리 미재귀 | `testWalkExcludesAXMenuBarSubtreeFromRecursion` |
| 3 | `AXMenu`/`AXMenuItem` 서브트리 미재귀 | `testWalkExcludesAXMenuAndAXMenuItemSubtreesFromRecursion` |
| 4 | 큰 윈도우가 다른 윈도우 예산을 소진 못 함 | `testEachWindowGetsItsOwnFullBudgetRegardlessOfOtherWindows` |
| 5 | 프로세스 인벤토리 non-recursive | `testProcessSummaryCarriesNoNestedElementData` (구조적 보증) |
| 6 | 전용 snapshot이 500줄 cap에 안 걸림 | `testRenderTextIncludesEveryElementRegardlessOfCountExceedingLoggerCap` (600개 요소로 검증) |
| 7 | Copy Raw AX Snapshot이 전체 export | `testRenderTextIncludesProcessWindowAndElementSections` |
| 8 | Save Raw AX Snapshot 파일명/데이터 완전성 | `testDefaultFileNameFormatIsDistinctFromLogExport` + 위 항목 |
| 9 | snapshot 생성이 performPress 호출 안 함 | `testExcludedMenuNodesAreNeverMutated` + 기존 `testWalkCapturesPressabilityAsDataWithoutPressing` |
| 10 | 기존 redaction 여전히 유효 | `testRedactionStillEffectiveInWindowScopedWalk` |
| 11 | Event Diagnostics Start/Stop 상태가 실제 세션과 일치 | `testStartWhenNotTrustedNeverReportsRunningAndInvokesOnStoppedImmediately` + `testStopWithoutAnyStartedSessionDoesNotInvokeOnStopped` |

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 68/68
- `Scripts/build-app.sh` + headless 실행: PASS, 3초+ 유지 후 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인 (`JarvisAudioDriverTool status`): PASS — Capture/Inject `hidden=true active=false` 그대로, route `Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커` 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인 (다른 최상위 프로젝트 무변경)

## CHECKPOINT 2 — No-Call Baseline Result (2026-08-15, 사용자 보고)

이전 실제 착신 통화가 이미 종료되고 수 분이 지난 뒤, 확인된 **No-Call 베이스라인**:

| 항목 | 값 |
|---|---|
| Accessibility | Granted |
| Work Mode | ON |
| Auto Answer | OFF |
| Native 착신 | **NONE** (실제 통화 없음) |

그럼에도 Jarvis는:

| 항목 | 결과 |
|---|---|
| State | **Ringing** (틀림) |
| Candidates | **341** (틀림) |
| "Dump Incoming AX Snapshot" (필터링된 스캔) | `341 call-relevant element(s) found` |
| evidence answer | **true** (틀림) |
| evidence end | **true** (틀림) |
| evidence activeControls | **true** (틀림) |
| evidence duration | **true** (틀림) |

341개 요소는 대부분 평범한 Phone.app/Notification Center UI였다 — application 메뉴 항목, recent-item 메뉴, Edit/Window/Help 메뉴, window chrome, 검색, 키패드, 표준 AXPress 가능 컨트롤. **이는 더 이상 가설이 아니라 확정된 false-positive 문제였다.**

### 차분 증거

- 실제 착신 중: 342개 filtered 요소
- 이후 확정 No-Call 베이스라인: 341개 filtered 요소
- 실제 착신 중에만 관찰되고 이후 No-Call 상태에서는 사라진 transient 요소 1개:

```
bundle=com.apple.mobilephone
role=AXButton
subrole=-
identifier=-
title=""
description="통신 오디오"
enabled=true
actions=["AXPress"]
```

이 요소는 "call-related UI/session이 존재한다"는 것과 상관관계가 있을 수 있다는 진단적 단서로만 취급한다 — Answer 버튼이라거나, 누르면 응답된다거나, ringing을 고유하게 의미한다거나, incoming/outgoing/active를 구분한다고 가정하지 않는다.

## Root Cause (코드 레벨)

1. **`SystemAccessibilityClient.scanProcess`/`walk`(구)가 `AXApplication` 루트부터 전체 트리를 훑었다** — Diagnostic Fix #2에서 raw discovery에 발견된 것과 동일한 구조적 문제가 production 스캐너에도 그대로 있었다. `kAXChildrenAttribute`로 재귀하면 `AXMenuBar`와 그 하위 전체 메뉴 트리(File/Edit/Window/Help, recent items 등)가 통째로 포함된다.
2. **수집 필터 `snapshot.supportsPress || snapshot.role == "AXButton"`에 의미론적 필터링이 전혀 없었다** — enabled 여부·앱 소속·역할만으로 341개 전부가 "call-relevant element"로 수집됐다. 이 341개는 대부분 Edit/필터/키패드/검색/닫기/최소화/확대 같은 평범한 컨트롤이었다.
3. **`AnswerCandidateResolver.resolve`가 pressable 요소 전부에 대해 `AnswerCandidate`를 반환했다**(점수 0인 것도 `.low`로) — `enabled(+1)+Phone.app 소속(+2)+AXButton 역할(+1)=4`만으로 mediumThreshold(3)를 넘어 "candidate"가 됐다. `IncomingCallObserver.tick()`은 `!resolved.isEmpty`(신뢰도 무관, 아무 candidate나 있으면)를 ringing 신호로 썼기 때문에, 평범한 버튼이 하나라도 있으면 Idle→Ringing 전환이 발생했다 — 정확히 관찰된 버그.
4. **`currentCallStateEvidence()`의 키워드 매칭이 너무 느슨했다**: `endCallKeywords`의 단독 "종료"(macOS 전반의 Quit/Close 메뉴 명령에 나타나는 매우 일반적인 한국어 단어)가 end evidence를 유발했고, `activeControlKeywords`의 "키패드"(Phone.app이 통화 중이 아니어도 항상 보여주는 다이얼러 UI)가 activeControls evidence를 유발했으며, duration 체크가 단순히 `haystack.contains(":")`였기 때문에 콜론이 포함된 아무 텍스트에나 반응했다.

이 결과는 **"Accessibility로 착신 UI를 볼 수 없다"는 증거가 아니다** — production 스캐너/리졸버/evidence 추출 로직이 지나치게 관대했다는 증거였다.

## CHECKPOINT 2 — False Positive Elimination + Focused Call AX Diagnostics

### 구조적 수정

1. **Production 스캐너 window-scope화** (`SystemAccessibilityClient.scanWindows`) — Diagnostic Fix #2와 동일한 구조적 교훈을 적용: `AXApplication` 루트가 아니라 각 프로세스의 `AXWindow`만 순회. `AXRawDiscovery.walk`(이미 `AXMenuBar`/`AXMenu`/`AXMenuItem` 제외 로직과 테스트를 가진)를 그대로 재사용해 손으로 다시 구현하지 않고 이 보증을 그대로 물려받는다.
2. **`AXMenuBarItem`을 제외 role 목록에 추가** — 기존 Diagnostic Fix #2의 제외 목록(`AXMenuBar`/`AXMenu`/`AXMenuItem`)에 빠져 있던 role. `AXMenuBar`의 직계 자식이 보통 `AXMenuBarItem`(File/Edit/Window/Help)이며, 각각이 AXPress 가능한 메뉴 커맨드를 담고 있어 명시적으로 제외해야 한다.
3. **`AnswerCandidateResolver`에 구조적 candidacy gate 추가** — enabled+Phone.app 소속+AXButton 역할이라는 일반적 보너스만으로는 candidate가 될 수 없도록 했다. answer keyword 매칭 또는 "call" 관련 subrole처럼 **실제 call-specific signal**이 있어야만 candidate가 된다(disabled 요소의 기존 `.low` 표시 동작은 그대로 유지). PRD의 "실제 Answer 버튼 증거를 확보하기 전까지 false negative를 선호하라" 지시를 그대로 구현.
4. **`CallStateEvidenceExtractor`(신규, 순수·테스트 가능) 분리** — `endCallKeywords`에서 단독 "종료" 제거(→ "통화 종료"/"end call"/"hang up"만 유지), `activeControlKeywords`에서 "키패드"/"speaker"/"스피커" 제거("mute"/"음소거"만 유지, 이것도 미검증으로 표시), duration 체크를 `haystack.contains(":")`에서 "전체 문자열이 MM:SS 또는 H:MM:SS 숫자 패턴과 정확히 일치"하는 정규식으로 교체.
5. **`CallLifecycleTracker`/`IncomingCallObserver`/`AutoAnswerController`는 변경하지 않음** — 문제는 이들에게 들어가는 evidence/candidate 신호 자체였으므로, 업스트림(스캐너/리졸버/evidence 추출)만 고쳤다. 임의의 타임아웃이나 강제 리셋 로직은 추가하지 않았다.

### Focused Call AX Snapshot (신규 진단 도구)

전체 Raw AX Discovery Snapshot은 실제 기기에서 169개 프로세스·23개 창·5186개 노드를 ~98초에 걸쳐 스캔했다 — ringing UI처럼 짧게 사라지는 화면을 포착하기엔 너무 느리다. 이를 위한 별도의 빠르고 좁은 진단:

- **범위**: `com.apple.mobilephone`/`com.apple.notificationcenterui`(기존 후보 그대로 유지) + `com.apple.facetime`/`com.apple.FaceTime` 접두사로 매칭되는 FaceTime 알림 헬퍼 프로세스(동적 탐색, 실행 중이 아니어도 무방). **169개 전체 프로세스로 되돌아가지 않음** — 접두사 매칭 규칙 하나로 좁게 유지.
- **내용**: 프로세스별 pid/name/bundle/axReadable/windowCount/focusedWindow + 창별 role/subrole/title/identifier/description + 자식 요소(depth/role/subrole/identifier/title/description/enabled/actions/childCount). 기존 redaction 규칙 유지, 메뉴 role 제외(위 구조적 수정 재사용).
- **성능**: `elapsedMs` 계측. 좁은 프로세스 범위 덕분에 메인 액터 동기 실행으로도 목표(<1-2초)를 여유 있게 만족할 것으로 예상 — 실기기에서 elapsedMs가 목표치에 근접하면 백그라운드 실행으로 재검토 예정(현재는 도입하지 않음: `AXUIElement`는 Sendable이 아니라 백그라운드로 넘기면 Swift 6 동시성 안전성이 오히려 약해질 위험이 있고, 좁은 범위라면 불필요한 복잡도이기 때문).
- **전용 export**: `FocusedCallAXSnapshot`(신규, `AXDiagnosticSnapshot`과 동일한 패턴) — `BridgeLogger`는 `[AX-CALL-FOCUSED] processes=N windows=N nodes=N elapsedMs=N truncated=... callPresenceHint=...` 요약 한 줄만 받는다. 전체 상세는 "Copy Focused Call AX Snapshot"/"Save Focused Call AX Snapshot…"(`jarvis-call-ax-snapshot-YYYYMMDD-HHmmss.txt`)로만 노출.
- **선택적 label**: baseline/ringing/active/ended 중 선택하는 UI Picker 추가 — 순수 진단 메타데이터이며 스캐닝/리졸버 로직에 전혀 영향을 주지 않는다.
- **"통신 오디오" 처리**: `callPresenceHint`로 diagnostic-only 기록. Answer로 취급하지 않음, press하지 않음, 그 자체로 Auto Answer를 승인하지 않음, 그 자체로 Ringing vs Active를 증명하지 않음.
- **로컬라이즈드 라벨 하드코딩 금지**: "받기"/"응답"/"수락"/"Answer"/"Accept" 등 실기기 증거로 뒷받침되지 않은 새로운 추측 라벨을 추가하지 않음.

### Safety (재확인)

- AXPress 없음 — 신규 코드 전부 `AXRawDiscovery.walk`(`{ get }` 전용 `AXRawNode` 프로토콜) 위에서만 동작
- focus/app 활성화 변경 없음, 좌표 클릭/CGEvent/AppleScript 없음, ScreenCaptureKit 없음, private framework 없음
- audio route mutation/driver activation 없음 — 신규·수정 파일 어디에도 CoreAudio import 없음
- Realtime/recording 없음
- Auto Answer는 OFF 유지. 이번 수정은 `CallLifecycleTracker`/`AutoAnswerController`의 게이팅 로직(Work Mode 필요/high confidence 필요/유일 candidate 필요/delay+재검증/session당 1회 press/실패 시 재시도 없음) 자체를 하나도 완화하지 않았다 — 오직 그 입력이 되는 candidate/evidence 신호의 정확성만 고쳤다.

### Tests

새 테스트 22개 추가(`FalsePositiveRegressionTests` 신규 11개, `FocusedCallAXSnapshotTests` 신규 8개, `AXRawDiscoveryTests` +3), 기존 68개 전부 유지 — **합계 90개, 90 passed, 0 failed**.

| # | 요청 항목 | 커버 |
|---|---|---|
| 1 | AXMenuBar never call relevant | `testWalkExcludesAXMenuBarSubtreeFromRecursion`(기존) + `testFullMenuBarTreeShapeIsEntirelyExcluded`(신규) |
| 2 | AXMenuBarItem never call relevant | `testWalkExcludesAXMenuBarItemSubtreeFromRecursion`(신규 — 제외 목록에서 빠져있던 role을 이번에 추가) |
| 3 | AXMenu/AXMenuItem never AnswerCandidate | `testWalkExcludesAXMenuAndAXMenuItemSubtreesFromRecursion`(기존) |
| 4 | AXPress-only 요소는 candidate 아님 | `testGenericButtonWithNoCallSpecificSignalIsNeverACandidate`(기존, 업데이트) |
| 5 | Edit/Filter/Keypad/Search만으로 candidate 없음 | `testOrdinaryPhoneAppDialerControlsProduceNoCandidates` |
| 6 | Close/Minimize/Zoom은 evidence 없음 | `testNoCallBaselineProducesNoEvidenceOfAnyKind` |
| 7 | Quit/Close 메뉴 명령은 end evidence 없음 | `testBareGenericQuitCloseWordNeverCreatesEndCallEvidence` |
| 8 | 임의 숫자 텍스트는 duration evidence 없음 | `testArbitraryColonContainingTextDoesNotCreateDurationEvidence` |
| 9 | No-call 베이스라인 → candidates=0, evidence 전부 false | `testNoCallBaselineProducesNoEvidenceOfAnyKind` + `testOrdinaryPhoneAppDialerControlsProduceNoCandidates` |
| 10 | No-call fixture는 Idle→Ringing 전환 없음 | `testPersistentNoCallBaselineNeverReachesRinging` |
| 11 | 평범한 UI가 Ringing을 유지하지 못함 | `testPersistentNoCallBaselineNeverReachesRinging`(10회 반복 tick) |
| 12 | "통신 오디오" 단독으로는 candidate 아님 | `testCallPresenceHintElementAloneIsNeverACandidate` |
| 13 | "통신 오디오"는 press되지 않음 | `testCallPresenceHintElementIsCapturedAsDataWithoutPressing` |
| 14 | focused diagnostic이 메뉴 role 제외 | `AXRawDiscovery.walk` 재사용으로 구조적 상속(기존 테스트로 이미 커버) |
| 15 | focused diagnostic이 무관한 프로세스 스캔 안 함 | `testFaceTimeNotificationHelperPrefixMatchIsNarrow`/`...ExcludesUnrelatedProcesses`/`testPrimaryTargetBundleIdentifiersAreExactlyThePhaseTwoCandidates` |
| 16 | focused diagnostic이 window root 사용 (AXApplication 재귀 아님) | 코드 리뷰 + Diagnostic Fix #2와 동일한 `AXRawDiscovery.walk` 재사용(구조적 보증) |
| 17 | focused diagnostic이 AXPress 호출 안 함 | `testFocusedCaptureReusesReadOnlyWalkMachinery` |
| 18 | 전용 focused snapshot이 500줄 cap 무관 | `testRenderTextIncludesEveryElementRegardlessOfCountExceedingLoggerCap` |

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 90/90
- `Scripts/build-app.sh` + headless 실행: PASS, 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인 (`JarvisAudioDriverTool status`): PASS — Capture/Inject `hidden=true active=false` 그대로, route `Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커` 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

## CHECKPOINT 2 — 최종 판정: PASS (2026-08-15, 사용자 실기기 재검증)

False Positive Elimination 수정 반영 이후 실기기 재검증 결과, 아래 전부 확인됨:

| 항목 | 결과 |
|---|---|
| No-call 베이스라인 (State=Idle, Candidates=0) | **PASS** |
| False-positive candidate 없음 (이전 341 → 0) | **PASS** |
| 착신 ringing 감지 (State=Ringing) | **PASS** |
| 정확히 1개 candidate | **PASS** — `Candidates = 1` |
| 발신자 응답 전 종료 감지 (candidate 소실 → Idle 복귀) | **PASS** |
| Focused AX 진단 성능 | **PASS** — baseline elapsedMs≈250 (processes=5 windows=4 nodes=73), ringing elapsedMs≈311 (processes=5 windows=5 nodes=87). 목표(<1-2초) 대비 충분히 빠름 |
| 실제 착신 UI 소유 프로세스 식별 | **PASS** — `com.apple.notificationcenterui` |
| 실제 Answer AX 요소 식별 | **PASS** — 아래 참조 |

실기기 로그:

```
[CALL] lifecycle=ringing
[CALL] candidate discovered
...
[CALL] ringing candidate disappeared without active evidence — treating as ended
[CALL] lifecycle=idle
```

**관찰된 실제 착신 AX 구조** (Korean macOS, 실기기):

```
com.apple.notificationcenterui
  AXWindow / subrole=AXSystemDialog / title="Notification Center"
    AXGroup / subrole=AXNotificationCenterBanner / identifier=FACETIME_NOTIFICATION / description=FACETIME_NOTIFICATION
      AXGenericElement description="전화"
      AXGenericElement description=<caller/redacted>
      AXButton         description="답장"       ← Answer 아님
      AXPopUpButton    description="더 보기"     ← Answer 아님
      AXButton         description="거절"        ← Answer 아님 (Reject)
      AXButton         description="응답"        ← 실제 Answer 컨트롤
```

- **"응답"**이 이 시스템에서 관찰된 유일한 실제 Answer 컨트롤 (enabled=true, actions ⊇ [AXPress]).
- **"거절"**은 Answer가 아니다 (Reject).
- 이전 진단 단서였던 `com.apple.mobilephone` `AXButton description="통신 오디오"`는 **Answer가 아니다** — call-presence 진단 힌트로만 유지.

CHECKPOINT 2는 이제 **PASS**로 최종 기록한다. Phase 2 전체는 아직 최종 PASS가 아니다 — CHECKPOINT 3의 실기기 게이트(Gate A/B/C)가 남아있다.

## CHECKPOINT 3 — Evidence-Locked Answer Control + Manual/Auto Lifecycle Validation

**STATUS = IMPLEMENTED — REQUIRES MANUAL VALIDATION**

### 구조적 변경

1. **`AXElementSnapshot`에 `ancestorChain` 추가** (`[AXAncestorDescriptor]`, nearest-first, 기본값 `[]`로 기존 호출부 전부 무변경 유지) — 요소가 특정 `AXNotificationCenterBanner`/`FACETIME_NOTIFICATION` 조상 안에 있다는 것을 증명하는 데 필요. `AXRawDiscovery.walk`의 순수 재귀 알고리즘이 하강하면서 조상 스택을 함께 운반하도록 확장(신규 `AXAncestorDescriptor` 타입, `AXRawDiscoveryElement.ancestorChain`도 동일 패턴으로 확장) — 실제 AXUIElement 상호작용은 여전히 `SystemAccessibilityClient`에만 격리되어 있고, private API는 도입하지 않았다.
2. **`IncomingAnswerControlMatcher`(신규, 순수·테스트 가능)** — 아래 **전부**를 요구하는 evidence-locked 매칭:
   - 소유 프로세스 bundle = `com.apple.notificationcenterui`
   - 조상 체인에 `AXWindow`/`subrole=AXSystemDialog` 포함
   - 조상 체인에 `AXGroup`/`subrole=AXNotificationCenterBanner`/`identifier=FACETIME_NOTIFICATION` 포함
   - target `role=AXButton`
   - target `description="응답"` (정확히 일치, 부분 문자열 아님)
   - `enabled=true`
   - `actions`에 `AXPress` 포함
   - 로컬라이즈드 라벨을 추측으로 추가하지 않음 — "받기"/"수락"/"Answer"/"Accept" 전부 미도입 (실기기 증거 없음).
3. **`AnswerCandidateResolver` 재작성** — CHECKPOINT 2의 점수 누적 휴리스틱(enabled+소유앱+역할 조합만으로 medium 도달 가능했던 방식, 341개 false positive의 근본 원인과 동일 계열)을 완전히 폐기하고 `IncomingAnswerControlMatcher`가 유일한 candidacy 게이트가 됐다. 매칭되면 high, 아니면 candidate 자체가 아님(low/medium 부분점수 없음). 복수 매칭 시에만 PRD §13 그대로 ambiguity downgrade(전부 medium)가 적용된다.
4. **`AutoAnswerController`에 press 직전 실시간 재검증 추가** (§9/§10) — delay 도중 여러 poll tick이 지날 수 있으므로, 스케줄 시점에 캡처한 snapshot을 그대로 누르지 않는다. Press 직전 `scanner.scanCallRelevantElements()`를 다시 호출하고 `AnswerCandidateResolver.resolve()`로 재해석해, 정확히 1개의 high-confidence candidate가 있고 그 `id`가 원래 스케줄된 candidate와 **동일**할 때만 press한다. 조건이 달라지면 press를 취소하며, 다른 버튼으로 대체하지 않는다. 기존 안전 계약(Work Mode 필요/candidate 유일성/high confidence/session당 1회/실패 시 재시도 없음) 전부 유지.
5. **구조화 로깅 갱신**: `[AUTOANSWER] candidate high owner=notificationcenter banner=FACETIME_NOTIFICATION control=answer`, `scheduled delayMs=... session=...`, `revalidation pass session=...`, `press attempted session=...`, `press result=success|failure session=...`. 전화번호/발신자 개인정보/전체 알림 텍스트는 로깅하지 않음(redaction 유지).
6. **`CallLifecycleTracker`/`CallStateEvidenceExtractor`의 active-call 판정 로직은 변경하지 않음** — 문제였던 것은 candidate 판정 자체였으므로, 이번에도 upstream(리졸버/매처)만 고쳤다. 임의의 active 라벨 추측이나 워크어라운드는 추가하지 않았다.

### Safety (재확인)

- AXPress는 여전히 `SystemAccessibilityClient.press(_:)` 단 한 곳에서만 수행되며, `AutoAnswerController.attemptPress`의 재검증 경로도 실제 클릭 없이 순수 스캔·리졸브만 수행
- 좌표 클릭/CGEvent/AppleScript 없음, ScreenCaptureKit 없음, private framework 없음
- audio route mutation/driver activation 없음 — 신규·수정 파일 어디에도 CoreAudio import 없음
- Realtime/recording 없음
- Auto Answer는 OFF 유지(실기기 자동 테스트는 에이전트가 수행하지 않음)

### Tests

새 테스트 다수 추가, 기존 90개 전부 유지(리졸버 의미 변화로 일부 fixture/assert 갱신 — 아래 표), **합계 107개, 107 passed, 0 failed**.

| # | §22 요청 항목 | 커버 |
|---|---|---|
| 1-2 | 실제 관찰된 계층 구조 → candidate 정확히 1개, HIGH confidence | `testSingleStrongCandidateScoresHigh` |
| 3 | bundle=notificationcenterui 필수 | `testCandidateRequiresOwnerBundleNotificationCenter` |
| 4 | AXNotificationCenterBanner 조상 필수 | `testCandidateRequiresFacetimeNotificationBannerAncestor` |
| 5 | identifier=FACETIME_NOTIFICATION 필수 | 위와 동일 테스트(banner ancestor 검사에 identifier 포함) |
| 6 | target role=AXButton 필수 | `testCandidateRequiresTargetRoleAXButton` |
| 7 | description="응답" 필수(정확 일치) | `testCandidateRequiresExactAnswerDescription` |
| 8 | enabled=true 필수 | `testDisabledElementIsNeverACandidate` |
| 9 | AXPress 지원 필수 | `testCandidateRequiresAXPressSupport` |
| 10 | "거절"은 candidate 아님 | `testRejectButtonIsNeverAnswerCandidate` |
| 11 | "답장"은 candidate 아님 | `testReplyButtonIsNeverAnswerCandidate` |
| 12 | "더 보기"는 candidate 아님 | `testMoreButtonIsNeverAnswerCandidate` |
| 13 | "통신 오디오"는 candidate 아님 | `testCallPresenceHintElementIsNeverAnswerCandidate`(+기존) |
| 14 | banner 밖의 동일 "응답" 버튼은 candidate 아님 | `testCandidateRequiresFacetimeNotificationBannerAncestor`(outside-banner fixture) |
| 15 | 무관 프로세스 하의 동일 banner는 candidate 아님 | `testCandidateRequiresOwnerBundleNotificationCenter`(wrong-process fixture) |
| 16 | 복수 candidate → fail closed | `testMultipleAmbiguousCandidatesNeverScheduled`(기존) |
| 17 | delay 중 candidate 소실 → press 없음 | `testCandidateDisappearsDuringDelayCancelsPress`(신규) |
| 18 | delay 중 candidate 변경 → press 없음 | `testCandidateChangesIdentityDuringDelayCancelsPress`(신규) |
| 19 | delay 중 신뢰 상실 → press 없음 | `testAccessibilityTrustLostDuringDelayCancelsPress`(신규) |
| 20 | delay 중 Work Mode OFF → press 없음 | `testWorkModeOffBeforeTimerFiresCancelsWithoutPress`(기존) |
| 21 | delay 중 Auto Answer OFF → press 없음 | `testAutoAnswerDisabledDuringDelayCancelsWithoutPress`(신규) |
| 22 | delay 중 lifecycle이 Ringing 이탈 → press 없음 | `testCallEndBeforeTimerFiresCancelsWithoutPress`(기존) |
| 23 | 재검증 성공 시 정확히 1회 press | `testHighConfidenceSingleCandidatePressesExactlyOnce`(갱신) |
| 24 | 중복 poll tick이 복수 press를 만들지 않음 | `testDuplicateEventsForSameCallNeverPressMoreThanOnce`(갱신) |
| 25 | press 실패 시 재시도 없음 | `testPressFailureDoesNotRetry`(갱신) |
| 26-28 | 거절/답장/더 보기는 press 안 됨(동시 존재해도) | `testSiblingBannerControlsNeverReceivePressEvenWhenPresentTogether`(신규) |
| 29-30 | 기존 no-call 베이스라인 유지 | `testNoCallBaselineStillYieldsNoCandidates`(신규) + 기존 `FalsePositiveRegressionTests` 전부 |
| 31 | 수동 응답 경로는 AutoAnswerController 불필요 | `CallLifecycleTrackerTests.testManualAnswerEvidenceTransitionsRingingToActive`(기존, AutoAnswerController 참조 없음) |
| 32-33 | driver 비활성/route 불변 | `IncomingCallObserverTests.testFullCallLifecycleNeverActivatesDriverOrMutatesRoute`(기존) |

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 107/107
- `Scripts/build-app.sh` + headless 실행: PASS, 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인: PASS — Capture/Inject `hidden=true active=false`, route `Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커` 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

## CHECKPOINT 3 — Gate A 실기기 1차 결과: BLOCKED / ACTIVE-EVIDENCE INVESTIGATION (2026-08-15)

| 항목 | 결과 |
|---|---|
| Native 수동 응답(사용자가 직접 "응답" 클릭) | **PASS** |
| 실제 통화 연결 | **PASS** |
| Jarvis Active 감지 | **FAIL** |

Jarvis 로그:

```
[CALL] ringing candidate disappeared without active evidence — treating as ended
[CALL] lifecycle=idle
```

사용자가 focused active snapshot(label=active)을 저장해 실제 active-call 배너 구조를 확보했다.

### 관찰된 실제 ACTIVE 계층 구조

동일한 `FACETIME_NOTIFICATION` 배너가 유지되지만, 자식이 변형된다:

```
com.apple.notificationcenterui
  AXWindow / subrole=AXSystemDialog
    AXGroup / subrole=AXNotificationCenterBanner / identifier=FACETIME_NOTIFICATION
      AXGenericElement description="전화"
      AXGenericElement description=<caller/redacted>
      AXButton description="키패드"              enabled=true  actions⊇[AXPress]
      AXButton description="FaceTime 영상 통화"   enabled=false actions⊇[AXPress]
      AXButton description="소리 끔"              enabled=true  actions⊇[AXPress]
      AXButton description="더 보기"              enabled=true  actions⊇[AXPress]
      AXButton description="종료"                 enabled=true  actions⊇[AXPress]
```

Focused snapshot: `label=active processes=5 windows=5 nodes=88 elapsedMs=277`.

### 상태 차분

| 상태 | 배너 자식 |
|---|---|
| Ringing | 응답 + 거절 (+ 답장/더 보기) |
| Active | 종료 + 소리 끔 + 키패드 (+ 더 보기, + 비활성 FaceTime 영상 통화) |

**핵심 의미론적 정정**: 배너 안에서 활성화된(enabled) `"종료"`는 "이 통화가 이미 종료됨"을 뜻하지 않는다 — "현재 진행 중인 통화에 사용 가능한 종료 컨트롤이 있음"을 뜻한다. 이전 구현은 이 구분을 하지 않았을 뿐 아니라, CHECKPOINT 2에서 전역 키워드 오탐(341개) 문제를 고치면서 `"종료"`/`"키패드"`를 전역 키워드 목록에서 아예 제거해버렸다 — 그 결과 이 라벨들이 진짜 FACETIME_NOTIFICATION 배너 안에 정당하게 등장해도 인식할 방법이 전혀 없었다. 이번 수정의 핵심은 "전역 키워드로 되돌리는 것"이 아니라 — 두 문제(오탐과 미탐) 모두 **동일한 구조적 해법**을 갖는다는 것이다: 이 라벨들은 실제 evidence-locked `FACETIME_NOTIFICATION` 배너의 자손일 때만 call 의미론을 가진다.

## CHECKPOINT 3 — Active Call Evidence Fix

### 구조적 변경

1. **`FaceTimeNotificationCallStateClassifier`(신규, 순수·테스트 가능)** — `[AXElementSnapshot]`을 `.none/.ringing/.active/.ambiguous`로 분류. banner-scope(`bundle=notificationcenterui` + `AXWindow/AXSystemDialog` 조상 + `AXGroup/AXNotificationCenterBanner/FACETIME_NOTIFICATION` 조상) 안의 요소만 검사 대상으로 삼는다.
   - Ringing = 배너 안에 enabled `AXButton description="응답"` **그리고** enabled `AXButton description="거절"` 둘 다 존재.
   - Active = 배너 안에 enabled `AXButton description="종료"` **그리고** (enabled `"소리 끔"` **또는** enabled `"키패드"`) 중 최소 하나 — 독립적인 두 신호를 요구하며 `"종료"` 단독으로는 Active가 되지 않는다.
   - `"더 보기"`는 Ringing/Active 양쪽에 다 나타나므로 상태 구분에 전혀 쓰지 않는다. `"FaceTime 영상 통화"`(비활성으로 관찰됨)는 진단 정보로만 기록하고 분류에 요구하지 않는다(활성화 여부가 달라질 수 있음).
2. **`CallStateEvidenceExtractor` 재작성** — CHECKPOINT 2의 전역 키워드 매칭(`endCallKeywords`/`activeControlKeywords`)을 완전히 제거하고, `endCallButtonPresent`/`activeCallControlsPresent`를 전부 `FaceTimeNotificationCallStateClassifier`의 `.active` 판정 하나로부터 도출한다. 전역 키워드 검색은 이제 어디에도 남아있지 않다 — CHECKPOINT 2의 false-positive 방지가 구조적으로 계속 보장된다.
3. **`IncomingCallObserver.tick()` — 단일 스캔 사이클 수정** (§11): 기존에는 candidate 판정을 위해 `scanCallRelevantElements()`를 한 번, evidence 판정을 위해 `scanner.currentCallStateEvidence()`가 내부적으로 **다시** `scanCallRelevantElements()`를 호출해 총 두 번의 독립적인 AX 스캔이 발생했다 — 그 사이 배너가 변형되면(응답 사라짐, 종료 등장) candidate는 사라졌는데 evidence는 아직 옛 상태를 반영하는 race가 이론적으로 가능했다. 이제 한 번의 `scanCallRelevantElements()` 결과를 candidate 판정과 evidence 판정 양쪽에 그대로 사용한다 — candidate와 evidence가 항상 동일한 스캔 사이클에서 나온다. `SystemAccessibilityClient.currentCallStateEvidence()`/`scanner.currentCallStateEvidence()`는 진단용 `dumpDiagnosticSnapshot()`에서만 계속 사용된다(실시간 lifecycle 판단 경로 아님).
4. **`CallLifecycleTracker`/`AutoAnswerController`/`IncomingAnswerControlMatcher`(Answer 매칭)는 변경하지 않음** — 문제는 업스트림 evidence 추출에 있었으므로 이번에도 그것만 고쳤다. 임의의 타임아웃, 강제 상태 리셋, active 라벨 추측은 추가하지 않았다.

### Safety (재확인)

- Active 판정은 여전히 읽기 전용 — `FaceTimeNotificationCallStateClassifier`는 이미 스캔된 `AXElementSnapshot`만 검사, AX 프레임워크를 직접 호출하지 않음
- AXPress/focus 변경/좌표 클릭/CGEvent/AppleScript/ScreenCaptureKit/private framework 없음
- audio route mutation/driver activation 없음 — 신규·수정 파일 어디에도 CoreAudio import 없음
- Realtime/recording 없음, Auto Answer는 OFF 유지

### Tests

새 테스트 24개 추가(`FaceTimeNotificationCallStateClassifierTests` 신규 17개, `CallLifecycleActiveTransitionTests` 신규 7개), 기존 107개 중 2개는 새 구조적 현실에 맞게 갱신(`testSpecificEndCallPhraseStillCreatesEvidence` → `testEndCallPhraseWithoutBannerContextNeverCreatesEvidence`로 의미 반전, `testFullCallLifecycleNeverActivatesDriverOrMutatesRoute`의 Active 구간을 실제 배너 fixture로 교체), 나머지 전부 유지 — **합계 131개, 131 passed, 0 failed**.

§16 요청 항목 매핑: 1-2(정확한 실제 계층 구조 분류) `testExactRealRingingHierarchyClassifiesRinging`/`testExactRealActiveHierarchyClassifiesActive` · 3-4(구조적 요구사항) `testActiveRequiresFacetimeNotificationBannerAncestor`/`testActiveRequiresNotificationCenterOwner` · 5-7(배너 밖 일반 라벨은 무효) `testGenericEndCallLabelOutsideBannerIsNotActiveEvidence`/`testGenericKeypadInNormalPhoneAppIsNotActiveEvidence`/`testGenericMuteLabelOutsideBannerIsNotActiveEvidence` · 8-9(검증된 종료+소리끔/키패드 → Active) `testVerifiedEndCallPlusMuteClassifiesActive`/`testVerifiedEndCallPlusKeypadClassifiesActive` · 10(종료 단독 불충분) `testEndCallAloneWithoutInCallControlIsNotActive` · 11(더 보기는 구분 불가) `testMoreButtonAloneNeverClassifiesRingingOrActive`/`testMoreButtonPresentInBothRingingAndActiveDoesNotChangeClassification` · 12(FaceTime 영상 통화 불필요) `testActiveClassificationDoesNotRequireFaceTimeVideoCallControl` · 13(Ringing 시그니처) `testRingingRequiresBothAnswerAndReject` · 14(Ringing→Active 전환) `testRingingTransformsToActiveWhenBannerChildrenTransform` · 15(candidate 소실이 강제 Idle 유발 안 함) `testAnswerCandidateDisappearanceDuringTransformationDoesNotForceIdle` · 16(반복 tick간 Active 유지) `testActiveRemainsActiveAcrossRepeatedTicksWhileSignaturePersists` · 17-18(debounce) `testActiveSignatureBriefDisappearanceWithinDebounceRecoversWithRealFixtures`/`testActiveSignatureDisappearingBeyondDebounceEndsCallWithRealFixtures` · 19(no-call 유지) `testNoCallFixtureNeverLeavesIdle` · 20(일반 Phone.app 무영향) `testNoCallBaselineClassifiesNone` · 21(종료≠이미종료) `testEndCallControlPresenceMeansAvailableControlNotAlreadyEnded` · 22(액션 없음, 구조적 보증) `testClassificationNeverPerformsAnyAction` · 23(AutoAnswerController 불필요) `testManualAnswerPathNeverRequiresAutoAnswerController` · 24-25(driver/route 불변) 기존 `IncomingCallObserverTests.testFullCallLifecycleNeverActivatesDriverOrMutatesRoute`(갱신).

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 131/131
- `Scripts/build-app.sh` + headless 실행: PASS, 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인: PASS — Capture/Inject `hidden=true active=false`, route 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

**CHECKPOINT 3 상태 (Active Evidence Fix 적용 후): REQUIRES MANUAL GATE A RETEST** — 그러나 이 재검증에서도 **Active 감지는 다시 실패**했다. 아래 참조.

## CHECKPOINT 3 — Gate A 2차 실기기 결과: 여전히 FAIL, 그러나 새로운 결정적 증거 확보 (2026-08-15)

Active Call Evidence Fix 반영 후 재검증에서도 production lifecycle은 Active를 인식하지 못했다:

```
18:24:17.615  [CALL] lifecycle=ringing
18:24:17.615  [CALL] candidate discovered
(사용자가 native "응답" 클릭, 실제 통화 연결됨)
18:24:20.717  [CALL] ringing candidate disappeared without active evidence — treating as ended
18:24:20.717  [CALL] lifecycle=idle
```

**그러나** 통화가 실제로 계속 연결된 상태에서 Focused Call AX Snapshot을 두 차례 별도로 캡처했다:

| 시각 | processes | windows | nodes |
|---|---|---|---|
| 18:24:26.250 (production이 Idle로 잘못 전환된 지 ~6초 후) | 5 | 5 | 88 |
| 18:24:38.192 (~18초 후) | 5 | 5 | 88 |

두 캡처 모두 이전에 검증된 실제 Active 배너와 정확히 동일한 형태(windows=5, nodes=88)였다 — 즉 **active UI는 사라지지 않고 안정적으로 존재했다.** 이는 "배너가 너무 빨리 사라진다"는 타이밍 가설을 사실상 배제하고, **production 스캔 경로와 focused 진단 경로가 서로 다른 결과를 낸다**는 쪽으로 조사 방향을 바꾸는 결정적 증거였다.

## Root Cause #2: Production/Focused 프로세스 탐색 방식 불일치

`captureFocusedCallAXSnapshot()`(동작함)와 `scanCallRelevantElements()`→`scanProcess()`(실패함) 둘 다 최종적으로는 동일한 `AXRawDiscovery.walk`를 동일한 윈도우 엘리먼트에 대해 호출한다 — 즉 **트리 순회 로직 자체는 이미 공유되고 있었다.** 실제 divergence는 그보다 앞선 **프로세스 탐색 단계**에 있었다:

- `scanProcess()`(구현): `NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")` — bundle identifier로 앱 레지스트리를 직접 조회
- `captureFocusedCallAXSnapshot()`: `NSWorkspace.shared.runningApplications`를 열거한 뒤 bundle identifier로 필터링

두 API는 이론상 같은 결과를 내야 하지만, 실기기 증거가 보여주듯 실제로는 항상 일치하지 않는다 — Notification Center의 배너를 실제로 호스팅하는 시스템 UI 에이전트 프로세스처럼, `NSRunningApplication.runningApplications(withBundleIdentifier:)` API가 안정적으로 찾지 못하는 프로세스가 `NSWorkspace.shared.runningApplications` 열거에는 나타날 수 있다. depth(둘 다 이미 8로 동일), node budget, ancestorChain 전파, subrole/identifier 보존 — 이 모든 것을 코드로 대조 확인했으나 전부 동일했다(§3/§6/§7 조사 결과). **유일한 차이는 프로세스 탐색 API였다.**

### 수정

`scanProcess()`가 `NSWorkspace.shared.runningApplications`를 사용하도록 통일했다(`runningApplication(bundleIdentifier:)` 신규 헬퍼) — focused 진단 경로가 이미 실기기에서 검증된 것과 동일한 메커니즘이다. 두 스캔 경로가 이제 프로세스 탐색·윈도우 순회·ancestry 전파 전부 동일한 코드 경로를 공유한다.

### 추가 진단 계측

- **`FaceTimeNotificationClassificationResult`**(신규) — `classifyWithDiagnostics()`가 반환하는 판정 funnel: `bannerFound`/`ownerMatched`/`systemDialogMatched`/`notificationBannerMatched`/`identifierMatched`/`controlsDetected`/`ringingSignatureMatched`/`activeSignatureMatched`. 어느 구조적 요구사항에서 매칭이 끊겼는지 다음번엔 즉시 알 수 있다.
- **`[CALL-SCAN]` 구조화 로그**(신규, `IncomingCallObserver.tick()`) — 실제 FACETIME_NOTIFICATION 배너가 발견됐을 때만, 알려진 구조적 컨트롤 라벨만(발신자 이름·전화번호·원문 알림 텍스트 전혀 없음) 로깅: `[CALL-SCAN] banner=true owner=com.apple.notificationcenterui windowSubrole=AXSystemDialog controls=응답,거절 ringing=true active=false`.
- **단일 스캔 사이클 보증 재확인** — `IncomingCallObserver.tick()`은 이미 CHECKPOINT 3 앞선 수정에서 candidate/evidence를 동일한 `scanCallRelevantElements()` 결과로부터 도출하도록 고쳐져 있었다(§9 요구사항 기 충족, 이번에 신규 테스트로 재확인).

### Safety (재확인)

- 진단은 여전히 읽기 전용 — `classifyWithDiagnostics`는 이미 스캔된 `AXElementSnapshot`만 검사
- AXPress 없음, Auto Answer OFF 유지
- audio route mutation/driver activation 없음 — 신규·수정 파일 어디에도 CoreAudio import 없음

### Tests

새 테스트 13개 추가(`ProductionFocusedScanParityTests`), 기존 131개 전부 유지 — **합계 144개, 144 passed, 0 failed**.

§11 요청 항목 매핑: 1(ancestry parity) `testProductionStylePipelinePreservesFullAncestryChainForRinging` · 2(FACETIME_NOTIFICATION 조상 포함) `testProductionActiveHierarchyIncludesFacetimeNotificationAncestor` · 3(AXSystemDialog 메타데이터 보존) `testProductionActiveHierarchyPreservesSystemDialogWindowMetadata` · 4(실제 깊이에서 버튼 도달) `testProductionScanReachesButtonsAtRealObservedDepth` · 5(실제 active 계층 분류) `testProductionPipelineClassifiesRealActiveHierarchyAsActive` · 6(실제 ringing 계층 분류) `testProductionPipelineClassifiesRealRingingHierarchyAsRinging` · 7(단일 스캔이 candidate+evidence 공급) `testObserverTickScansExactlyOncePerCycle` · 8(같은 사이클 내 candidate 소실+active → Active) `testObserverTickTransitionsRingingToActiveInSingleTick` · 9(반복 tick간 Active 유지) `testObserverTickKeepsActiveAcrossRepeatedTicks` · 10-11(no-call/일반 Phone.app 무영향) `testObserverTickNoCallBaselineStaysIdleWithNoEvidence` · 12(진단 로깅이 발신자 정보 노출 안 함) `testClassificationDiagnosticsNeverIncludeArbitraryCallerText` + funnel 테스트 2개.

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 144/144
- `Scripts/build-app.sh` + headless 실행: PASS, 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인: PASS — Capture/Inject `hidden=true active=false`, route 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

**CHECKPOINT 3 상태: PRODUCTION/FOCUSED AX PARITY FIX IMPLEMENTED — REQUIRES MANUAL GATE A RETEST** (아직 PASS로 기록하지 않음 — 근본 원인은 코드 대조로 확인했지만, 이 특정 시스템 프로세스 탐색 차이가 실기기에서 진짜 원인이었는지는 다음 Gate A 재검증으로만 최종 확인 가능하다)

## Real Device Validation

**STATUS (3차 재검증 이전) = REQUIRES MANUAL GATE A RETEST — GATE B REMAINS BLOCKED** — 그러나 이번에는 결정적으로 다른 결과를 확인했다: **process discovery/scan parity/classifier 전부 정상 동작이 실기기 로그로 확인됐고, 남은 문제는 lifecycle 타이밍 하나였다.**

## CHECKPOINT 3 — Gate A 3차 실기기 결과: 근본 원인 확정 (2026-08-15)

Production/Focused Parity Fix 반영 후, 사용자가 수동 응답을 다시 테스트했다. 이번에는 `[CALL-SCAN]` 진단 로그가 production 스캐너의 실제 동작을 그대로 보여줬다:

```
18:44:46.071  banner=true controls=답장,더 보기,거절,응답        ringing=true  active=false
18:44:46.824  banner=true controls=답장,더 보기,거절,응답        ringing=false active=false
              [CALL] ringing candidate disappeared without active evidence
              [CALL] lifecycle=idle
18:44:47.674  banner=true controls=답장,더 보기,거절,응답        ringing=false active=false
18:44:48.332  banner=true controls=키패드,FaceTime 영상 통화,소리 끔,더 보기,종료   ringing=false active=true
              (이후 반복적으로 active=true 확인, 통화는 계속 연결된 상태)
```

이 로그는 **CHECKPOINT 2/3에서 고친 모든 것이 실제로 정상 동작함을 증명한다**: process discovery는 Notification Center를 정확히 찾았고, ancestor 메타데이터도 정확했고, FACETIME_NOTIFICATION classifier도 정확히 ringing→(전환 구간)→active를 판별했다. **남은 문제는 순수하게 lifecycle 타이밍이었다.**

**근본 원인**: macOS는 "응답" 클릭 후 배너를 원자적으로 전환하지 않는다. 실측된 전환 구간(첫 non-ringing/non-active 스캔 `18:44:46.824`부터 첫 verified active 스캔 `18:44:48.332`까지)은 **약 1.508초**였다 — 이 구간 동안 ringing 시그니처(응답+거절)는 이미 사라졌지만 active 시그니처(종료+소리끔/키패드)는 아직 나타나지 않는다. 기존 구현은 이 구간을 "발신자가 응답 전에 끊었다"로 즉시 해석해 active가 나타나기도 전에 세션을 닫아버렸다.

## CHECKPOINT 3 — Ringing → Active Transition Grace Fix

### 구조적 변경

`CallLifecycleTracker`에 `answerTransitionGrace`(기본 2.5초 — 실측 ~1.508초에 약 1초의 여유를 더한 값) 신규 추가. `.ringing`/`.answering` 상태에서 ringing 시그니처도 active 시그니처도 없을 때:

- 즉시 Idle로 가지 않고, 기존 세션을 유지한 채 `.answering`(이미 존재하던 상태 — 새 상태를 추가하지 않고 재사용) 상태로 bounded grace를 시작한다.
- grace 도중 **active 시그니처가 나타나면 즉시**(나머지 grace를 기다리지 않고) 같은 세션으로 `.active` 전환.
- grace 도중 **ringing 시그니처가 재등장**하면 pending transition을 취소한다(중복 세션 생성 없음).
- grace가 **만료될 때까지 아무 증거도 없으면** 그제서야 세션을 닫고 Idle로 전환 — 발신자가 응답 전 끊은 경우를 여전히 정확히 처리하되, 최대 2.5초 늦게 감지될 뿐이다(실제로 연결된 통화를 오탐으로 끊는 것보다 훨씬 낫다).
- Active→Idle(통화 종료)은 완전히 별개의 기존 `endDebounceInterval`/`pendingEndSince` 메커니즘을 그대로 사용 — 두 타이머가 섞이지 않는다(§12).

**Stale timer 안전성**: 이 구현은 `Task.sleep`/타이머를 전혀 쓰지 않는다 — 기존 `endDebounceInterval` 데드바운스와 동일하게, `IncomingCallObserver`의 750ms poll tick마다 `update()`가 호출될 때 `now().timeIntervalSince(pendingAnswerTransitionSince!) >= answerTransitionGrace`를 동기적으로 검사할 뿐이다. 별도의 detached Task/타이머가 없으므로 "오래된 타이머 콜백이 새 세션을 잘못 닫는" 문제 자체가 구조적으로 발생할 수 없다.

`FaceTimeNotificationCallStateClassifier`(ringing/active 시그니처 정의)는 전혀 건드리지 않았다 — 문제는 classifier가 아니라 그 결과를 lifecycle이 해석하는 타이밍이었다.

### Safety (재확인)

- 여전히 읽기 전용, AXPress 없음, Auto Answer OFF 유지
- audio route mutation/driver activation 없음
- Work Mode OFF/Bridge 비활성화 시 `tracker.reset()`이 pending transition을 안전하게 취소함(기존 경로 그대로 재사용)

### Tests

새 테스트 24개 추가(`AnswerTransitionGraceTests` 신규 16개 + 기존 `testRingingWithoutActiveEvidenceReturnsToIdleWhenCandidateDisappears`를 grace 동작에 맞게 재작성), 기존 157개 중 위 테스트 1개만 새 동작에 맞게 갱신, 나머지 전부 유지 — **합계 157개, 157 passed, 0 failed**.

§16 매핑: 1 `testRingingSignaturePresentRemainsRinging` · 2 `testRingingSignatureDisappearanceStartsGraceInsteadOfIdle` · 3 `testSameSessionIdSurvivesGraceIntoActive` · 4/7 `testActiveEvidenceAt1_5SecondsTransitionsToActiveImmediately` · 5(실측 시퀀스 재현) `testExactObservedRealTimingSequenceReachesActiveNeverIdle` · 6 `testActiveEvidenceCancelsGraceBeforeExpiry` · 8/9 `testNoActiveEvidenceForFullGraceExpiresToIdle` · 10 `testRingingSignatureReappearanceDuringGraceCancelsPendingEnd` · 11 `testDuplicatePollingDoesNotCreateDuplicateSession` · 12 `testGraceExpiryCannotCloseAnAlreadyActiveCall` · 13 `testOldGraceDeadlineCannotCloseANewerCallSession` · 14 `testWorkModeOffDuringGraceCancelsPendingTransitionSafely` · 15/16 `testNoEvidenceAtAllDuringGraceEventuallyFailsSafelyToIdle` · 17-23(AXPress 없음/Auto Answer 독립/no-call/일반 Phone.app/classifier 불변/driver·route 불변) 기존 테스트 스위트 전체가 이미 커버(`AXRawDiscoveryTests`의 read-only 보증, `FaceTimeNotificationCallStateClassifierTests` 무변경 재확인, `FalsePositiveRegressionTests`, `IncomingCallObserverTests.testFullCallLifecycleNeverActivatesDriverOrMutatesRoute`).

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 157/157
- `Scripts/build-app.sh` + headless 실행: PASS, 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인: PASS — Capture/Inject `hidden=true active=false`, route 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

## CHECKPOINT 3 — Gate A: PASS (2026-08-15, 사용자 실기기 재검증)

Answer Transition Grace Fix 반영 후 재검증에서 전체 수동 응답 lifecycle이 실기기에서 확인됐다:

```
18:56:18.343  [CALL-SCAN] controls=답장,더 보기,거절,응답  ringing=true  active=false
              [CALL] lifecycle=ringing / candidate discovered

18:56:21.340  ringing=false active=false
              [CALL] lifecycle=answering
              [CALL] answer transition grace started graceMs=2500

18:56:22.838  controls=키패드,FaceTime 영상 통화,소리 끔,더 보기,종료   ringing=false active=true
18:56:22.839  [CALL] active evidence acquired during answer transition
              [CALL] lifecycle=active
              (이후 반복 폴링에서 Active 안정적으로 유지)

18:56:34.204  [CALL] lifecycle=ending
18:56:35.531  [CALL] lifecycle=idle
```

| 항목 | 결과 |
|---|---|
| Idle → Ringing | **PASS** |
| Ringing → Answering (grace 진입, Idle로 떨어지지 않음) | **PASS** |
| Answering → Active (verified evidence로) | **PASS** |
| Active 안정성 (반복 폴링 동안 유지) | **PASS** |
| Active → Ending → Idle | **PASS** |
| 세션 동일성 유지 | **PASS** |
| answerTransitionGrace 동작(측정된 갭 대비 여유 있게 동작) | **PASS** |

**CHECKPOINT 3 Gate A = PASS.**

## CHECKPOINT 3 — Gate B 준비: Real Auto Answer Validation Preparation

### 기존 구현 재검토 결과

Gate A가 실기기에서 PASS했으므로, 이미 구현되어 있던 Auto Answer 경로(`AutoAnswerController`/`AnswerCandidateResolver`/`IncomingAnswerControlMatcher`/live revalidation/one-press-per-session)를 처음부터 다시 구현하지 않고 코드 검토와 테스트 보강으로 진행했다. 검토 결과:

- **evidence-locked "응답" 매처**: 변경 없음, 그대로 유지 — `com.apple.notificationcenterui` + `AXWindow/AXSystemDialog` + `AXNotificationCenterBanner/FACETIME_NOTIFICATION` + `AXButton description="응답" enabled=true AXPress지원` 전부 필수
- **지연 실행**: `AutoAnswerController.delaySeconds`(UI Picker에서 이미 선택 가능, 기본 3초) — 하드코딩하지 않음
- **press 직전 실시간 재검증**: 이미 구현됨(`attemptPress`가 `scanner.scanCallRelevantElements()`를 다시 호출 → `AnswerCandidateResolver.resolve()` → 정확히 1개의 HIGH candidate가 **동일한 snapshot id**를 가져야만 press) — CHECKPOINT 3 앞선 작업에서 이미 완료
- **session당 1회 press**: `attemptedSessionIDs` dedup, 실패해도 재시도 없음 — 변경 없음
- **AXPress 격리**: 여전히 `SystemAccessibilityClient.press(_:)` 단 한 곳, 테스트는 전부 `MockAccessibilityScanning` spy 사용, 실제 AXPress는 유닛 테스트에서 절대 발생하지 않음

### 이번에 추가한 것

1. **취소 사유 코드 표준화** (§12/§13) — `cancel(reason:)` 문자열을 사람이 읽는 문구에서 기계적으로 구분 가능한 kebab-case 코드로 정리: `lifecycle-not-ringing`/`work-mode-off`/`auto-answer-disabled`/`candidate-missing`/`candidate-ambiguous`/`revalidation-failed`/`new-call`. Session-already-attempted 케이스는 매 tick마다 반복 발생하므로 의도적으로 로깅하지 않음(§13의 "매 tick마다 취소 로그를 남기지 말 것" 지침을 그대로 따름) — 동작 자체는 변경 없이 로그 문자열만 정리했다.
2. **테스트 보강** — 기존 커버리지 감사 후 §18의 30개 항목 중 실제로 비어 있던 부분만 추가(`AutoAnswerGateBTests` 신규 9개): 3초 delay 설정 확인, revalidation 시점의 ambiguous candidate 처리, `IncomingCallObserver`를 통한 전체 통합 경로에서의 수동 응답/발신자 끊음 취소, "통신 오디오"/일반 Phone.app 컨트롤이 실제 Answer와 함께 스캔되어도 press되지 않음, press 성공이 곧바로 Active를 강제하지 않음(Answering만 표시), press 이후 verified evidence가 Answering→Active를 실제로 이끎(세션 id 유지 확인 포함), 오래된 세션의 대기 중 작업이 새 세션에 영향을 주지 않음.

### Safety (재확인)

- 여전히 읽기 전용 진단 + 단 한 곳의 AXPress
- Auto Answer는 OFF 유지 — 에이전트는 실제 전화를 걸거나 실제 AXPress를 수행하지 않았다
- audio route mutation/driver activation 없음

### Tests

새 테스트 9개 추가(`AutoAnswerGateBTests`), 기존 166개 중 취소 사유 문자열 변경에 의존하는 테스트는 없었음(문자열 assert 없이 카운트/상태만 검증) — **합계 166개, 166 passed, 0 failed**.

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 166/166
- `Scripts/build-app.sh` + headless 실행: PASS, 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인: PASS — Capture/Inject `hidden=true active=false`, route 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

**CHECKPOINT 3 Gate B 상태: IMPLEMENTATION VERIFIED — REQUIRES MANUAL REAL-DEVICE VALIDATION**

## CHECKPOINT 3 — Gate B: PASS (2026-08-15, 사용자 실기기 검증)

실제 Auto Answer가 실기기에서 검증됐다:

| 항목 | 결과 |
|---|---|
| HIGH candidate 감지 | **PASS** |
| Delay 설정(3000ms) | **PASS** |
| Live revalidation PASS | **PASS** |
| AXPress 정확히 1회, 대상="응답" | **PASS** |
| Press result=success | **PASS** |
| lifecycle → Answering | **PASS** |
| verified Active evidence 등장 | **PASS** |
| lifecycle → Active, 안정적 유지 | **PASS** |
| 중복 AXPress 없음 | **PASS** |
| 통화 종료 → Ending → Idle | **PASS** |

**CHECKPOINT 3 Gate B = PASS.**

**관찰(비차단, follow-up 기록용)**: 설정된 delay는 3000ms였으나 실측 schedule→press 간격은 약 4684ms(scheduled `19:07:24.371` → revalidation `19:07:28.826` → press `19:07:29.055`)였다 — 약 1.7초의 추가 지연. Auto Answer 자체는 정확했고(candidate HIGH, revalidation PASS, 정확히 1회 press, 올바른 컨트롤, 실제 통화 연결, lifecycle 완주) 이 타이밍 차이만으로는 Phase 2를 막지 않는다. **OBSERVATION / FOLLOW-UP**으로만 기록하며, 이번 Gate C 준비에서는 폴링 아키텍처를 건드리지 않는다(정적 검토로 명백한 회귀/정확성 버그가 발견되지 않는 한).

## CHECKPOINT 3 — Gate C 준비: Safety Regression

### 코드 검토 결과 (재작성 없음 — Gate C는 검증 위주)

- **CoreAudio 결합 없음**: `Sources/JarvisCallBridge/Call/` 전체에 `import CoreAudio`/`AudioToolbox`가 단 하나도 없음(재확인) — Ringing/Answering/Active/Ending 그 어떤 lifecycle 상태도 구조적으로 오디오를 건드릴 수 없다.
- **영속성 계층 없음**: `Call/`/`App/` 어디에도 `UserDefaults`/파일 기반 상태 저장이 없다. `BridgeViewModel.init()`은 매 실행마다 완전히 새로운 `CallLifecycleTracker`/`AutoAnswerController`/`IncomingCallObserver`를 생성한다 — 즉 "재시작 시 stale 세션 없음"은 별도 리셋 로직이 필요한 게 아니라 애초에 상태를 어디에도 저장하지 않는 구조에서 자동으로 보장된다.
- **Work Mode OFF 경로**: `IncomingCallObserver.tick()`의 `workModeArmedProvider() == false` 분기가 `tracker.reset()` + `autoAnswer.resetForNewCall()`을 호출 — pending Auto Answer/answerTransitionGrace 전부 안전하게 취소됨(기존 코드, 변경 없음).
- 위 모든 이유로 이번 체크포인트는 **코드를 거의 수정하지 않았다** — 취소 사유 로깅 정리(직전 체크포인트)가 마지막 실질 변경이었고, 이번엔 검증 테스트 2개만 추가했다.

### 추가한 테스트

기존 168개 커버리지를 §19의 27개 항목에 대해 감사한 결과, 25개는 이미 기존 스위트(`BridgeStateMachineTests`, `IncomingCallObserverTests.testFullCallLifecycleNeverActivatesDriverOrMutatesRoute`, `AnswerTransitionGraceTests`, `AutoAnswerGateBTests` 등)로 커버되고 있었다. 실제로 비어 있던 2개만 추가(`GateCSafetyRegressionTests` 신규):

- **재시작 베이스라인**(§19-22): `testFreshCallLifecycleTrackerStartsWithNoStaleSession` — 새로 생성된 tracker는 항상 `.idle`/`currentSession=nil`로 시작.
- **"종료"가 Auto Answer에 사용되지 않음**(§19-25): `testEndCallControlNeverBecomesAnswerCandidateOrReceivesPress` — "종료"+"소리 끔"+실제 "응답"이 같은 스캔에 섞여 있어도 candidate는 "응답" 하나뿐이고, press된 id도 "응답" 하나뿐임을 확인.

### Tests

새 테스트 2개 추가, 기존 166개 전부 유지 — **합계 168개, 168 passed, 0 failed**.

### Build

- `swift build`: PASS, 경고 0
- `swift test`: PASS, 168/168
- `Scripts/build-app.sh` + headless 실행 2회(최초 실행 + 재시작) 모두: PASS, 정상 종료, 크래시 없음
- Phase 1 driver regression 재확인: PASS — Capture/Inject `hidden=true active=false`, route 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

**CHECKPOINT 3 Gate C 상태: AUTOMATED REGRESSION PASS — REQUIRES MANUAL REAL-DEVICE VALIDATION**

## Real Device Validation

**Gate A: PASS. Gate B: PASS.**

**Gate C: REQUIRES MANUAL REAL-DEVICE VALIDATION** — 아래 Test A/B/C를 사용자가 직접 수행한다. 에이전트는 실제 전화를 걸거나, 실제 AXPress를 수행하거나, 사용자의 오디오 라우트/드라이버를 건드리지 않는다.

### Test A — Work Mode ON / Auto Answer OFF (가장 중요한 테스트)

1. 최신 빌드 실행. Accessibility=Granted, Work Mode=ON, Bridge State=Armed, **Auto Answer=OFF**.
2. Call State=Idle, Candidates=0, Capture/Inject=Inactive 확인. 현재 Default Input/Output/System Output을 기록해둔다.
3. 실제 셀룰러 착신 1건 → native Mac 착신 UI가 정상적으로 뜨는지, Jarvis가 `Idle → Ringing`으로 전환하는지, **AXPress가 0회**인지 확인.
4. 사용자가 native "응답"을 직접 클릭 → `Ringing → Answering → Active` 확인.
5. 5~10초 이상 연결 유지 → Active 안정 확인.
6. 발신자 종료 → `Active → Ending → Idle`, Candidates=0 확인.
7. Capture/Inject=Inactive, Default Input/Output/System Output 불변 확인.

### Test B — Work Mode OFF 네이티브 동작 회귀 (Test A PASS 후에만)

1. Work Mode=OFF → Bridge State=Disabled 확인. Capture/Inject=Inactive, route 불변 확인.
2. 추가로 실제 셀룰러 착신 1건 → native Mac 착신 UI가 여전히 정상적으로 뜨는지, Jarvis가 어떤 Auto Answer도 시도하지 않는지 확인. 수동으로 받고 끊거나 발신자가 취소해도 무방(길게 통화 유지할 필요 없음).
3. 정상적인 착신 동작, route 불변, driver 비활성 확인.

### Test C — 클린 재시작 (Test B 후에만)

1. 통화가 없는 상태에서 Jarvis Call Bridge를 완전히 종료 후 재실행.
2. Call State=Idle, Candidates=0, stale 세션 없음, 지연된 Auto Answer 없음, Capture/Inject=Inactive, route 불변 확인. (Work Mode 초기값은 현재 제품 동작을 그대로 따르며 이 테스트를 위해 바꾸지 않는다.)

### 로그

Test A/B/C 완료 후 "Save Logs…"로 저장해 공유. 앱이 계속 실행 중이면 로그 하나로 충분하고, Test C에서 재시작했다면 재시작 전/후 로그를 각각 보존한다.

### Gate C FAIL 조건

native 착신 UI 미표시, Work Mode ON이 native ringing을 막음, Auto Answer OFF인데 AXPress 발생, 잘못된 컨트롤이 눌림, Capture/Inject 활성화, route 변경, 수동 응답이 Active에 도달 못함, 통화 종료 후 Idle 미복귀, 통화 종료 후에도 Candidates 잔존, 지연된 Auto Answer가 나중에 발동, Work Mode OFF에서도 native 착신 방해, 재시작 후 stale 세션 복원 — 이 중 하나라도 발생하면 중단하고 로그 보존, Phase 3 진행 금지.

### Phase 2 최종 게이트

Phase 2 최종 PASS는 CHECKPOINT 1/2/Gate A/Gate B 전부 PASS + **Gate C 실기기 PASS**일 때만 부여된다. Phase 2 최종 PASS 이후에만 별도 작업으로 **Phase 3 — Real Call Audio**(Capture/Inject 의도적 활성화 포함)가 시작될 수 있다. 이번 체크포인트에서는 Phase 3에 속하는 어떤 것도 구현하지 않았다 — driver/route/Realtime/recording 전부 미변경.
