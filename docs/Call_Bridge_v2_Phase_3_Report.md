# CB v2 Phase 3 Report — Real Call Audio

작성일: 2026-08-17
최종 판정 (에이전트 단계, 최신 상태 — 아래는 매 체크포인트마다 갱신되며 과거 기록은 하단에 그대로 보존):

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **FINAL PASS** — 실기기: RX, TX 1 kHz, 동시 RX/TX, 연속 2통화, route restore, Active+PCM 중 Work Mode OFF (PCM stop → inject/capture stop → route restore)
- **Phase 3**: **COMPLETE**
- **Phase 4**: 이 문서에서 이어 쓰지 않음 — `docs/Call_Bridge_v2_Phase_4_Report.md`

Phase 2는 CHECKPOINT 1/2, Gate A/B/C 전부 실기기 PASS로 **FINAL PASS**됐다(`docs/Call_Bridge_v2_Phase_2_Report.md` 참조). Phase 3부터의 모든 작업은 이 문서에 기록하며, Phase 2 문서는 더 이상 이어서 작성하지 않는다.

## Scope — CHECKPOINT 1

이번 체크포인트가 구현하는 것은 **오디오 경로 소유권 획득/복원**뿐이다:

- 안전한 call-audio route 획득
- Capture/Inject 활성화
- 검증된 Active 통화 이후의 route takeover
- route 검증(readback)
- 통화 종료 후 정확한 복원
- 실패 시 rollback
- 크래시/재시작 복구 보호
- 위 전부를 검증하기 위한 진단/UI

**구현하지 않은 것**(다음 체크포인트/Phase로 명시적으로 미룸): 실제 RX/TX PCM 스트리밍, Realtime Voice, STT/TTS, 녹음, merged call audio, R2 업로드, Jarvis Agent 연동, Human Takeover 오디오, iPhone Handoff 오디오 로직.

## Architecture

```
RX (미구현, CHECKPOINT 2 예정): 발신자 → Phone.app 통화 오디오 출력 → Default Output=Jarvis Call Capture → Capture loopback → Bridge CoreAudio 입력
TX (미구현, CHECKPOINT 2 예정): Bridge PCM → Jarvis Call Inject 출력 → Inject loopback → Default Input=Jarvis Call Inject → Phone.app → 발신자
```

CHECKPOINT 1은 위 경로의 **라우팅 소유권**만 구현한다 — 실제 PCM이 그 경로를 타고 흐르는지는 검증하지 않는다(§23, CHECKPOINT 2 몫).

### 핵심 안전 불변식

- Idle/Ringing/Answering 동안 오디오 route는 절대 변경되지 않는다 — 오직 검증된 `lifecycle == Active`(Phase 2의 `FaceTimeNotificationCallStateClassifier`가 이미 검증한 evidence)일 때만 획득을 시작한다.
- Default System Output은 **절대** 변경되지 않는다 — 이는 관례가 아니라 구조적 보장이다: `CallAudioRouteControlling` 프로토콜에는 system output을 변경하는 메서드가 아예 존재하지 않는다(§11).
- Work Mode ON(§3의 새 기본값) 자체는 오디오를 전혀 건드리지 않는다 — `BridgeStateMachine.setWorkMode`는 여전히 route/driver mutator를 호출하지 않으며(Phase 0/1부터 불변), `CallAudioSessionController`는 검증된 Active 세션이 있을 때만 동작한다.

### 새 구성요소

| 파일 | 역할 |
|---|---|
| `System/CallAudioRouteSnapshot.swift` | `CallAudioRouteSnapshot`(UID 기반, Codable), `CallAudioRecoveryRecord`(크래시 복구용, Codable), `CallAudioSessionState` enum(`idle/preparing/routed/restoring/failed`), `JarvisAudioDeviceUIDs` 상수 |
| `System/CallAudioRouteControlling.swift` | `CallAudioRouteControlling`/`JarvisAudioDeviceActivating` 프로토콜 + 실제 CoreAudio 구현(`SystemCallAudioRouteController`/`SystemJarvisAudioDeviceActivator`) |
| `System/CallAudioRecoveryStore.swift` | `CallAudioRecoveryStore` 프로토콜 + `FileCallAudioRecoveryStore`(Application Support 하위 JSON 1개 파일) + `InMemoryCallAudioRecoveryStore`(테스트용) |
| `System/CallAudioSessionController.swift` | 오케스트레이터 — takeover/rollback/restore/startup-recovery/route-ownership-loss 상태 기계 |

### 왜 `CallLifecycleTracker`와 분리했는가 (§7)

Call lifecycle("통화가 지금 뭘 하고 있나")과 audio route lifecycle("그것 때문에 CoreAudio에 무엇을 했나")은 서로 다른 관심사이며 실패 모드도 다르다. `CallAudioSessionController`는 `CallLifecycleState`에 새 케이스를 추가하지 않고, `IncomingCallObserver.tick()`이 `tracker.update(...)` 직후 호출하는 `handleLifecycleChange(callState:session:workModeArmed:)` 하나로만 구동된다 — CHECKPOINT 3의 "candidate와 evidence는 동일 스캔 사이클에서" 원칙과 동일하게, 자체 타이머 없이 정확히 같은 폴링 사이클에서 동작한다.

## Route Transaction Design (§12/§13)

**Takeover 순서** (모두 성공해야만 `routed`):

```
1. Capture/Inject 디바이스 존재 확인
2. 현재 route snapshot 획득 (UID 기반)
3. 복구 레코드 저장 (첫 mutation 이전!)
4. Capture 활성화
5. Inject 활성화
6. Default Output → Capture
7. Default Input → Inject
8. readback으로 실제 route 검증 (Output/Input/**SystemOutput 불변** 전부 확인)
9. 상태 = Routed
```

어느 단계든 실패하면 **즉시 rollback**: 원래 snapshot으로 Output/Input을 되돌리고, 이미 활성화된 디바이스만 정확히 비활성화하고, 복구 레코드를 지우고, 이 **call session은 영구적으로 제외**(`excludedSessionIDs`)되어 같은 세션에 대해 다시는 재시도하지 않는다(§13 — "매 poll tick마다 재시도 금지"). Rollback 자체가 실패하면 상태는 `.failed`로 남아 눈에 띄게 표시된다.

**Restore 순서** (정상 종료 — 확정된 `Idle`에서만, `Ending` 단계에서는 트리거하지 않음 — §15):

```
1. 상태 = Restoring
2. Default Output 복원
3. Default Input 복원
4. readback 검증 (System Output 불변 재확인)
5. Inject 비활성화
6. Capture 비활성화
7. 복구 레코드 삭제
8. 상태 = Idle
```

## Session Ownership (§8)

`routeOwnerSessionID`가 정확히 하나의 `CallSession.id`만 소유한다. `.active` 케이스의 가드(`routeOwnerSessionID != session.id`, `state == .idle`)가 동일 세션에 대한 중복 획득을 막고(§27 idempotent), 복원 후에는 `routeOwnerSessionID`/원본 snapshot이 전부 `nil`로 초기화되어 다음 통화가 완전히 새로운 snapshot·소유권을 받는다(§28, leaked metadata 없음).

## Recovery Record Design (§19)

Phase 2는 의도적으로 영속성이 전혀 없었다 — Phase 3는 실제 macOS 오디오 route를 건드리므로 다르다. `CallAudioRecoveryRecord`(version/callSessionID/createdAt/originalInputUID/originalOutputUID/originalSystemOutputUID/targetInputUID/targetOutputUID)를 **첫 route mutation 이전에** 디스크에 쓴다. DB 아님, call lifecycle 상태 아님, 발신자 정보 아님 — 정확히 복구에 필요한 최소 필드만.

## Startup Recovery (§19-21)

`BridgeViewModel.start()`가 Work Mode 자동 armed **이전에** `callAudioSession.performStartupRecovery()`를 호출한다:

- **Case A** (현재 route가 여전히 Jarvis 디바이스를 가리킴 + 원본 디바이스가 존재): 기록된 원본 route로 복원, Jarvis 디바이스 비활성화, 레코드 삭제.
- **Case B** (레코드는 있지만 현재 route가 이미 Jarvis가 아님): 사용자의 현재 선택을 절대 덮어쓰지 않고, 오래된 레코드만 삭제.
- **Case C** (원본 디바이스가 더 이상 존재하지 않음): 대체 디바이스를 추측하지 않고, Jarvis 디바이스만 안전하게 비활성화, 레코드 삭제.

세 경우 모두 System Output에 관련된 메서드 자체가 없으므로 System Output은 절대 건드리지 않는다.

## Rollback / 실패 안전성 (§13/§29)

Capture 활성화 실패·Inject 활성화 실패·Output route 실패·Input route 실패·readback 불일치 — 5가지 실패 지점 전부 rollback을 트리거하며, 부분 적용 상태(예: Output만 Capture이고 Input은 원본)로 절대 남지 않는다(all-or-nothing). 테스트로 5가지 전부 개별 검증.

## Route Ownership Loss (§18)

매 tick마다(`.routed` 상태일 때만) 현재 route가 여전히 Capture/Inject를 가리키는지 확인한다. 사용자가 통화 도중 수동으로 다른 디바이스를 선택하면: `[CALL-AUDIO] route-ownership-lost`를 로깅하고, Jarvis 디바이스를 비활성화하고, 그 세션을 영구 제외 목록에 추가한다 — **사용자와 route를 두고 계속 다투지 않는다.**

## Startup Defaults (§3)

- `BridgeViewModel.start()`가 이제 `setWorkMode(true)`를 호출 — **Work Mode 기본값이 ON으로 바뀌었다**(의도된 제품 결정). Auto Answer는 이미 `AutoAnswerController.isEnabled`가 기본 `true`였으므로 변경 없음.
- Work Mode ON 자체는 여전히 오디오를 전혀 건드리지 않는다 — 실기기 검증 결과, 앱 실행/종료 전후 route와 Capture/Inject 상태가 완전히 동일했다(아래 Build 섹션 참조).

## Structured Logging (§25)

`[CALL-AUDIO] prepare/snapshot/driver capture activated/driver inject activated/default-output -> capture/default-input -> inject/route verification pass/state=routed/restore started/restore verification pass|failed/inject inactive/capture inactive/state=idle/takeover failed stage=.../rollback started/rollback result=.../route-ownership-lost/startup recovery detected/startup recovery result=...` — 발신자 이름/전화번호/알림 원문은 어디에도 로깅하지 않는다.

## UI (§24)

기존 UI에 "Call Audio (Phase 3)" 섹션 추가: Call Audio State / Route Owner(세션 id 앞 8자만) / Original Route Snapshot(Available/None) / Recovery Record(Present/None). Capture/Inject 활성 상태와 Default Input/Output/System Output은 기존 "Call Audio Driver"/route 행을 그대로 재사용(§22 — "새로운 visibility 계약을 만들지 말 것").

## Phase 2 Regression

Phase 2의 전체 168개 테스트가 이번 체크포인트 이후에도 전부 그대로 통과한다 — `AnswerCandidateResolver`/`IncomingAnswerControlMatcher`/`FaceTimeNotificationCallStateClassifier`/`answerTransitionGrace`/process discovery 등 CHECKPOINT 3에서 검증된 로직은 전혀 건드리지 않았다. 유일하게 변경된 기존 코드는 `IncomingCallObserver.tick()`에 한 줄(`callAudioSession?.handleLifecycleChange(...)`) 추가, `BridgeViewModel.start()`에 startup recovery + `setWorkMode(true)` 추가, `statusMessage`의 Active 문구를 route 상태에 맞게 갱신한 것뿐이다.

## Tests

새 테스트 26개 추가(`CallAudioSessionControllerTests` 24개 + `BridgeViewModelPhase3Tests` 2개), 기존 168개 전부 유지 — **합계 194개, 194 passed, 0 failed**. 전부 spy 기반(`CallAudioRouteControllingSpy`/`JarvisAudioDeviceActivatingSpy`/`InMemoryCallAudioRecoveryStore`) — 실제 CoreAudio route를 건드리는 테스트는 하나도 없다(§26).

§31 요청 항목 매핑: 1-3(기본값 ON + 시작 시 오디오 무영향) `BridgeViewModelPhase3Tests.testStartArmsWorkModeAndAutoAnswerByDefaultWithoutTouchingAudio` · 4-6/9/50(비-Active 상태 무변경) `testNonActiveLifecycleStatesNeverMutateRoutesOrActivateDevices` · 7-8/19-20(단일 획득+idempotent+세션 소유) `testVerifiedActiveStartsExactlyOneAcquisitionAndRepeatedTicksAreIdempotent` · 10(UID 정체성) `testRouteSnapshotIdentityIsUIDBased` · 11(mutation 이전 레코드 저장) `testRecoveryRecordPersistedBeforeFirstForwardRouteMutation` · 12-15(정확한 순서) `testTakeoverOperationOrderMatchesSpec` · 16(System Output setter 부재, 구조적) `testCallAudioRouteControllingHasNoSystemOutputSetter` · 17-18(System Output 불변+readback 검증) `testSystemOutputRemainsOriginalAfterTakeover`/`testVerificationMismatchTriggersRollback` · 21-25(5가지 실패 지점 전부 rollback) `test{Capture,Inject}ActivationFailureTriggersRollback`/`test{Output,Input}RouteFailureTriggersRollback` · 26(Ending 단독으로 복원 안 함) `testEndingAloneDoesNotTriggerRestore` · 27-32(확정 Idle 복원 트랜잭션 전체) `testConfirmedIdleRestoresOriginalRoutesDeactivatesDevicesAndClearsRecoveryRecord` · 33-36(비상 복원 경로+idempotent) `testWorkModeOffWhileRoutedRestoresImmediately`/`testEmergencyRestoreOnAppQuitWhileRoutedRestoresImmediately`/`testEmergencyRestoreIsNoOpWhenNotRouted`/`testDuplicateRestoreCallsAreIdempotent` · 37-38(새 세션 완전 분리) `testNewSessionAfterRestoreReceivesFreshOwnershipWithNoLeakedMetadata` · 39-42(startup recovery 3가지 케이스) `testStartupRecoveryRestoresOriginalRoutesWhenCurrentlyOnJarvisDevices`/`testStartupRecoveryDoesNotOverwriteUserRoutesWhenAlreadyNonJarvis`/`testStartupRecoveryFailsSafelyWhenOriginalDeviceMissing` · 43(route ownership loss) `testUserRouteOwnershipLossIsDetectedAndNotFoughtIndefinitely` · 44-46(PCM/Realtime/recording 객체 없음, 구조적) `testNoPCMStreamingRealtimeOrRecordingObjectsExist` · 47-49(Phase 2 회귀) 기존 168개 테스트 그대로 통과.

## Build

- `swift build`(전체 클린 빌드 `rm -rf .build` 후): **PASS**, 경고 **0**
- `swift test`: **PASS**, 194/194
- `Scripts/build-app.sh` + headless 실행: **PASS**, 정상 종료, 크래시 없음
- **실행 전/실행 중/종료 후 3회 비교**: `JarvisAudioDriverTool status` 결과가 완전히 동일 — Capture/Inject `hidden=true active=false` 유지, route `Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커` 불변. Work Mode가 이제 자동으로 ON이 되었음에도(§3) 실제 통화가 없으므로 오디오는 전혀 변경되지 않았다는 것을 실기기로 확인.
- `~/Library/Application Support/com.jarvis.callbridge/` 확인: 실제 통화가 없었으므로 복구 레코드 파일 생성 안 됨(예상대로).
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

## Manual CHECKPOINT 1 Real-Device Validation

에이전트는 실제 전화를 걸거나, 실제 route를 바꾸거나, 오디오 디바이스를 활성화하지 않았다. 아래는 사용자가 직접 수행한다.

**이번 첫 오디오 라우팅 테스트는 임시로 Auto Answer=OFF, 수동 응답을 사용한다** (제품 기본값은 ON/ON이지만, 첫 route mutation 테스트는 call lifecycle과 새 오디오 라우팅 동작을 분리해서 확인하기 위해 의도적으로 수동 응답으로 진행).

**Initial**: Accessibility=Granted, Work Mode=ON(자동), Auto Answer=OFF(수동 전환), Call State=Idle, Capture/Inject=Inactive. Default Input/Output/System Output을 기록해둔다(ORIGINAL_*).

**Incoming**: 실제 셀룰러 착신 1건 → `Idle → Ringing`. Ringing 동안 route는 반드시 ORIGINAL 그대로, Capture/Inject는 반드시 Inactive.

**Manual Answer**: native "응답" 클릭 → `Ringing → Answering`. Answering 동안에도 route는 여전히 ORIGINAL 그대로, Capture/Inject는 여전히 Inactive.

**Verified Active**: lifecycle이 `Active`가 되는 순간 기대값 — Capture=Active, Inject=Active, Default Output=Jarvis Call Capture, Default Input=Jarvis Call Inject, Default System Output=정확히 ORIGINAL_SYSTEM_OUTPUT, Call Audio State=Routed. 5~10초 연결 유지(무음이어도 무방 — 이 체크포인트는 PCM을 검증하지 않는다).

**Remote hangup**: 발신자 종료 → `Active → Ending → Idle`, 이어서 Default Input=ORIGINAL_INPUT, Default Output=ORIGINAL_OUTPUT, Default System Output=ORIGINAL_SYSTEM_OUTPUT, Capture/Inject=Inactive, Call Audio State=Idle, Recovery Record=None.

**증거 저장**: "Save Logs…", 필요하면 route 상태 스크린샷도 함께.

### FAIL 조건

Active 이전 route 변경, Idle/Ringing/Answering 동안 Capture 또는 Inject 활성화, 둘 중 하나만 활성화(부분 적용), System Output 변경, rollback 없는 takeover 실패, 통화 종료 후 원본 Input/Output 미복원, 통화 종료 후에도 Capture 또는 Inject 활성 유지, 성공적인 복원 후에도 recovery record 잔존, 앱이 native 착신을 받지 못하게 됨, Phase 2 lifecycle 회귀 — 하나라도 발생하면 로그 보존 후 반복 재시도 없이 CHECKPOINT 2로 진행하지 않는다.

## Next Checkpoint

사용자가 실기기 CHECKPOINT 1 증거를 제공하고 PASS로 판정된 이후에만: **Phase 3 CHECKPOINT 2 — CoreAudio Direct I/O + Deterministic RX/TX PCM Validation**(실제 Capture PCM 읽기, Inject에 결정적 PCM 쓰기, 원격 RX/TX 검증)로 진행한다. Realtime Voice는 여전히 Phase 4다. 에이전트가 자동으로 다음 체크포인트로 진행하지 않는다.

---

## CHECKPOINT 1 — 첫 실기기 시도: FAIL (Route Verification Settling + Recovery Record 정리 문제)

사용자가 위 Manual CHECKPOINT 1 절차로 실제 통화 1건을 테스트했다. 결과: **FAIL**. 두 가지 독립된 버그가 실기기 로그로 확인되었다.

### 실기기 증거

| 확인 항목 | 결과 |
|---|---|
| Active 이전 route 변경 없음 | PASS |
| Phase 2 lifecycle (Ringing→Answering→Active) | PASS |
| Capture/Inject 활성화 호출 | PASS |
| Default Output/Input setter 성공 | PASS |
| **즉시 readback 검증** | **FAIL** — `takeover failed stage=verification` |
| rollback 호출됨 | PASS |
| route가 시각적으로 원본으로 복귀 | PASS |
| rollback 후 Capture/Inject 시각적으로 Inactive | PASS |
| **rollback 이후 Recovery Record** | **FAIL** — 계속 "Present"로 남음 (Active→Ending→Idle 완료 이후에도) |

실기기 로그 타임스탬프 (동일 밀리초 내에 prepare→snapshot→capture/inject activated→output/input setter 성공→검증 실패→rollback 성공까지 전부 발생):

```
14:40:35.070  prepare / snapshot / driver capture activated / driver inject activated
14:40:35.070  default-output -> capture / default-input -> inject
14:40:35.079  takeover failed stage=verification
14:40:35.079  rollback result=success  (route는 복귀했으나 Recovery Record는 이후에도 잔존 관찰됨)
```

### Bug 1 — Route Verification Settling (PRIMARY HYPOTHESIS, 실기기로 아직 최종 확정되지 않음)

**PRIMARY HYPOTHESIS** (사실로 확정된 것이 아니라, 이번 수정과 다음 실기기 재검증으로 검증해야 할 가설): `AudioObjectSetPropertyData`가 `noErr`를 반환해도 CoreAudio의 default-device 프로퍼티 변경이 그 직후의 `AudioObjectGetPropertyData` 단일 readback에서 곧바로 관찰 가능하다는 보장이 없다. 이전 구현은 setter 성공 직후 단 한 번의 즉시 readback으로 검증했기 때문에, 이 settling 지연이 실제 원인이라면 항상 검증 실패로 오판했을 것이다. 이 가설이 틀렸을 가능성(예: 실제로는 setter가 진짜로 실패했는데 반환값만 성공이었다든가, 다른 타이밍 이슈)도 완전히 배제하지는 못하며, 다음 실기기 재검증에서 "route verification pass attempts=N"이 attempts>1로 관측되는지가 이 가설의 직접적 증거가 된다.

**수정**: 즉시 단일 readback을 `waitForRouteConvergence(target:)` — bounded async polling (기본 `convergenceMaxAttempts=10`, `convergencePollNanoseconds=75_000_000` ≈ 750ms 상한, poll 사이 `Task.sleep`)으로 교체했다. Output/Input/System Output 셋 다 일치해야 수렴으로 간주하며, 일치가 관측되는 즉시 반환(불필요한 대기 없음), 상한 도달 시 각 필드별 최종 일치 여부(`inputMatch`/`outputMatch`/`systemOutputMatch`)와 함께 타임아웃으로 실패 처리한다. `@MainActor` 컨텍스트 안에서 `await Task.sleep`을 사용하므로 메인 스레드를 블로킹하지 않는다(Swift 6 strict concurrency 유지, `MainActor.assumeIsolated` 등 우회 없음).

동일한 bounded convergence를 **forward takeover 검증 / rollback 이후 route 복원 검증 / 정상 restore(통화 종료) 검증** 세 곳 모두에 동일하게 적용했다(사용자가 명시적으로 요구한 대로 forward 경로만 고치지 않음).

새 로그: `[CALL-AUDIO] route verification waiting session=...` → 성공 시 `route verification pass attempts=N elapsedMs=N session=...`, 실패 시 `route verification timeout attempts=N elapsedMs=N inputMatch=... outputMatch=... systemOutputMatch=... session=...`. rollback/restore 쪽도 각각 `rollback route restoration timeout ...` / `restore verification pass|failed attempts=... elapsedMs=...`로 동일한 필드를 로깅한다. 발신자 정보는 어디에도 없다.

### Bug 2 — Recovery Record가 rollback 성공 이후에도 잔존

**조사 결과 (추측 아님, 코드 직접 검사로 확인)**: 원인은 A(디스크에 실제로 남음)와 B(삭제는 됐으나 UI가 갱신 안 됨) 둘 중 하나로 단정할 수 없는 **더 근본적인 설계 결함**이었다 — 이전 구현의 `FileCallAudioRecoveryStore.clear()`는 `try? FileManager.default.removeItem(...)`으로 실패를 조용히 삼켰고, `hasPersistedRecoveryRecord`(UI가 구독하는 `@Published` 플래그)는 `clear()` 호출 자체의 성공 여부와 무관하게 별도로 관리되고 있었다 — 즉 A(삭제 실패)와 B(UI 비동기화) 두 가능성을 코드가 동시에 내포하고 있었고, 실기기 로그만으로는 어느 쪽인지 확정할 수 없었다.

**수정** (두 가능성을 동시에 제거): 
1. `CallAudioRecoveryStore.clear()`가 `@discardableResult` **`Bool`**을 반환하도록 프로토콜 자체를 변경 — 파일이 이미 없으면 `true`, 실제로 삭제 성공하면 `true`, 삭제 시도가 예외를 던지면 `false`(더 이상 `try?`로 삼키지 않음).
2. `hasPersistedRecoveryRecord`는 이제 **항상** save/clear 시도 직후 `recoveryStore.load() != nil`로 다시 읽어서 계산한다 — `clear()`가 반환한 값이나 이전 상태를 신뢰하지 않고, 매번 스토어의 실제 현재 상태를 그대로 반영한다(stale cached boolean 제거).
3. `rollback(...)`의 성공 판정을 강화 — Output 복원, Input 복원, Capture/Inject 비활성화, **route convergence 완료**, **그리고 recovery record 삭제 확인(`!clearRecoveryRecord()`이면 즉시 실패로 전환)**까지 전부 만족해야 `rollback result=success`를 로깅한다. 하나라도 실패하면 정확히 어떤 postcondition이 실패했는지 로깅(`rollback route restoration timeout ...` 또는 `rollback recovery-record deletion failed session=...`)하고 `rollback result=failure`로 보고한다.
4. `restore(reason:)`(정상 종료 경로)도 동일하게 `clearRecoveryRecord()`의 반환값을 확인하고 실패 시 `restore recovery-record deletion failed session=...`를 로깅한다.

### 비동기 전파에 따른 구조 변경 (Bug 1 수정의 파급 효과)

`waitForRouteConvergence`가 `await Task.sleep`을 쓰므로 `CallAudioSessionController`의 `handleLifecycleChange`/`attemptTakeover`/`rollback`/`restore`/`emergencyRestore`가 전부 `async`로 바뀌었다. 이로 인해:

- `IncomingCallObserver.tick()`도 `async`가 되었고, 750ms `Timer`가 다음 tick을 발화시킬 때 이전 tick의 convergence polling이 아직 끝나지 않았을 가능성이 생겨 **재진입 방지 가드**(`isTicking` bool + `defer`)를 추가했다 — 겹치는 tick이 같은 `CallLifecycleTracker`/`CallAudioSessionController` 상태를 동시에 건드리는 경쟁을 막는다.
- `AppDelegate`의 앱 종료 훅을 동기적인 `applicationWillTerminate(_:)`(내부에서 `MainActor.assumeIsolated`로 우회하던 방식)에서, `await`를 정식으로 호스팅할 수 있는 `applicationShouldTerminate(_:) -> .terminateLater` + `NSApp.reply(toApplicationShouldTerminate:)` 패턴으로 교체했다 — `emergencyRestore(reason: "app-quit")`가 완료된 뒤에만 실제로 종료된다.

Phase 2 로직(Answer matcher, call classifier, answer transition grace, lifecycle state semantics, Auto Answer)은 이번 수정에서 **전혀 건드리지 않았다** — 실기기 로그에서도 이번 실패한 CHECKPOINT 1 시도 동안 Phase 2 lifecycle 자체는 다시 PASS로 확인되었다.

### 새 테스트 (§16, 13개 추가)

`CallAudioSessionControllerTests`에 13개 신규 테스트 추가 — 기존 194개 전부 유지, **합계 207개, 207 passed, 0 failed**:

- `testConvergenceSucceedsImmediatelyWithoutUnnecessaryPolling` — 즉시 관측되면 불필요한 추가 폴링 없음
- `testConvergenceSucceedsAfterOneStaleReadbackThenTarget` / `testConvergenceSucceedsAfterMultipleStaleReadbacksWithinDeadline` — 오래된 readback 이후 target이 데드라인 내 관측되면 성공
- `testConvergenceNeverConvergesTimesOutAtBoundedAttemptsThenRollsBack` — 영원히 수렴하지 않으면 정확히 bounded attempt 수에서 타임아웃 후 rollback (forward/rollback 양쪽 모두 bound 확인)
- `testOutputConvergesBeforeInputStillWaitsForBothToConverge` / `testInputConvergesBeforeOutputStillWaitsForBothToConverge` — 한쪽만 먼저 일치해도 양쪽 다 일치할 때까지 대기
- `testSystemOutputMismatchFailsVerificationEvenWhenInputOutputMatch` — Input/Output이 일치해도 System Output 불일치면 검증 실패
- `testNormalRestoreUsesBoundedConvergencePolling` — 정상 restore도 bounded convergence 사용
- `testRollbackRouteRestorationConvergesAfterStaleReadbackAndStillReportsSuccess` — rollback도 bounded convergence 사용, 오래된 readback을 견디고 성공 보고
- `testRollbackCannotReportFullSuccessWhenRecoveryRecordDeletionFails` — recovery record 삭제 실패 시 rollback이 success를 보고할 수 없음
- `testSuccessfulRollbackLeavesRecoveryRecordAbsentAndUIReflectsIt` — 완전히 성공한 rollback은 record를 반드시 삭제하고 UI 플래그도 반영
- `testSuccessfulTakeoverLeavesRecoveryRecordPresentWhileRouted` — Routed 상태에서는 record가 존재하는 것이 정상(크래시 복구용)
- `testRepeatedActiveAfterFailedTakeoverNeverRetriesExcludedSession` — 실패한 세션은 이후 몇 번을 다시 관찰해도 재시도하지 않음
- 기존 `testConfirmedIdleRestoresOriginalRoutesDeactivatesDevicesAndClearsRecoveryRecord`에 `hasPersistedRecoveryRecord == false` assertion 추가(§16 items 15/18)

### Build (재검증)

- `rm -rf .build && swift build --build-tests`: **PASS**, 경고 **0**, 에러 **0**
- `swift test`: **PASS**, **207/207** (기존 194 + 신규 13, 회귀 없음)
- `Scripts/build-app.sh`: **PASS**, 앱 번들 정상 빌드/서명
- `JarvisAudioDriverTool status`: **PASS** — Capture/Inject `hidden=true active=false` 유지, route `Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커` 완전히 불변(Phase 1 불변 조건 확인)
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

### 재검증 실기기 절차 (§19와 동일한 형식)

**Manual retest: REQUIRED.** 이번 절차는 위 "Manual CHECKPOINT 1 Real-Device Validation" 섹션과 동일하되, 다음 관측을 추가로 확인한다:

1. 단일 실제 통화, Work Mode ON(자동), Auto Answer OFF(수동 응답).
2. Active 진입 시: Capture=Active, Inject=Active, route가 Jarvis 디바이스로 전환, Call Audio State=**Routed**, **Recovery Record=Present**(이번엔 이게 정상 기대값 — 크래시 복구를 위해 Routed 동안은 존재해야 함).
3. 로그에서 `route verification pass attempts=N elapsedMs=N`이 관측되는지 확인 — `attempts` 값이 1보다 크게 나오면 Bug 1의 PRIMARY HYPOTHESIS(비동기 settling)가 실기기로 뒷받침된 것이다.
4. 상대방 종료 → Idle 전환 후: route가 정확히 ORIGINAL로 복원, Capture/Inject=Inactive, Call Audio State=Idle, **Recovery Record=None**(이번 재검증의 핵심 확인 대상).
5. Phase 2 lifecycle(Ringing→Answering→Active→Ending→Idle)이 이번에도 그대로 PASS인지 재확인(로직을 건드리지 않았으므로 회귀가 없어야 한다).

### 현재 게이트 상태

- **Phase 3 CHECKPOINT 1**: **BLOCKED — REQUIRES FIX + REAL-DEVICE RETEST** (이번 수정 완료, 실기기 재검증 대기)
- **Phase 3 CHECKPOINT 2**: **BLOCKED**
- **Phase 4**: **BLOCKED**

에이전트는 이번 세션에서 실제 전화를 걸거나, PCM/Realtime을 시작하거나, CHECKPOINT 2로 진행하지 않았다.

---

## CHECKPOINT 1 — 두 번째 실기기 시도: FAIL (CoreAudio Default Route Setter 근본원인 확정)

Bounded convergence 수정 이후 사용자가 재시도한 두 번째 실기기 테스트도 **FAIL**했다. 이번에는 convergence가 timeout까지 전부(10회, 711ms) 소진되었고 Input/Output 둘 다 끝내 수렴하지 않았다 — "CoreAudio settling 지연" 가설이 약화되었고, 사용자 지시에 따라 timeout을 늘리지 않고 근본원인을 코드/실기기 증거로 조사했다.

### 실기기 증거 (두 번째 시도)

```
15:20:58.446  lifecycle=active
15:20:58.446  [CALL-AUDIO] prepare / original route snapshot
15:20:58.451  driver capture activated
15:20:58.452  driver inject activated
15:20:58.454  default-output -> capture   (setter "성공" 경로 도달)
15:20:58.455  default-input -> inject     (setter "성공" 경로 도달)
15:20:58.455  route verification waiting
15:20:59.166  route verification timeout attempts=10 elapsedMs=711 inputMatch=false outputMatch=false systemOutputMatch=true
              → rollback 성공, UI도 Input/Output이 원본 그대로였음을 확인
```

Recovery Record 정리(이전 수정)는 이번에도 실기기에서 정상 동작 — rollback 이후 및 통화 종료 이후 모두 Recovery Record=None. **이 동작은 이번 조사에서 건드리지 않았다.**

### 근본원인 (코드 조사 + 실기기 read-only 증거로 확정)

`AudioDriver/Plugin/PlugInInterface.c`의 `Driver_GetPropertyData`에서 `kAudioDevicePropertyDeviceCanBeDefaultDevice`가 **모든 scope에서 항상 0(false)을 반환하도록 하드코딩**되어 있었다 — Phase 1 당시 "이 드라이버가 시스템 기본 입력/출력이 되는 것을 절대 막는 안전장치"로 의도적으로 설계된 것(코드 주석에 명시됨). CoreAudio(coreaudiod)는 대상 디바이스가 `CanBeDefaultDevice=false`를 보고하면, `AudioObjectSetPropertyData(kAudioHardwarePropertyDefault{Output,Input}Device)` 요청 자체는 `noErr`로 accept하면서도 실제 route 변경은 절대 커밋하지 않는다 — 이것이 정확히 실기기에서 관찰된 증상("setter는 성공 경로였지만 readback이 끝까지 수렴 안 함")과 일치한다.

**실기기 read-only 증거** (설치되어 있던, 아직 고치기 전 드라이버 대상 — mutate 없이 `JarvisAudioDriverTool inspect`로 확인, 이번 세션에서 새로 추가한 커맨드):

```
--- Jarvis Call Capture (deviceID=182) ---
  hidden: true / alive: true / running: false
  canBeDefaultDevice(output): false
  canBeDefaultDevice(input): false
  canBeDefaultSystemDevice(output): false
  channels: output=2 input=2   streams: output=1 input=1   nominalSampleRate: 48000.0

--- Jarvis Call Inject (deviceID=186) ---
  (Capture와 동일한 패턴 — canBeDefaultDevice(output/input) 모두 false)

Current default route: Output=Smart M80C(4C2D...) Input=Microphone(EPOS B20) SystemOutput=Mac Studio 스피커
```

UID→AudioDeviceID resolve는 두 디바이스 모두 정상(round-trip 일치, `deviceID(forUID:)`가 매번 재조회하므로 activation 전후 stale ID 문제도 구조적으로 없음 — §17-18 가설은 기각). Stream 방향(Capture output/input 각각 2ch, Inject 동일)도 정상 — 방향성 문제 아님. Property existence/settable(§5) — `kAudioHardwarePropertyDefault{Output,Input}Device`는 `kAudioObjectSystemObject`에서 항상 존재+settable(시스템 프로퍼티 자체는 항상 세팅 가능 — 문제는 "세팅 가능한 프로퍼티"가 아니라 "그 값으로 세팅해도 대상 디바이스가 자격 미달"이라는 점). `kAudioHardwarePropertyDevices` 일반 열거(enumeration)에서는 두 Jarvis 디바이스가 **hidden 상태일 때 빠질 수 있음**을 이번에 확인(§7 관련 부가 발견) — 그래서 `inspect` 커맨드는 UID 직접 resolve로 두 디바이스를 항상 명시적으로 조회한다.

### 수정 (드라이버, 최소 범위)

`AudioDriver/Plugin/PlugInInterface.c`:
1. `kAudioDevicePropertyDeviceCanBeDefaultDevice`를 `atomic_load(&device->isActive)`에 연동 — 기존 `IsHidden`과 정확히 같은 토글 시점(§Ract 커스텀 프로퍼티 setter)에서 함께 바뀐다. Idle(비활성)일 때는 여전히 항상 false(Phase 1 안전 의도 100% 보존), Jarvis가 명시적으로 활성화한 그 짧은 구간에서만 true.
2. `kAudioDevicePropertyDeviceCanBeDefaultSystemDevice`는 **의도적으로 그대로 항상 false** — `CallAudioRouteControlling`에 System Output setter가 아예 없다는 기존 불변조건(§11)을 코드 레벨에서 한 번 더 보강.
3. `AudioServerPlugInHostRef`를 `Driver_Initialize`에서 저장해두고, Active 토글 시 `PropertiesChanged(IsHidden, CanBeDefaultDevice)`로 호스트에 통지 — `AudioServerPlugIn.h` 자체 문서("IO/구조에 영향 없는 상태 변화는 PropertiesChanged, 있으면 RequestDeviceConfigurationChange")에 따라 이 종류의 변화에 정확히 맞는 API. 이게 없으면 coreaudiod가 캐시된(등록 시점의) `CanBeDefaultDevice=false`를 계속 참조할 위험이 있다.

**중요한 부수 발견 및 즉시 수정**: 위 변경 직후 `AudioDriver/build/selftest`를 재실행했을 때 **SIGSEGV로 크래시**했다 — 기존 `selftest.c`의 더미 host(`AudioServerPlugInHostInterface dummyHost = { 0 }`)가 `PropertiesChanged` 함수 포인터를 null로 두고 있었고, 새 드라이버 코드가 그 null을 실제로 호출하면서 발생. 실제 coreaudiod는 항상 완전한 host interface를 제공하므로 이 크래시는 실제 설치 환경에서는 발생하지 않을 것으로 판단되지만(§27 — 추측성 변경 금지 원칙에 따라, 이 대체제 사실 자체는 코드 검사로 확정, 실제 coreaudiod 크래시 여부는 검증 안 됨), **설치 전에 in-process에서 이 크래시를 잡을 수 있었다는 것 자체가 selftest의 존재 가치를 증명한다.** `selftest.c`에 `StubPropertiesChanged`를 추가해 더미 host에 연결하고, 이 크래시가 재발하지 않는지 + `CanBeDefaultDevice`가 Active 토글에 맞춰 정확히 바뀌는지 + `PropertiesChanged`가 실제로 호출되는지를 검증하는 8개의 새 체크를 추가했다. **드라이버는 여전히 설치되지 않았다** — `Scripts/build-driver.sh`만 실행했고 `install-driver.sh`는 실행하지 않았다(에이전트가 sudo/install을 실행한 적 없음, 규칙 준수).

`Sources/JarvisCallBridge/System/CallAudioRouteControlling.swift` (진단 강화, 로직 변경 아님):
- `SystemCallAudioRouteController`/`SystemJarvisAudioDeviceActivator`에 `BridgeLogger`를 주입해 `[CALL-AUDIO-COREAUDIO]`/`[CALL-AUDIO-DEVICE]` 라인을 남긴다 — 정확한 OSStatus, UID round-trip 결과, property existence/settable 결과, setter 직전/직후 readback을 매 시도마다 기록(§4/§5/§6/§12). Property가 settable하지 않으면 convergence polling에 들어가지 않고 즉시 실패 처리(§14).
- `SystemJarvisAudioDeviceActivator`는 이제 Active 세팅 직후 실제 `Ract` 값을 다시 읽어 확인 — 세터가 noErr을 반환했지만 실제로 상태가 안 바뀌었다면 실패로 취급(§19, defense-in-depth — 이 커스텀 프로퍼티 자체는 동기적으로 적용되므로 실전에서 불일치가 관찰될 것으로 기대하지는 않는다).
- `CallAudioSessionController`의 convergence timeout 로그에 이제 expected/observed Input/Output/SystemOutput UID가 전부 포함된다(§13).
- Swift 6 동시성: `CallAudioRouteControlling`/`JarvisAudioDeviceActivating` 프로토콜을 `@MainActor`로 선언(로거 호출이 MainActor-isolated라서 필요) — 실제 호출부는 이미 전부 `@MainActor`인 `CallAudioSessionController`였으므로 런타임 동작 변화 없음.

`Sources/JarvisAudioDriverTool/`: 새 READ-ONLY 커맨드 `inspect` 추가(`Commands.swift`/`CoreAudioHelpers.swift`/`main.swift`) — `AudioObjectSetPropertyData`를 절대 호출하지 않고, Jarvis Capture/Inject를 UID로 직접 resolve해 hidden/alive/running/canBeDefaultDevice/canBeDefaultSystemDevice/sampleRate/channels/streams를 출력하고, 현재 Default Output/Input/SystemOutput identity와, 발견되면 AITakeCall 디바이스(비교 참고용, read-only)도 출력한다.

### Phase 2 / 기존 동작 영향

Phase 2 로직(Answer matcher, call classifier, answer transition grace, lifecycle state semantics, Auto Answer)은 이번에도 전혀 건드리지 않았다. `docs/Call_Bridge_v2_Phase_2_Report.md`는 이전 세션에서 이미 FINAL PASS로 기록된 상태 그대로 유지된다.

### 테스트

이번 조사에서 변경된 것은 (a) 드라이버 C 코드(테스트는 `AudioDriver/build/selftest`로 in-process 검증 — XCTest가 아니라 실제 vtable을 dlopen해 실행하는 별도 real 검증), (b) `SystemCallAudioRouteController`/`SystemJarvisAudioDeviceActivator`의 진단 로깅(실제 CoreAudio 호출 자체는 spy가 이미 완전히 추상화하고 있어 XCTest로는 검증 불가능한 영역 — 정직하게 그렇게 기록한다), (c) 새 read-only CLI 커맨드다. 기존 207개 spy 기반 테스트는 로직 변화가 전혀 없으므로 전부 그대로 유지·통과한다 — **합계 207개, 207 passed, 0 failed** (신규 XCTest 추가 없음, 신규 검증은 selftest 8건 + 실기기 read-only `inspect` 실행으로 커버).

### Build / 실기기 read-only 검증

- `rm -rf .build && swift build --build-tests`: **PASS**, 경고 **0**, 에러 **0**
- `swift test`: **PASS**, **207/207**
- `Scripts/build-app.sh`: **PASS**
- `Scripts/build-driver.sh`: **PASS** (plain clang, sudo 없음, `/Library/Audio/Plug-Ins/HAL`에 설치 안 함)
- `AudioDriver/build/selftest`: **0 failure(s)** — CanBeDefaultDevice가 Active=true일 때 1, Active=false일 때 다시 0으로 바뀌는 것, PropertiesChanged가 두 번(활성화/비활성화 각각) 호출되는 것, CanBeDefaultSystemDevice는 Active와 무관하게 항상 0인 것을 전부 확인
- `JarvisAudioDriverTool inspect` (READ-ONLY, 실기기, 아직 미설치 상태의 기존 드라이버 대상): **실행 완료** — 위 "실기기 read-only 증거" 섹션에 결과 기록. 이 커맨드는 `AudioObjectSetPropertyData`를 전혀 호출하지 않는다.
- `JarvisAudioDriverTool status`(Phase 1 불변조건): Capture/Inject `hidden=true active=false`, route `Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커` — 실행 전후 불변
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

### 재검증에 필요한 사용자 조치 — 이번엔 설치가 필요하다

**이전 수정과 달리, 이번 수정은 실제로 검증하려면 사용자가 드라이버를 재설치해야 한다** (에이전트는 `install-driver.sh`/`uninstall-driver.sh`를 절대 실행하지 않음 — 규칙):

1. `cd bridge && ./Scripts/uninstall-driver.sh` (사용자가 직접 실행 — 기존 설치된 드라이버 제거, coreaudiod 재시작 포함)
2. `./Scripts/install-driver.sh` (사용자가 직접 실행 — 이번 세션에서 새로 빌드된 `AudioDriver/build/JarvisCallAudio.driver` 설치)
3. `swift run JarvisAudioDriverTool inspect` 재실행 — `canBeDefaultDevice(output/input)`이 Idle 상태에서는 여전히 `false`인지 먼저 확인(Phase 1 안전장치가 유지됐는지)
4. 위 "Manual CHECKPOINT 1 Real-Device Validation" 절차대로 실제 통화 1건 재시도. 이번엔 Active 진입 시 로그에서 `route verification pass attempts=N elapsedMs=N`이 나오는지(그리고 이제 `[CALL-AUDIO-COREAUDIO] operation=set-default-output/input ... osStatus=0 result=success`도 함께) 확인한다.
5. 여전히 수렴 안 되면 이번엔 `[CALL-AUDIO-COREAUDIO]`/`[CALL-AUDIO-DEVICE]` 로그 라인 전체를 보존해서 공유 — 정확한 OSStatus와 즉시-readback 값이 다음 조사의 출발점이 된다.

### 현재 게이트 상태

- **Phase 3 CHECKPOINT 1**: **BLOCKED — REQUIRES DRIVER REINSTALL + REAL-DEVICE RETEST**
- **Phase 3 CHECKPOINT 2**: **BLOCKED**
- **Phase 4**: **BLOCKED**

에이전트는 이번에도 실제 전화를 걸거나, 드라이버를 설치/제거하거나, PCM/Realtime을 시작하거나, CHECKPOINT 2로 진행하지 않았다.

---

## CHECKPOINT 1 — 세 번째 실기기 시도: CoreAudio 라우팅 자체는 PASS, UI 동기화 결함 발견

사용자가 드라이버 재설치 후 재시도한 세 번째 실기기 테스트에서 **CoreAudio route 전환 자체는 성공**했다 — 이전 두 번의 실패 원인이었던 `CanBeDefaultDevice` 문제가 완전히 해결됨을 실기기로 확인.

### 실기기 증거 (세 번째 시도) — CoreAudio 라우팅 기능: PASS

```
Idle → Ringing → Answering → Active → Ending → Idle   (Active 이전 route 변경 없음)

Capture activation: PASS / Inject activation: PASS

Default Output: Smart M80C → Jarvis Call Capture
  targetDeviceID=392 osStatus=0 immediateAfterDeviceID=392 immediateAfterUID=com.jarvis.callbridge.audio.capture

Default Input: Microphone → Jarvis Call Inject
  targetDeviceID=396 osStatus=0 immediateAfterDeviceID=396 immediateAfterUID=com.jarvis.callbridge.audio.inject

route verification pass attempts=1 elapsedMs=231   →   state=routed

(통화 종료, 확정 Idle)
Default Output: Jarvis Call Capture → Smart M80C
Default Input: Jarvis Call Inject → Microphone
restore verification pass attempts=1   →   Inject inactive / Capture inactive / state=idle

Recovery Record: Routed 동안 Present, restore 이후 None
```

이 결과로 두 차례의 route-setter 수정(bounded convergence + `CanBeDefaultDevice` 드라이버 수정)이 실기기에서 최종적으로 검증되었다. **이 동작은 이번 작업에서 전혀 건드리지 않았다.**

### 남은 결함: UI 동기화 (CoreAudio 라우팅 실패 아님)

Routed 상태에서 "Call Audio (Phase 3)" 섹션(Call Audio State/Driver/Recovery Record)은 전부 정확했지만, 상단의 범용 "Audio Route — Input/Output" 표시는 실제 CoreAudio가 이미 Jarvis 디바이스로 전환했음에도 여전히 원래 디바이스(Microphone/Smart M80C)를 보여주고 있었다. System Output은 정확히 그대로였다.

### 근본원인 (코드 조사로 확정)

`AudioRouteReading`/`AudioRouteSnapshot`/`CoreAudioRouteReader`(`Sources/JarvisCallBridge/System/AudioRouteManager.swift`, Phase 0부터 존재)는 상단 UI가 구독하는 **완전히 별개의, Phase 3 CHECKPOINT 1의 `CallAudioRouteControlling`/`CallAudioRouteSnapshot`(`CallAudioSessionController` 내부 전용)과는 전혀 연결되지 않은** read-only 스냅샷이었다. `BridgeViewModel.refreshRouteSnapshot()`은 오직 앱 시작 시점과 Work Mode 토글 시점에만 호출됐고, `CallAudioSessionController`가 실제로 CoreAudio route를 바꿔도 `BridgeViewModel`에게 알릴 방법이 전혀 없었다 — 두 컴포넌트 사이에 알림 메커니즘 자체가 존재하지 않았다(코드 조사로 확정, 추측 아님).

### 수정 — 단일 진실 공급원 유지, 최소 결합

1. `CallAudioSessionController`에 `var onRouteMutated: ((String) -> Void)?` 추가 — SwiftUI/`BridgeViewModel` 타입을 전혀 알지 못하는 순수 클로저. 실제 route를 변경했을 수 있는 5개 트랜잭션 경계 각각의 끝에서 호출: 성공적 takeover(`"takeover"`), 정상 restore(자신의 기존 `reason` 그대로 전달 — `"call-ended"`/`"work-mode-off"`/`"app-quit"`), rollback(`"rollback"`), route ownership loss(`"ownership-loss"`), startup recovery(`"startup-recovery"`, `defer`로 모든 종료 경로 커버).
2. `BridgeViewModel.init()`에서 `callAudioSession.onRouteMutated = { [weak self] reason in self?.refreshRouteSnapshot(reason: reason) }`로 연결 — `refreshRouteSnapshot()`은 항상 `routeReader`(실제 CoreAudio)를 다시 읽을 뿐, `callAudioSession.state`나 하드코딩된 Jarvis 디바이스 이름에서 값을 유추하지 않는다(요청된 "single source of truth" 요구사항 그대로).
3. 새 주기적 폴링 타이머는 추가하지 않았다 — 이미 존재하는 트랜잭션 경계에서만 갱신된다.
4. `refreshRouteSnapshot()`에 `reason: String = "manual"` 파라미터 추가(기본값이 기존 수동 버튼 동작을 그대로 보존), 로그를 `[AUDIO] snapshot refreshed input=... output=... systemOutput=... reason=...`(성공)/`[AUDIO] route snapshot refresh failed reason=...`(실패)로 갱신 — 발신자 정보 없음.
5. refresh 실패(라우트 리더가 nil 반환)는 `callAudioSession`의 성공/실패 판정에 전혀 영향을 주지 않는다 — 완전히 분리된 관심사(§10 요구사항, 테스트로 확인).

`CallAudioRouteControlling`/`JarvisAudioDeviceActivating`는 그대로, driver(`PlugInInterface.c`)도 이번엔 전혀 건드리지 않았다 — `CanBeDefaultDevice`/`CanBeDefaultSystemDevice` 동작 보존.

### Phase 2 / CoreAudio setter / convergence 영향

전부 건드리지 않았다. Phase 2 로직, `SystemCallAudioRouteController`의 property address/scope/element/OSStatus 로직, `waitForRouteConvergence`의 타이밍 로직 — 모두 이전 그대로.

### 테스트

새 파일 `AudioRouteUISynchronizationTests.swift`에 10개 테스트 추가 — 기존 207개 전부 유지, **합계 217개, 217 passed, 0 failed**:

- `testStartupPopulatesRouteDisplayFromActualRouteProvider`
- `testRingingAndAnsweringDoNotChangeRouteDisplay`
- `testSuccessfulTakeoverRefreshesRouteDisplayToActualJarvisRoute` (System Output이 정확히 불변으로 표시되는 것까지 확인)
- `testSuccessfulNormalRestoreRefreshesRouteDisplayToOriginalRoute`
- `testSuccessfulRollbackRefreshesRouteDisplayToActualRestoredRoute`
- `testRouteOwnershipLossRefreshesToUserSelectedRoute` (Jarvis가 기대한 route가 아니라 사용자가 실제로 선택한 route가 표시되는지 확인)
- `testStartupRecoveryTriggersRouteRefresh`
- `testWorkModeOffEmergencyRestoreRefreshesRouteDisplay`
- `testRouteSnapshotRefreshFailureDoesNotFailAnAlreadySuccessfulTakeover` (표시 갱신 실패가 이미 검증된 takeover를 실패로 뒤집지 않음을 확인)
- `testManualRefreshStillWorks` (기존 수동 버튼 경로 그대로 동작)

모두 `CallAudioSessionController`를 스캐너 없이 직접 구동하고(`BridgeViewModelPhase3Tests`와 동일한 패턴), 상단 UI가 구독하는 route provider는 `FakeAudioRouteReader`(이번에 `let` 구조체에서 `var` 프로퍼티를 가진 `class`로 변경 — 테스트 중간에 "실제 route"를 바꿔가며 자동 동기화를 검증하기 위함)로 독립적으로 제어했다 — `CallAudioSessionController` 내부의 `CallAudioRouteControllingSpy`와는 별개의 스파이이므로, 두 컴포넌트가 실제로 완전히 분리되어 있고 값이 그대로 전달되기만 한다는 것을 구조적으로 증명한다.

나머지 요청 항목(§17): Recovery Record 동작 불변·System Output setter 부재·Phase 2 회귀·CoreAudio setter/convergence 불변·PCM/Realtime/recording 부재는 각각 기존 테스트(전부 그대로 유지)로 이미 커버되어 있어 중복 테스트를 추가하지 않았다.

### Build

- `rm -rf .build && swift build --build-tests`: **PASS**, 경고 **0**, 에러 **0**
- `swift test`: **PASS**, **217/217**
- `Scripts/build-app.sh`: **PASS**
- 드라이버는 이번 작업에서 전혀 변경하지 않았으므로 `build-driver.sh`/재설치를 실행하지 않았다(§19 지시대로)
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

### 최종 CHECKPOINT 1 재검증 절차 (§21과 동일)

**Manual final retest: REQUIRED.** 드라이버 코드를 건드리지 않았으므로 재설치는 불필요하다. Work Mode ON / Auto Answer OFF로 실제 통화 1건 재시도하며 이번엔 Active/Routed 상태에서 상단 "Audio Route — Input/Output"이 각각 Jarvis Call Inject/Jarvis Call Capture로 즉시 갱신되는지, System Output은 원본 그대로인지, 통화 종료 후 원본 Input/Output으로 다시 갱신되는지 확인한다. 세부 단계는 기존 "Manual CHECKPOINT 1 Real-Device Validation" 섹션과 동일.

### 현재 게이트 상태

- **Phase 3 CHECKPOINT 1**: **FUNCTIONAL ROUTING PASS** — **FINAL PASS는 사용자의 최종 UI 동기화 실기기 확인 대기 중**
- **Phase 3 CHECKPOINT 2**: **BLOCKED**
- **Phase 4**: **BLOCKED**

에이전트는 이번에도 실제 전화를 걸거나, 드라이버를 재설치하거나, PCM/Realtime/recording을 구현하거나, CHECKPOINT 2로 진행하지 않았다.

---

## Phase 3 CHECKPOINT 1 — 최종 판정: FINAL PASS

사용자가 UI 동기화 수정 이후 최종 실기기 재검증을 완료했다. 전체 라이프사이클과 route/PCM 무관 UI 동기화까지 전부 실기기로 확인되었다:

```
Idle → Ringing → Answering → Active → Ending → Idle   (Active 이전 route 변경 없음)
Capture/Inject activation: PASS
Default Output: Smart M80C → Jarvis Call Capture   (osStatus=0)
Default Input:  Microphone → Jarvis Call Inject    (osStatus=0)
route verification pass attempts=1 elapsedMs=11    →   state=routed
UI: Audio Route — Input=Jarvis Call Inject, Output=Jarvis Call Capture, System Output=Mac Studio 스피커 (원본 그대로)
Recovery Record: Routed 동안 Present

(통화 종료)
Default Output/Input 원본으로 복원, restore verification pass
Inject/Capture inactive, Recovery Record=None
최종 UI: 원본 Input/Output/System Output 전부 정확히 표시
```

**Phase 3 CHECKPOINT 1 = FINAL PASS.** CoreAudio route takeover/restore, `CanBeDefaultDevice` 드라이버 수정, bounded convergence, recovery record 정리, UI route 동기화 — 전부 실기기에서 검증 완료. 이 체크포인트는 다시 열지 않는다(CHECKPOINT 2에서 실제 회귀가 발견되지 않는 한).

---

## CHECKPOINT 2 — CoreAudio Direct I/O + Deterministic RX/TX PCM Validation (구현)

### 목적

CHECKPOINT 1은 "macOS route를 안전하게 획득/복원할 수 있다"를 증명했다. CHECKPOINT 2는 그 route 위에서 **실제 PCM이 흐른다**는 것을 증명한다 — RX(발신자→Capture→Bridge)와 TX(Bridge→Inject→발신자) 양방향. Realtime/STT/TTS/녹음/R2 업로드 등은 명시적으로 범위 밖(Phase 4/7)이다.

### 아키텍처

- **`CallAudioPCMControlling`** (프로토콜, `System/CallAudioPCMControlling.swift`) — Bridge 자신의 CoreAudio Direct I/O만 담당. `CallAudioSessionController`(route ownership/recovery/restore)와 명확히 분리 — SwiftUI 타입을 전혀 모르는 순수 프로토콜.
- **`SystemCallAudioPCMController`**(`System/SystemCallAudioPCMController.swift`) — 실제 구현. `AudioDeviceCreateIOProcIDWithBlock`/`AudioDeviceStart`/`AudioDeviceStop`/`AudioDeviceDestroyIOProcID` 사용(`JarvisAudioDriverTool.DeviceIOSession`이 이미 검증한 것과 동일한 저수준 HAL Direct I/O API) — ScreenCaptureKit/AVAudioEngine/Aggregate Device 전혀 사용 안 함.
- **조정(coordination)**: `CallAudioSessionController`가 `pcmController: CallAudioPCMControlling`을 주입받아 §21/§22 순서를 코드로 명시적으로 강제한다(§7/§23의 "protocol-injected PCM controller coordinated by CallAudioSessionController" 패턴) — SwiftUI 타이밍이나 임의 sleep에 의존하지 않는다.

### Native PCM Format (§6/§11)

드라이버의 실제 ASBD를 매 PCM 시작 시점마다 조회해 검증(가정하지 않음) — `AudioDriver/Plugin/PlugInInterface.c`의 `FillStreamFormat`과 일치:

```
sampleRate: 48000 Hz
sample type: Float32 (kAudioFormatFlagIsFloat)
channels: 2 (stereo)
interleaving: interleaved (kAudioFormatFlagIsNonInterleaved 없음)
bytesPerFrame: 8 (Float32 × 2채널)
```

실제 조회한 포맷이 이 계약과 다르면 **즉시 실패**하며 리샘플링을 시도하지 않는다(`CallAudioPCMFormat.expected`와의 `Equatable` 비교).

### RX 경로 (§12/§13)

`Jarvis Call Capture`의 INPUT 스트림에서 읽는다(driver loopback을 통해 Phone.app이 실제로 재생한 PCM). Capture 자신의 OUTPUT 쪽은 매 콜백마다 명시적으로 silence로 채운다(우리가 채울 것이 없으므로 stale 메모리를 남기지 않기 위함). 진단 전용, 절대 의미론적이지 않음: RX Frames/Callbacks/RMS(dBFS)/Peak(dBFS)/Activity(단순 threshold, VAD 아님) — 가장 최근 콜백의 버퍼로부터 계산(긴 롤링 윈도우 아님, 단순하고 결정적).

### TX 경로 (§14/§15/§28)

`Jarvis Call Inject`의 OUTPUT 스트림에 쓴다(driver loopback을 통해 Phone.app이 이걸 마이크 입력으로 읽음). 큐에 든 톤이 없으면 **명시적 디지털 무음**을 쓴다(이전 콜백의 stale 메모리를 절대 재생하지 않음 — 매번 남은 프레임을 0으로 채우는 테스트로 확인).

**결정적 진단 톤**(§15): 1000 Hz, 1.0초(48000프레임 @ 48kHz), 스테레오 양 채널 동일 신호, 진폭 0.1(≈ -20 dBFS, 요청된 -18~-24 dBFS 범위 내), 위상은 항상 0에서 시작하고 콜백 경계를 넘어 연속(위상 불연속 없음).

**절대 자동재생 안 함**(§16/§17): "Send 1 kHz Test Tone" 버튼은 `Call Audio State == Routed && PCM State == Running`일 때만 활성화되며, 누르면 이미 실행 중인 TX 경로에 톤을 큐에 넣을 뿐 — route/디바이스 활성화/PCM 시작을 절대 건드리지 않는다. 재요청 정책(§48): **이미 재생 중/큐에 있으면 거부**(가장 단순하고 결정적인 정책으로 채택, 문서화됨) — 재생 중간에 주파수가 튀는 일이 없다.

### 시작/종료 순서 (§21/§22) — `CallAudioSessionController`에서 강제

```
route verification PASS → state=routed → onRouteMutated("takeover") → pcmController.start("takeover")
```
PCM 시작 실패 시(§25): 부분 시작분만 되돌리고(`start()` 내부에서 이미 all-or-nothing), `rollback(..., stage: "pcm-start", ...)`을 재사용해 route를 emergency-restore하고 디바이스를 비활성화하고 recovery record를 지우고 해당 세션을 재시도 대상에서 제외한다.

```
(confirmed Idle / Work Mode OFF / app quit / ownership loss)
pcmController.stop(reason:) 완료를 await   →   그 다음에만 route setter/디바이스 비활성화 호출
```
`restore()`/`rollback()`/ownership-loss 분기 전부 각자의 맨 처음(어떤 route/디바이스 mutation보다도 먼저)에서 `await pcmController.stop(reason:)`을 호출 — rollback은 PCM이 실제로 시작한 적 없는 경로(대부분의 실패 단계)에서도 무조건 호출하지만 idempotent라 안전하다.

### 실시간 안전성 (§18/§50) — 코드 구조로 보장되는 것 vs 테스트로 증명되는 것

**코드 구조로 보장**(정직하게, 유닛테스트가 실제 하드 리얼타임을 증명할 수는 없음을 명시): 콜백 본체(`silence`/`consumeRX`/`produceTX`)는 파일 I/O·네트워크 I/O·SwiftUI 호출·콜백당 로거 호출·할당 없음 — 순수 수학(sqrt/log10/sin)과 `NSLock` 보호 하의 짧은 임계구역뿐(`JarvisAudioDriverTool.DeviceIOSession`이 이미 캡처 버퍼에 쓰던 것과 동일한, 기존에 이 코드베이스에서 받아들여진 패턴). `PCMRuntimeBox`는 `@unchecked Sendable`로 이 락 보호를 명시적으로 문서화. 콜백들은 `@MainActor` 클래스의 `nonisolated static func`로 선언되어 있다 — 이는 이번 구현 중 발견해 즉시 고친 실제 정확성 문제였다(아래 "발견 및 수정" 참고).

**버퍼링**(§19/§20): TX 톤 생성은 별도 프로듀서 스레드/링버퍼 없이 콜백 안에서 직접 샘플을 계산하므로, 이 체크포인트 범위에서는 진짜 "TX underrun"(외부 프로듀서가 데이터를 제때 채우지 못하는 상황)이 구조적으로 발생할 수 없다 — `txUnderrunCount` 필드는 존재하지만(향후 Phase 4에서 실제 스트리밍 프로듀서가 생기면 의미를 가짐) 손상된 `AudioBufferList`(널 데이터 등) 같은 방어적 케이스에서만 증가한다. RX "overflow/drop" 카운터는 추가하지 않았다 — 콜백이 락 보호 하에 무조건적으로 즉시 기록하므로 드롭될 큐 자체가 존재하지 않는다(§20의 "Phase 4 버퍼링을 과설계하지 말 것" 지시에 따름).

### 발견 및 수정 (구현 중)

1. **크래시 위험이 아닌 정확성 버그**: `SystemCallAudioPCMController`가 `@MainActor` 클래스이므로 그 정적 메서드(`silence`/`consumeRX`/`produceTX`/`dBFS`)가 기본적으로 MainActor-isolated로 추론되었다 — 이 메서드들은 실제로는 **실시간 오디오 스레드**에서 호출되어야 하는데, Swift가 이 격리 위반을 컴파일 타임에 즉시 잡아내지 못하고(콜백 클로저 타입이 `@Sendable`로 명시되지 않아 검사가 느슨했음) 테스트 코드를 작성하는 과정에서 발견했다. **수정**: 이 4개 메서드를 `nonisolated static func`로 명시 — 이들은 MainActor 상태를 전혀 건드리지 않고(`PCMRuntimeBox` 하나만, 이미 `@unchecked Sendable`) 실시간 스레드에서 호출되는 것이 올바른 설계이므로, 이는 억지 우회가 아니라 정확한 수정이다.
2. `PCMRuntimeBox`를 파일 내부(`private`)에서 모듈 내부(`internal`)로, 그리고 위 4개 메서드도 동일하게 접근 수준을 낮춰 순수 계산 로직을 실제 CoreAudio 없이 합성 `AudioBufferList`로 직접 단위 테스트할 수 있게 했다(§40).
3. 기존 스파이 유틸리티(`CallAudioTestFixtures.makeSpies()`)가 4-튜플로 확장되면서(§40 대응 `CallAudioPCMControllingSpy` 추가) 이를 사용하는 **기존 3개 테스트 파일의 모든 `CallAudioSessionController(...)` 생성 호출부에 `pcmController: spies.pcm`을 추가**해야 했다 — 그렇지 않으면 `CallAudioSessionController`의 새 `pcmController` 파라미터가 기본값(실제 `SystemCallAudioPCMController`)으로 떨어져 **자동화 테스트가 실제 Jarvis Capture/Inject 디바이스에 진짜 CoreAudio Direct I/O를 열 뻔했다** — 새 테스트를 작성하기 전에 먼저 잡아서 고쳤다.

### UI (§29/§30/§31)

"Call PCM (Phase 3 CHECKPOINT 2)" 섹션 추가: PCM I/O State/Format/RX Frames/RX Callbacks/RX RMS·Peak/RX Activity/TX Frames/TX Callbacks/TX Underruns/Test Tone 상태, "Send 1 kHz Test Tone" 버튼(Routed+Running일 때만 활성화). `SystemCallAudioPCMController`는 콜백에서 직접 `@Published`를 갱신하지 않는다 — 락 보호된 `PCMRuntimeBox`에 실시간 스레드가 쓰고, PCM이 `.running`일 때만 살아있는 5Hz(`0.2초`) 타이머가 스냅샷을 읽어 게시한다(§30) — Idle/ARMED 동안은 이 타이머 자체가 존재하지 않는다. 매 호출마다 새 세션을 시작하므로 이전 통화의 메트릭이 새 통화로 새어들지 않는다(§31 — `start()`가 항상 먼저 `runtimeBox.reset()`을 호출).

### 구조적 로깅

`[CALL-PCM]` 접두사로 요청된 라이프사이클 전부 구현: prepare/capture device resolved/inject device resolved/capture format/inject format/capture io created/capture started/inject io created/inject started/state=running/test-tone queued·started·completed/stop started reason=.../inject stopped/capture stopped/io disposed/state=idle. 콜백당 로그는 전혀 없다. 발신자 이름/전화번호/트랜스크립트는 어디에도 없다.

### 드라이버

**이번 체크포인트에서 드라이버 소스는 전혀 수정하지 않았다** — `Jarvis Call Capture`/`Jarvis Call Inject`의 기존 Direct I/O 계약(48kHz/Float32/stereo/interleaved, `AudioDeviceCreateIOProcIDWithBlock`으로 정상 동작)을 그대로 사용했다. **DRIVER REINSTALL NOT REQUIRED.**

### 테스트

새 테스트 36개 추가(순수 계산 20개 + 조정/라이프사이클 16개), 기존 217개 전부 유지 — **합계 253개, 253 passed, 0 failed**:

- **`SystemCallAudioPCMControllerComputationTests.swift`**(20개) — 실제 CoreAudio 없이 합성 `AudioBufferList`로 직접 검증: dBFS 변환(풀스케일=0dBFS, 무음=floor, 알려진 진폭), silence()가 모든 바이트를 0으로, consumeRX가 무음/풀스케일 신호에 대해 올바른 RMS·Peak·Activity를 계산, 프레임/콜백 카운트 누적, `reset()`이 전부 초기화, produceTX가 톤 없을 때 정확히 전무음 출력(stale 메모리 덮어씀 확인), 큐에 든 톤이 정확한 주파수·진폭의 결정적 사인파를 생성(부동소수 오차 허용), 콜백 경계를 넘어 위상이 연속(불연속 없음), 톤이 버퍼 중간에 소진되면 나머지가 정확히 무음, `queueTone`이 정확히 요청된 프레임 수(1초=48000)를 설정, 손상된 버퍼가 크래시 대신 underrun으로 기록, 기대 포맷 상수가 Phase 1 계약과 정확히 일치 + 잘못된 sample rate/channel/type/interleaving이 전부 `!=`.
- **`CallAudioPCMCoordinationTests.swift`**(16개) — §42 items 1-7(Idle/Ringing/Answering은 PCM 시작 안 함, 검증 실패 시 PCM 시작 안 함, 성공적 Routed 전환은 정확히 1번만 PCM 시작, 반복 tick은 중복 시작 안 함, restore 이후 새 통화는 새 PCM 세션), §43(PCM 시작이 route setter 둘 다보다 나중), §44(PCM 정지가 route 복원/디바이스 비활성화보다 먼저 — order log의 정확한 인덱스로 검증), §45(Work Mode OFF/app quit/ownership loss 전부 PCM을 먼저 정지 후 복원), §25(PCM 시작 실패 시 route rollback + 세션 재시도 제외), §52(recovery record 동작이 PCM과 무관하게 그대로).
- 새로 추가한 `CallAudioOperationOrderLog`(route/activator/pcm 스파이가 공유하는 단일 순서 로그)가 §43/§44의 "상대적 순서" 요구사항을 실제로 검증 가능하게 만든다 — 단순히 "호출됐다/안 됐다"가 아니라 "이게 저것보다 먼저 호출됐다"를 인덱스로 증명.
- §46(포맷 검증), §47(RX), §48(TX 톤), §49(TX 무음/underrun), §50(리얼타임 안전성)은 위 계산 테스트 20개가 커버. §51(부분 실패 unwind)은 `SystemCallAudioPCMController.start()`의 all-or-nothing 로직으로 구조적으로 보장되며(Inject 실패 시 이미 시작한 Capture를 되돌리는 코드가 존재), 실제 CoreAudio 실패를 모의(mock)하려면 real device access가 필요해 유닛테스트로는 이 구조 자체(코드 인스펙션)로 확인 — 정직하게 그렇게 기록한다.

### Build

- `rm -rf .build && swift build --build-tests`: **PASS**, 경고 **0**, 에러 **0**
- `swift test`: **PASS**, **253/253**
- `Scripts/build-app.sh`: **PASS**
- 드라이버 소스 미변경 → `build-driver.sh`/재설치 실행 안 함(§54 지시대로)
- `git status --porcelain admin/ api/ web/`: 빈 결과 확인

### Headless / No-Call 안전성 확인 (§55, 필수)

`Jarvis Call Bridge.app`을 빌드된 번들 그대로 3초간 실제로 실행(에이전트가 직접 실행 — 통화 없이 headless 확인 목적, 실제 전화는 걸지 않음)한 뒤 `JarvisAudioDriverTool status`(read-only)로 확인, 정상 종료(AppleScript `quit`, 새 `applicationShouldTerminate`+`.terminateLater` 경로로 크래시/행 없이 종료):

```
실행 전:  Capture/Inject hidden=true active=false alive=true running=false canBeDefaultDevice=false/false
          Route: Input=Microphone Output=Smart M80C SystemOutput=Mac Studio 스피커
앱 3초간 실행 중 (Work Mode 자동 ON, 통화 없음):
실행 중:  Capture/Inject hidden=true active=false alive=true running=false canBeDefaultDevice=false/false  (완전히 동일)
          Route: 완전히 동일
```

Work Mode ON 상태에서도 통화가 없으면 Capture/Inject `running=false`(IOProc 시작 안 됨), route 완전 불변 — PCM은 Idle 상태를 유지했다.

### 현재 게이트 상태

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **IMPLEMENTATION COMPLETE — REQUIRES MANUAL REAL-DEVICE VALIDATION**
- **Phase 4**: **BLOCKED**

에이전트는 실제 전화를 걸지 않았고, Realtime/STT/TTS/녹음을 구현하지 않았고, CHECKPOINT 2를 넘어서지 않았다.

---

## CHECKPOINT 2 — Real-Time Callback Lock-Free Hardening

### 리뷰에서 발견된 문제

이전 구현의 문서는 `PCMRuntimeBox`가 `NSLock`으로 보호된다고 기록했다. **정정**: 그 서술은 잘못되었다 — 기능적으로는 정확했고(모든 테스트 통과) 실기기 검증도 막지 않았지만, **실제 CoreAudio 실시간 콜백의 최종 설계로는 받아들일 수 없다.** `NSLock`은 블로킹 뮤텍스이며, 오디오 콜백이 메인 스레드·5Hz UI 메트릭 타이머·그 밖의 어떤 비실시간 소비자 뒤에서 우선순위 역전(priority inversion)이나 락 소유 스레드의 스케줄러 선점으로 인해 멈춰버릴 수 있다. `@unchecked Sendable`은 실시간 동기화 보장이 아니다 — 단지 "이 타입이 스레드-안전함을 수동으로 검증했다"는 컴파일러에 대한 약속일 뿐이며, 그 수동 검증 자체(락)가 실시간에 부적합했다.

**락을 획득하던 콜백 도달 가능 함수들**(수정 전): `PCMRuntimeBox.recordRX` / `.recordTX` / `.queueTone` / `.consumeToneFrames` / `.toneRemainingFrames` / `.snapshot` / `.reset` — 전부 동일한 단일 `NSLock`을 공유했다. `SystemCallAudioPCMController.consumeRX`/`produceTX`가 이 메서드들을 콜백 안에서 직접 호출했다.

### 선택한 설계: C11 `stdatomic.h` (새 작은 C 타겟)

**결정 순서**: (A) 이미 사용 가능한 원자적 프리미티브 — Swift `Synchronization.Atomic`은 배포 최소 버전을 올려야 할 가능성이 있어(현재 `platforms: [.macOS(.v14)]`) "이미 사용 가능"으로 보기 어려움. (B) 작은 C11 원자 헬퍼 — **채택**. 이 코드베이스의 드라이버(`AudioDriver/Plugin/PlugInTypes.h`)가 이미 `_Atomic bool isHidden`/`isActive`로 정확히 같은 클래스의 문제(실시간 HAL 콜백에서 안전하게 읽어야 하는 상태)를 C11 atomics로 풀고 있어 — 이 프로젝트 안에서 이미 검증된, 일관된 패턴. (C) 새 의존성 추가는 불필요 — 기각.

새 타겟 `Sources/JarvisPCMAtomics/`(헤더의 `static inline` 함수만으로 구성 — Swift는 `_Atomic` 필드에 C 매크로를 직접 호출할 수 없으므로, 매 연산을 평범한 C 함수로 감쌌다) + Package.swift에 `JarvisCallBridge`의 새 의존성으로 연결. 드라이버의 기존 `JarvisLoopbackBuffer` C 타겟과 완전히 동일한 `.c` + `include/*.h` 레이아웃.

```c
typedef struct {
    _Atomic int64_t rxFrames, rxCallbacks;
    _Atomic uint32_t rxRMSBits, rxPeakBits;   // Float.bitPattern
    _Atomic int64_t txFrames, txCallbacks, txUnderrunCount;
    _Atomic int32_t toneState;          // 0=idle 1=queued 2=playing
    _Atomic int32_t toneRequestFrames;
} JarvisPCMAtomicState;
```

### 실시간 상태 소유권 모델 (§5)

- **RX 필드**(rxFrames/rxCallbacks/rxRMS/rxPeak): **단일 작성자** — Capture 콜백만 씀. 5Hz UI 타이머만 읽음. 매 샘플마다 원자 연산 없음 — 콜백은 로컬(스택) 변수로 frameCount/peak/sumSquares/RMS를 계산한 뒤, 콜백 끝에서 **딱 한 번**만 집계값을 원자적으로 기록한다.
- **TX 카운터**(frames/callbacks/underrun): 동일 패턴, Inject 콜백만 씀.
- **톤 재생 진행 상태**(frame index/phase): 이번에 새로 도입한 `PCMTXToneProgress`가 소유 — Inject 콜백 클로저 단 하나에만 캡처되는 평범한(원자적이지 않은) Swift 프로퍼티. CoreAudio가 한 디바이스의 IOProc을 절대 동시에 호출하지 않으므로(항상 순차 호출) 이 값은 애초에 경쟁할 대상이 없다 — 원자성 자체가 불필요. `start()`마다 새 인스턴스를 생성하므로 이전 통화의 진행 상태가 새 통화로 새는 일도 구조적으로 불가능(§19).
- **톤 요청 핸드오프**(toneState/toneRequestFrames): 유일하게 "진짜" 크로스스레드 지점 — 비실시간 "Send Test Tone" 액션이 `idle(0) -> queued(1)` 단일 compare-exchange로 요청을 발행(두 번째 동시 요청은 반드시 짐, 정확히 하나만 승리), Inject 실시간 콜백이 유일한 소비자. release/acquire 순서로 `toneState==1`을 관측한 콜백은 반드시 그 직전에 저장된 `toneRequestFrames`도 함께 관측한다.

### RX/TX 콜백 (§6/§8) — 변경된 부분

`consumeRX`는 그대로(이미 로컬 변수로 집계 후 한 번만 기록하는 구조였음 — 내부 저장 메커니즘만 락→원자적으로 교체). `produceTX`는 시그니처에 `progress: PCMTXToneProgress` 파라미터가 추가됐고, 톤 재생 수학(사인파 생성/위상 진행/프레임 차감)이 `PCMRuntimeBox.consumeToneFrames`(락 보유)에서 `produceTX` 함수 자체로 이동해 `progress`의 평범한 프로퍼티를 직접 갱신한다 — 이제 톤 한 프레임을 쓸 때마다 원자 연산이 전혀 없다. `box`는 딱 두 곳에서만 호출: 큐에 새 요청이 있는지 폴링(`pollQueuedToneRequest`, queued→playing 전환도 여기서), 그리고 톤이 끝났을 때 완료 신호(`markToneComplete`).

### 톤 요청 핸드오프 정책 (§9/§48) — 변경 없음, 구현만 락-프리로

정책 자체(이미 재생 중/큐에 있으면 거부)는 그대로 유지 — 다만 이제 **판정 자체가 원자적 compare-exchange 결과**다. 이전 구현은 `@Published testToneState`(MainActor 미러)로 먼저 판정했는데, 이는 5Hz 타이머가 아직 따라잡지 못한 좁은 시간창에서 이론적으로 오판할 수 있었다 — `sendTestTone()`은 이제 `runtimeBox.requestTone(frameCount:)`의 반환값을 유일한 판정 근거로 쓴다.

### 메트릭 스냅샷 일관성 (§7) — 의도적으로 최종 일관(eventual)

5Hz UI 타이머가 콜백 N의 RX frame count와 콜백 N-1의 RX peak를 동시에 관측해도 무방하다 — 진단 전용 값이고 어떤 제어 흐름에도 쓰이지 않는다. 이걸 완벽하게 일치시키려고 락을 다시 넣는 일은 절대 하지 않았다(§7 명시적 지시).

### 로깅

콜백 안에서는 여전히 로거를 전혀 호출하지 않는다. "test-tone started"/"completed" 로그는 5Hz 타이머(`publishMetrics`)가 `box.toneStateSnapshot()`을 읽고 이전 값과 달라졌을 때만 발행 — 콜백이 직접 로깅하지 않고도 라이프사이클 로그가 정확히 유지된다. `[CALL-PCM] runtime synchronization=lock-free`를 컨트롤러 생성 시 한 번 기록.

### 콜백 안전성 감사 (§31, 필수)

`SystemCallAudioPCMController.swift` 전체에서 `NSLock`/`.lock(`/`pthread_mutex`/`os_unfair_lock`/`DispatchQueue`/`.sync(`/`semaphore`/`wait(`/`await` 검색 결과 — 실제 코드에서 매칭 **0건**(유일한 매치는 "이전 설계는 NSLock을 썼다"를 설명하는 주석 문자열). 콜백 도달 가능 함수 전체(`silence`/`consumeRX`/`produceTX`/`dBFS`, `PCMRuntimeBox.recordRX`/`.recordTX`/`.pollQueuedToneRequest`/`.markToneComplete`, `PCMTXToneProgress` 필드 접근) 직접 추적 확인:

```
callback reachable blocking primitives = NONE
```

파일 I/O 없음, 네트워크 I/O 없음, SwiftUI/@Published 게시 없음, MainActor hop 없음, 콜백당 로거 호출 없음, 무제한 버퍼 없음(§17 지시대로 새 링버퍼도 추가하지 않음 — 톤은 콜백 안에서 직접 생성되므로 프로듀서/컨슈머 큐 자체가 필요 없다). `NSLock` 하나는 여전히 파일에 존재하지만 **테스트 전용**(`ManagedCounter`, concurrency stress 테스트 자신의 카운터 집계용) — 콜백 경로와 무관함을 명시적으로 구분해 기록한다.

### 드라이버 / Phase 2 / CHECKPOINT 1

전혀 건드리지 않았다. **DRIVER REINSTALL NOT REQUIRED.**

### 테스트

`SystemCallAudioPCMControllerComputationTests.swift`에 신규/재작성 테스트 추가 — 기존 253개 전부 유지, **합계 263개, 263 passed, 0 failed**:

- 기존 톤 테스트 7개를 새 API(`produceTX(..., progress:)`, `box.requestTone`/`toneStateSnapshot`)로 재작성 — 정확한 결정적 사인파, 콜백 경계 간 위상 연속성, 버퍼 중간 소진 후 무음 등 기존에 검증하던 동작은 전부 그대로 재확인됨.
- **§27 락-프리 핸드오프**(7개): idle→queued 성공, Queued 중 재요청 거부, Playing 중 재요청 거부, 콜백이 큐 요청을 정확히 한 번만 소비, Queued→Playing 전환, Playing→Idle 전환(완료), 완료 후 나중 콜백에서 stale 재생 안 됨.
- **§30 reset/stop 안전성**(2개): reset이 대기 중인 요청도 Idle로 되돌림, reset 이후 이전 요청을 폴링할 수 없음.
- **§32 선택적 동시성 스트레스 테스트**(1개, `DispatchQueue.concurrentPerform`로 200개 동시 요청 경쟁, wall-clock sleep 없이 완전히 결정적): compare-exchange가 실제 동시 경합 하에서도 정확히 승자 1명만 보장함을 증명.
- RX 관련 기존 테스트(무음/풀스케일/누적 카운트/reset)는 공개 API가 그대로라 전부 무수정으로 통과 — 내부가 락→원자적으로 바뀐 것이 투명했음을 그 자체로 증명한다.

### Build

- `rm -rf .build && swift build --build-tests`: **PASS**, 경고 **0**(ClangImporter의 "built-in type 'Atomic' not supported" 노트는 에러/경고가 아닌 정보성 note이며, `_Atomic` 필드를 Swift가 원자 타입으로 직접 매핑하지 않는다는 의도된 사실을 보고할 뿐 — 이 필드들에 절대 Swift에서 직접 접근하지 않고 오직 C 함수 호출로만 다루므로 무해함), 에러 **0**
- `swift test`: **PASS**, **263/263**
- `Scripts/build-app.sh`: **PASS**
- 드라이버 소스 미변경 → 재설치 없음

### Headless / No-Call 안전성 재확인 (§38)

앱을 3초간 실행(통화 없음, Work Mode 자동 ON)한 뒤 `JarvisAudioDriverTool status`로 실행 전/중 비교 — 완전히 동일: Capture/Inject `hidden=true active=false running=false canBeDefaultDevice=false/false`, route 완전 불변. 정상 종료(AppleScript quit, 크래시/행 없음).

### 현재 게이트 상태

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **IMPLEMENTATION COMPLETE — REAL-TIME CALLBACK HARDENING COMPLETE — FINAL PASS PENDING MANUAL REAL-DEVICE RX/TX VALIDATION**
- **Phase 4**: **BLOCKED**

에이전트는 실제 전화를 걸지 않았고, 드라이버를 수정/재설치하지 않았고, Realtime/STT/TTS/녹음을 구현하지 않았고, CHECKPOINT 2를 넘어서지 않았다.

---

## CHECKPOINT 2 — C Native IOProc Real-Time Hardening

### 왜 다시 리뷰했나 — 이전 "최종" 표현의 정정

바로 앞 섹션은 락-프리 원자적 하드닝을 두고 "실시간 콜백 경로에 블로킹 동기화가 전혀 없다"를 최종 상태로 기록했다. **그 서술 자체는 사실이었지만 충분하지 않았다**: `AudioDeviceCreateIOProcIDWithBlock`으로 등록한 콜백은 여전히 **Swift 클로저**였다 — 락이 없더라도, CoreAudio의 실시간 오디오 스레드가 매 IO 사이클마다 Swift 런타임(ARC, 클로저 캡처, Swift 호출 규약)을 거쳐야 한다는 사실 자체가 하드 리얼타임 관점에서 이상적이지 않다. **상위 문서의 "Swift AudioDeviceIOBlock + C 원자적 연산 = 최종 RT-safe 설계"라는 표현은 이번 작업으로 대체(superseded)된다** — 지우지 않고 그대로 보존하되, 이 섹션이 최종 하드닝임을 명시한다: 실제 프로덕션 IOProc 콜백 자체를 네이티브 C로 옮겨, 오디오 콜백 실행 경로에 Swift가 전혀 없도록 만들었다.

### 이전 콜백 경로 (대체됨)

```
CoreAudio → AudioDeviceCreateIOProcIDWithBlock 등록 → Swift 클로저
  → SystemCallAudioPCMController.{silence,consumeRX,produceTX} (Swift, nonisolated static)
  → PCMRuntimeBox (Swift 클래스, C11 원자 연산 호출)
```

### 새 콜백 경로 (현재, 프로덕션)

```
CoreAudio → AudioDeviceCreateIOProcID 등록 → C 함수 포인터
  Capture: JarvisPCMCaptureIOProc (순수 C)
  Inject:  JarvisPCMInjectIOProc  (순수 C)
    → JarvisPCMRuntimeContext (C 구조체, C11 원자 필드)
```

**Swift는 콜백 실행 경로에서 완전히 사라졌다** — `AudioDeviceCreateIOProcID(deviceID, JarvisPCMCaptureIOProc, clientData, &procID)`처럼 C 함수를 함수 포인터 값으로 직접 등록하며, 그 C 함수는 Swift로 다시 호출하지 않는다(구조적으로 감사 완료, 아래 참고).

### C 런타임 (`Sources/JarvisPCMRealtime/`) — 기존 `JarvisPCMAtomics` 타겟을 확장(옵션 A)

타겟 이름을 `JarvisPCMAtomics` → `JarvisPCMRealtime`으로 변경(단순 원자 프리미티브 그 이상 — 실제 IOProc 구현 자체를 담게 되어 이름이 더 정확해짐). 새 서드파티 의존성 없음. `Package.swift`에 `linkerSettings: [.linkedFramework("CoreAudio")]` 추가(C 타겟이 `AudioBufferList`/`AudioTimeStamp`/`OSStatus` 등 CoreAudio 타입을 직접 사용하므로).

**공개 C API** (`JarvisPCMRealtime.h`) — 원자 필드 자체는 Swift에 전혀 노출하지 않는다(§10):

```c
typedef struct JarvisPCMRuntimeContext JarvisPCMRuntimeContext; // Swift에는 완전히 불투명(opaque)

// 제어 평면 (non-RT)
JarvisPCMRuntimeContext *_Nullable JarvisPCMRuntimeCreate(void);
void JarvisPCMRuntimeReset(JarvisPCMRuntimeContext *context);
void JarvisPCMRuntimeDestroy(JarvisPCMRuntimeContext *_Nullable context);
bool JarvisPCMRuntimeRequestTone(JarvisPCMRuntimeContext *context, int32_t frameCount);
void JarvisPCMRuntimeReadMetrics(const JarvisPCMRuntimeContext *context, JarvisPCMMetricsSnapshot *outSnapshot);
bool JarvisPCMRuntimeAtomicsAreLockFree(void);

// 실시간 (CoreAudio가 직접 호출; Swift는 절대 호출하지 않음)
OSStatus JarvisPCMCaptureIOProc(...);
OSStatus JarvisPCMInjectIOProc(...);
```

Swift 쪽에서 `JarvisPCMRuntimeContext*`는 **불완전(opaque) 타입**이라 `OpaquePointer`로 임포트된다(`UnsafeMutablePointer<T>`가 아님 — Swift가 내부 레이아웃을 전혀 모름, sqlite3 핸들과 동일한 패턴).

### 컨텍스트 생명주기 (§11)

```
제어 평면: JarvisPCMRuntimeCreate()
             ↓
           AudioDeviceCreateIOProcID (Capture) → AudioDeviceStart (Capture)
             ↓
           AudioDeviceCreateIOProcID (Inject)  → AudioDeviceStart (Inject)
             ↓
콜백 구간: 컨텍스트는 안정적으로 유효 — 콜백만 접근

제어 평면: AudioDeviceStop (Inject) → AudioDeviceDestroyIOProcID (Inject)
             ↓
           AudioDeviceStop (Capture) → AudioDeviceDestroyIOProcID (Capture)
             ↓
           오직 이 시점에만: JarvisPCMRuntimeDestroy()
```

`AudioDeviceStop`이 반환하면 CoreAudio 자체 계약상 해당 IOProc이 다시 호출되지 않는다는 것이 보장된다 — 이것이 바로 그 이후에 컨텍스트를 free해도 안전한 근거다. `SystemCallAudioPCMController.stop(reason:)`이 정확히 이 순서(Inject 먼저 stop/destroy → Capture stop/destroy → 오직 그 다음에만 `JarvisPCMRuntimeDestroy`)를 구현한다.

### 원자적 lock-free 보장 (§14)

컴파일 타임: `_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 || ATOMIC_LLONG_LOCK_FREE == 2, ...)`(64비트 필드), `_Static_assert(ATOMIC_INT_LOCK_FREE == 2, ...)`(32비트 필드). 런타임 폴백: `JarvisPCMRuntimeAtomicsAreLockFree()`가 `atomic_is_lock_free()`로 모든 원자 필드를 실제로 확인 — `SystemCallAudioPCMController.start()`가 **어떤 IOProc도 등록하기 전에** 이걸 호출하고, false면 즉시 안전하게 시작을 실패시킨다(콜백 내부에서 발견하는 일은 구조적으로 불가능).

### RX 콜백 설계 (§15/§16/§17)

`JarvisPCMCaptureIOProc`(순수 C): Capture의 INPUT 버퍼(드라이버 loopback을 통한 실제 발신자/Phone.app 오디오)를 읽어 콜백 로컬(스택) 변수로 frameCount/sumSquares/peak를 계산한 뒤, 콜백 끝에서 **딱 한 번** 집계값을 원자적으로 기록 — 샘플당 원자 연산 없음. **dB 변환은 콜백에서 완전히 제거**했다(§16) — 원자 상태에는 이제 `rxMeanSquareLinear`/`rxPeakLinear`(선형값)만 저장되고, `sqrt`/`log10` 기반의 dBFS 변환은 5Hz Swift UI 리더(`SystemCallAudioPCMController.publishMetrics()`, 논-RT)에서만 수행된다. Capture 자신의 OUTPUT 버퍼는 매 콜백마다 전체를 memset으로 0 채움(Jarvis가 채울 것이 없으므로, stale 메모리 방지).

### TX 콜백 설계 (§18/§19/§20/§21)

`JarvisPCMInjectIOProc`(순수 C): 매 콜백마다 OUTPUT 버퍼 전체를 우선 무음으로 다룬 뒤(실제로는 톤이 있으면 그 프레임만 덮어씀), 톤 진행 상태(`toneFramesRemaining`/`tonePhase`)는 **컨텍스트 구조체 안의 평범한(원자적이지 않은) 필드**로 옮겼다 — CoreAudio가 한 디바이스의 IOProc을 절대 동시에 두 번 호출하지 않으므로 이 두 필드는 Inject 콜백 하나만 건드리는 게 구조적으로 보장되어 원자성이 아예 불필요하다(§20의 단일-writer 모델을 C 레벨로 그대로 이식). 톤 계약은 정확히 보존: 1000 Hz, 48000프레임(1.0초 @ 48kHz), 진폭 0.1, 스테레오 양 채널 동일, 위상은 항상 0에서 시작하고 콜백 경계를 넘어 연속.

### 톤 요청 핸드오프 (§21) — 그대로 보존, 구현만 C로

```
idle(0) --[비RT: compare-exchange]--> queued(1) --[RT: 콜백이 소비]--> playing(2) --[RT: 48000프레임 완료]--> idle(0)
```

`JarvisPCMRuntimeRequestTone`(비RT, `idle→queued` compare-exchange 단 한 번)가 유일한 진실 공급원 — 큐잉/재생 중 재요청은 항상 거부, 큐 증가 없음, 재시작 없음, 완료된 요청의 stale 재생 없음(전부 테스트로 검증, 아래 참고).

### Swift 제어 평면 책임 (변경 없음, §9)

`SystemCallAudioPCMController`는 여전히: 디바이스 UID→ID 해석, ASBD 조회/포맷 검증(§48 — 콜백으로 옮기지 않음, 여전히 Swift 제어 평면), PCM 상태 머신, start/stop 오케스트레이션, UI, 구조적 로그, 5Hz 메트릭 게시를 담당한다. `AudioDeviceCreateIOProcID`/`AudioDeviceStart`/`AudioDeviceStop`/`AudioDeviceDestroyIOProcID` 호출 자체는 여전히 Swift(제어 평면, 논-RT)에서 이루어진다 — C 레이어는 오직 콜백 함수 포인터와 원자적 컨텍스트만 제공한다.

### 콜백 안전성 감사 (§44/§45, 필수)

**Swift 프로덕션 PCM 소스**(`SystemCallAudioPCMController.swift`): `AudioDeviceCreateIOProcIDWithBlock` 검색 결과 — 실제 사용 **0건**(과거 설계를 설명하는 주석 문자열 1건만 존재). `AudioDeviceCreateIOProcID`(non-block, C 함수 포인터 API)만 실제로 사용됨을 확인.

**C 콜백 본문**(`JarvisPCMCaptureIOProc`/`JarvisPCMInjectIOProc`): `malloc`/`calloc`/`realloc`/`free`/`pthread_mutex`/`os_unfair_lock`/`dispatch_sync`/`printf`/`fprintf`/`NSLog` 검색 결과 — 두 콜백 함수 본문 안에서 **0건**. `malloc`은 `JarvisPCMRuntimeCreate`(제어 평면)에만, `free`는 `JarvisPCMRuntimeDestroy`(제어 평면)에만 존재 — 콜백과는 완전히 분리된 코드 경로임을 명시적으로 구분해 기록한다.

```
callback reachable Swift invocation = NONE
callback reachable malloc/calloc/realloc/free = NONE
callback reachable locks/mutex/dispatch/semaphore = NONE
callback reachable file/network I/O = NONE
callback reachable logging = NONE
```

### UI / 5Hz 게시자 (변경 없음)

"Call PCM (Phase 3 CHECKPOINT 2)" 섹션 필드 전부 그대로: PCM I/O State/Format/RX Frames/Callbacks/RMS/Peak/Activity/TX Frames/Callbacks/Underruns/Test Tone, "Send 1 kHz Test Tone" 버튼(Routed+Running일 때만 활성화). 5Hz 타이머는 PCM이 `.running`일 때만 존재하며, `JarvisPCMRuntimeReadMetrics`로 C 원자 상태의 스냅샷을 읽어 dBFS로 변환한 뒤 `@Published`에 게시 — 콜백은 이 타이머를 절대 기다리지 않는다.

### 테스트

**하나의 프로덕션 알고리즘만 존재**하도록, `SystemCallAudioPCMControllerComputationTests.swift`를 완전히 재작성해 실제 C `JarvisPCMCaptureIOProc`/`JarvisPCMInjectIOProc`를 합성 `AudioBufferList`로 직접 호출·검증한다(더 이상 별도 Swift 재구현을 테스트하지 않음) — 기존 217개(코디네이션 16개 포함) 전부 유지, **합계 260개, 260 passed, 0 failed**:

- 제어 평면: `JarvisPCMRuntimeCreate`가 완전히 리셋된 컨텍스트 반환, `JarvisPCMRuntimeReset`이 이전 메트릭/대기 중인 요청까지 전부 제거, `JarvisPCMRuntimeAtomicsAreLockFree` 확인.
- **§39 RX**: 실제 C Capture IOProc으로 무음→0 메트릭, 풀스케일 신호→mean-square/peak=1.0, 여러 번 호출 시 프레임/콜백 누적, Capture 자신의 OUTPUT이 매번 완전히 0으로 채워짐.
- **§40 TX**: 실제 C Inject IOProc으로 톤 없을 때 완전한 무음, idle→queued 요청 성공, Queued/Playing 중 재요청 거부, Queued→Playing 전환, 정확한 결정적 사인파(주파수/진폭 정밀 검증), 콜백 경계 간 위상 연속성, 완료 시 Playing→Idle 전환과 나머지 구간 무음, 완료 후 재생 안 됨(stale replay 없음), 손상된 버퍼가 크래시 대신 underrun으로 기록.
- **§41 동시성**: `DispatchQueue.concurrentPerform`로 200개 동시 톤 요청 경쟁 시 compare-exchange가 정확히 승자 1명만 보장(완전히 결정적, wall-clock sleep 없음), 실제 두 스레드가 하나는 200회 synthetic Capture 콜백을 실행하고 다른 하나는 200회 메트릭을 읽는 동안 데드락 없음(`DispatchGroup` + 10초 타임아웃으로 확인).
- 포맷/dBFS 변환 테스트는 그대로 유지(§48, §16 — dBFS 변환이 이제 순수 Swift 프레젠테이션 헬퍼로만 존재함을 반영).

### Build

- `rm -rf .build && swift build --build-tests`: **PASS**, 경고 **0**(ClangImporter의 "built-in type 'Atomic' not supported" note는 정보성 note일 뿐 경고/에러 아님 — Swift가 `_Atomic` 필드를 원자 타입으로 직접 매핑하지 않는다는 의도된 사실을 보고할 뿐이며, 이 필드들은 전부 C 함수 호출로만 다뤄지므로 무해함), 에러 **0**
- `swift test`: **PASS**, **260/260**
- `Scripts/build-app.sh`: **PASS**
- 드라이버 소스 미변경 → 재설치 없음. **DRIVER REINSTALL NOT REQUIRED.**

### Headless / No-Call 안전성 재확인

앱을 3초간 실행(통화 없음, Work Mode 자동 ON)한 뒤 `JarvisAudioDriverTool status`로 실행 전/중 비교 — 완전히 동일: Capture/Inject `hidden=true active=false running=false canBeDefaultDevice=false/false`, route 완전 불변(Input=Microphone, Output=Smart M80C, SystemOutput=Mac Studio 스피커). 정상 종료(AppleScript quit, 크래시/행 없음) — 새 `AudioDeviceCreateIOProcID` 기반 콜백 경로로 바뀐 뒤에도 앱 종료 경로가 여전히 정상 동작함을 확인.

### 현재 게이트 상태

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **IMPLEMENTATION COMPLETE — LOCK-FREE HARDENING COMPLETE — C NATIVE IOPROC HARDENING COMPLETE — FINAL PASS PENDING MANUAL REAL-DEVICE RX/TX VALIDATION**
- **Phase 4**: **BLOCKED**

## CHECKPOINT 2 — 첫 실기기 RX/TX 재검증: RX PCM 항상 정확히 0 (근본원인 미확정 — 진단 계측 추가)

### 실기기 증거 (사용자 제공, 요약 없이 그대로 기록)

라이프사이클(Idle→Ringing→Answering→Active→Ending→Idle): **PASS**. Route takeover: **PASS**(Default Output=Jarvis Call Capture, Default Input=Jarvis Call Inject, System Output=원래 Mac Studio 스피커 그대로). Driver Capture/Inject Active. PCM state=running. 네이티브 포맷 검증 통과(양쪽 디바이스 48000Hz Float32 2ch interleaved). 네이티브 C IOProc 등록/시작: **PASS**, 실제 로그 순서:

```
22:38:57.957  [CALL-AUDIO] route verification pass ... state=routed
22:38:57.960  [CALL-PCM] prepare ...
22:38:57.963  [CALL-PCM] capture format ...
22:38:57.964  [CALL-PCM] inject format ...
22:38:58.015  [CALL-PCM] capture io created / capture started
22:39:00.757  [CALL-PCM] inject io created
22:39:00.758  [CALL-PCM] inject started / state=running
```

**핵심 결함**: RX 콜백은 명백히 실행됐다 — RX Frames 286,208 → 3,223,552 → 4,231,680으로, RX Callbacks 559 → 6,296 → 8,265로 계속 증가했다. 하지만 **RX RMS/Peak는 통화가 연결돼 있는 내내 정확히 -96.0 dBFS(무음 바닥), RX Activity=Silence로 고정**됐다 — 상대방이 실제로 말하고 있었음에도 수백만 프레임이 정확히 0으로 처리됐다. "타이밍 노이즈/settling으로 취급하지 말 것"이 명시적 지시였다.

TX는 오분류하지 않는다: TX Frames/Callbacks는 계속 증가, TX Underruns=0(Inject 네이티브 C IOProc이 실제로 실행 중이고 버퍼를 만들어내고 있다는 증거) — 하지만 이번 테스트에서는 "Send 1 kHz Test Tone"을 누르지 않았다(`[CALL-PCM] test-tone queued/started/completed` 로그 없음). 따라서 "TX silence callback = PASS"이지만 **"TX 1kHz 원격 전달 = NOT TESTED"**(FAIL도 PASS도 아님).

Teardown은 정확히 올바르게 동작했고, 검증된 불변식으로 보존해야 한다 — 실제 로그 순서: `lifecycle=idle` → `[CALL-AUDIO] restore started` → `[CALL-PCM] stop started` → `inject stopped` → `capture stopped` → `io disposed` → `PCM state=idle` → **그 다음에야** `Default Output restored` → `Default Input restored` → `restore verification PASS` → `Inject inactive` → `Capture inactive` → `Call Audio state=idle`.

부차적 결함(낮은 우선순위, 최소 UI 동기화 문제로 별도 처리): 실제 CoreAudio 로그가 성공적인 비활성화를 증명함에도(`set-active role=inject active=false readBackActive=false result=success`, capture도 동일) 최종 UI는 여전히 "Call Audio Driver = Active"를 표시했다 — "실제 드라이버 비활성화 실패"가 아니라 "stale diagnostic UI"로 분류.

### §8 코드 경로 감사 — 콜/버퍼 그래프 (FACT, 코드 리뷰로 확정)

```
A. Phone.app 통화 오디오 클라이언트
      │  (macOS 시스템 오디오 믹서가 이 스트림을 Default Output Device로 라우팅한다고 가정)
      ▼
B. Jarvis Call Capture 디바이스 — OUTPUT 스트림
      │  Driver_DoIOOperation(kAudioServerPlugInIOOperationWriteMix)
      │    → JarvisLoopbackBufferWrite(&device->loopback, ioMainBuffer, frameCount)
      ▼
C. Capture 디바이스 내부 JarvisLoopbackBuffer (SPSC 링, Capture/Inject 각자 완전히 분리된 인스턴스)
      │  Driver_DoIOOperation(kAudioServerPlugInIOOperationReadInput)
      │    → JarvisLoopbackBufferRead(&device->loopback, ioMainBuffer, frameCount)
      ▼
D. Capture 디바이스 — INPUT 스트림 (Bridge가 실제로 받는 데이터)
      │  AudioDeviceCreateIOProcID로 등록된 JarvisPCMCaptureIOProc(C, native)
      │    → inInputData->mBuffers[i]를 그대로 순회, mean-square/peak 계산 → RX 메트릭 원자적 발행
      ▼
Bridge RX 메트릭 (SystemCallAudioPCMController가 5Hz로 읽어 UI에 dBFS로 게시)
```

- **B/C 구간 (드라이버 loopback)**: `Driver_DoIOOperation`은 같은 디바이스의 WriteMix→loopback→ReadInput만 연결한다(다른 코드 경로가 개입하지 않음, 주석으로도 명시됨). `JarvisLoopbackBuffer.c`의 Write/Read는 표준 SPSC 링 버퍼로, interleaved 레이아웃/오버런(가장 오래된 프레임 드롭)/언더런(무음 채움) 처리가 모두 올바르다 — 코드 리뷰상 방향/버퍼 시맨틱 결함(H2/H3) 없음. 이번에 추가한 `selftest.c`의 `CheckPCMDiagnostics`가 실제 `DoIOOperation` 호출(합성 클라이언트 WriteMix → 실제 loopback → ReadInput, 정확한 selector 사용)로 이 경로를 바이트 단위로 검증해 **0 failures로 통과** — "고립된 링 버퍼 테스트"가 아니라 실제 클라이언트 write→driver→loopback→client read 경로 자체를 증명한다.
- **D 구간 (Bridge C IOProc 버퍼 해석)**: `JarvisPCMCaptureIOProc`는 `inInputData->mBuffers[i].mData`를 `Float32*`로 캐스팅해 `mDataByteSize / sizeof(Float32)`개 샘플을 그대로 읽고, `floatCount / JARVIS_PCM_CHANNEL_COUNT`로 프레임 수를 유도한다 — 인덱스/채널 수/프레임 수 유도 모두 정확. 드라이버가 non-zero를 준다면 Bridge가 이를 오독해 0으로 만들 수 있는 코드 경로가 보이지 않는다(H4 가능성 낮음, 코드 리뷰 기준).
- **A→B 구간 (Phone.app이 실제로 Capture에 쓰는지)**: **이 부분만 실기기 관찰로 확인할 수 없다.** 기존 코드에는 이 구간을 직접 증명할 계측이 전혀 없었다 — 이번 진단 계측(§10 아래)의 핵심 목적.

### §9 CoreAudio 콜백 시맨틱 — 로컬 SDK 헤더 확인 (FACT, 기억이 아닌 실제 헤더 인용)

`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/.../AudioServerPlugIn.h`:

- `kAudioServerPlugInIOOperationWriteMix`: "This operation puts the data into the device's ring buffer for consumption of the hardware. Note that this operation always happens **in-place in the main buffer** passed to DoIOOperation(). It is **required** that this operation be implemented if the AudioDevice has output streams."
- `kAudioServerPlugInIOOperationReadInput`: "This operation transfers the input data from the device's ring buffer to the provided buffer in the stream's native format. Note that this operation always happens **in-place in the main buffer**... **required** if the AudioDevice has input streams."

→ 드라이버가 `ioMainBuffer`를 `(const float *)`/`(float *)`로 직접 다루는 현재 구현은 문서화된 계약과 정확히 일치한다(별도의 AudioBufferList 래핑이 아니라 stream 포맷대로의 raw 샘플 버퍼). WriteMix는 "모든 클라이언트의 데이터가 이미 믹싱된 결과"를 드라이버가 받는 지점 — 즉 Phone.app이 진짜로 이 디바이스에 렌더링하고 있다면, Bridge 자신의 (항상 무음인) 출력 기여와 합쳐지더라도 non-zero가 섞여 들어와야 한다. 이 사실이 아래 H1 가설에 힘을 싣는 핵심 근거다.

### 결정 매트릭스 분류 (Case A/B/C/D)

기존 드라이버 진단으로는 A/B/C 단계를 구분할 계측이 없었으므로(§10 요구사항대로), **이번 세션에서 §10-§15 계측을 새로 추가**했다(RT-safe, 아래 참조) — 하지만 이 계측을 반영한 실기기 재테스트는 아직 수행되지 않았다. 따라서 이번 라운드의 분류는 **INFERENCE**(코드 리뷰 + 기존 로그로부터의 추론)이며, 다음 실기기 재테스트의 새 계측 값이 이를 FACT로 확정하거나 반증한다.

- **Case B/C (드라이버 loopback 결함 / Bridge IOProc 해석 결함)는 이번 세션에 추가한 `selftest.c`의 실제 `DoIOOperation` 경로 통합 테스트로 사실상 배제됐다(FACT, in-process)** — 다만 이는 "합성 클라이언트가 실제로 WriteMix를 호출했을 때"의 검증이며, "실제 호스트가 이 디바이스의 WriteMix를 아예 호출하는지"는 별개의 질문이다.
- **Case A (Phone.app이 애초에 Jarvis Call Capture로 오디오를 보내지 않음)가 가장 유력한 INFERENCE**다. 근거:
  1. `SystemCallAudioPCMController.start()`는 Bridge 자신을 Capture 디바이스의 IOProc 클라이언트로 등록하고 `AudioDeviceStart`를 호출한다 — CoreAudio는 **어떤 클라이언트든 하나라도** `AudioDeviceStart`를 호출하면 그 디바이스의 IO 사이클(WillDoIOOperation/BeginIOOperation/DoIOOperation WriteMix+ReadInput/EndIOOperation)을 계속 돌린다. 즉 **"RX Callbacks/Frames가 계속 증가한다"는 사실 자체는 Phone.app이 이 디바이스에 실제로 데이터를 쓰고 있다는 증거가 아니다** — Bridge 자신의 등록만으로도 설명 가능하다. 이는 기존 문서 어디에도 명시되지 않았던, 이번 감사에서 새로 확인한 중요한 사실이다.
  2. `CallAudioSessionController.attemptTakeover`(§8에서 재확인)의 순서는 `callState == .active`가 **이미** 감지된 이후에만 시작된다 — 즉 Phone.app의 통화 오디오 엔진은 네이티브 Answer 입력 직후 ~1-2초의 Answering 구간을 거쳐 이미 렌더링을 시작했을 가능성이 높은 시점에서야 Jarvis가 Default Output/Input을 바꾼다. 만약 Phone.app의 오디오 유닛이 "현재 시스템 기본 출력"을 인스턴스화 시점에 고정하고 이후의 기본 디바이스 변경을 동적으로 따라가지 않는다면(다수의 macOS 앱에서 실제로 관찰되는 동작), Jarvis의 늦은 라우팅 전환은 이미 열려 있는 Phone.app의 오디오 그래프에 아무 영향을 주지 못한다 — "Capture IOProc은 도는데 신호는 0"과 정확히 일치하는 설명이다.
- **Case D(현재 실패가 재현 안 됨)**는 이번 라운드에서는 명백히 아니다 — 문제가 재현됐고 정확히 기록됐다.

**결론(솔직하게): ROOT CAUSE NOT YET PROVEN.** Case A가 유력한 INFERENCE이지만, "Phone.app이 WriteMix를 실제로 몇 번 호출했는지"를 보여주는 FACT 데이터(§10 계측)를 실기기에서 아직 관측하지 못했다. 추측을 확정으로 격상하지 않는다.

### §10-§15 새로 추가한 RT-safe 진단 계측 (드라이버)

`bridge/AudioDriver/Plugin/PlugInTypes.h` / `PlugInInterface.c`에 `JarvisPCMDeviceDiagnostics`(버전 필드 포함 스냅샷 구조체) 추가, Capture/Inject 각각에 다음 필드(§27 — Inject 쪽도 향후 TX 디버깅을 위해 대칭으로 계측):

- `ioClientCount` — 기존에 이미 존재하던 `AudioDeviceStart`/`Stop` 카운터를 그대로 노출(새 계측 아님, 재사용). **이 값이 실기기 통화 중 1을 넘지 않으면(즉 Bridge 자신만 클라이언트라면) Phone.app이 이 디바이스에 IO를 아예 시작하지 않았다는 강력한 FACT 증거가 된다.**
- `outputOperationCount`/`outputFrames`/`outputNonZeroCallbacks`/`outputPeakLinear` — WriteMix 단계(클라이언트→드라이버 OUTPUT).
- `loopbackWriteFrames`/`loopbackReadFrames`/`loopbackUnderrunCount`/`loopbackOverrunFrameCount` — 기존 `JarvisLoopbackBuffer`의 `writeIndex`/`readIndex`/`underrunCount`/`overrunFrameCount`를 새 `JarvisLoopbackBufferGetCounters()`로 재노출(중복 카운터 신설 안 함, §10 요구사항대로).
- `inputOperationCount`/`inputFrames`/`inputNonZeroCallbacks`/`inputPeakLinear` — ReadInput 단계(드라이버가 Bridge에게 실제로 건네는 것).

**RT-안전성**: `Driver_DoIOOperation`의 WriteMix/ReadInput 분기 안에서 콜백-로컬(스택) 누적 후 몇 개의 relaxed 원자 연산으로 한 번만 발행 — 샘플당 원자 연산 없음, 로깅/할당/락 없음(기존 Bridge `JarvisPCMCaptureIOProc`의 RX peak/mean-square 계산과 동일한 패턴). Raw PCM은 어디에도 보존하지 않음 — 집계 카운터/피크만.

**리셋**: 기존 `JarvisLoopbackBufferReset` 호출 지점(kJarvisDevicePropertyActive Set, kJarvisDevicePropertyClearBuffers Set) 두 곳에 `JarvisPCMDeviceDiagnosticsReset` 호출을 나란히 추가 — 두 곳 다 제어 평면(RT 아님)에서만 호출됨.

**노출**: 새 읽기 전용 커스텀 프로퍼티 `kJarvisDevicePropertyPCMDiagnostics`('Rpcm')를 기존 `kJarvisDevicePropertyActive`/`kJarvisDevicePropertyClearBuffers`와 동일한 CFPropertyList(CFData) 마샬링 방식으로 추가 — `Driver_SetPropertyData`에 해당 case가 없으므로 Set은 항상 `kAudioHardwareUnsupportedOperationError`로 자동 거부됨(읽기 전용 강제). `kCustomPropertyInfo` 배열을 2개→3개로 확장.

**CLI**: `JarvisAudioDriverTool pcm-inspect`(READ-ONLY) 신설 — Capture/Inject 각각의 OUTPUT/LOOPBACK/INPUT 3단계 카운터, `ioClientCount`, 현재 Input/Output/System Output 아이덴티티를 출력하고, 결과 해석 가이드(Case A/B/C 판별 기준)를 함께 인쇄한다. 라우트를 설정하거나 디바이스를 활성화하거나 IOProc을 시작하거나 PCM을 쓰는 코드는 전혀 호출하지 않는다(코드 검사로 확인 — `AudioObjectSetPropertyData`/`AudioDeviceStart`/`AudioDeviceCreateIOProcID` 호출 없음).

### §22-§23 minimal fix 여부

드라이버 loopback(Case B)도 Bridge IOProc 해석(Case C)도 코드 리뷰 + 새 통합 테스트로 결함이 발견되지 않았으므로 **이번 라운드에서는 "최소 수정"을 적용하지 않았다** — 계측만 추가했다. `CanBeDefaultDevice`/`CanBeDefaultSystemDevice`/activation lifecycle/route 설계는 손대지 않음.

### §18-§21 Route-timing 결론

**현재 Active-only takeover 타이밍이 여전히 유효한가: UNPROVEN.** §9의 코드 리뷰는 "Phone.app이 이미 열려 있는 오디오 그래프를 늦게 바뀐 기본 디바이스로 따라가지 못할 수 있다"는 강한 INFERENCE를 제공하지만, 이를 FACT로 만드는 것은 §10 계측(특히 `ioClientCount`, `outputOperationCount`/`outputNonZeroCallbacks`)의 실기기 값이다. **이번 세션에서는 라우팅 타이밍을 절대 앞당기지 않았다** — "검증된 Active 이전에는 라우트를 건드리지 않는다"는 안전 불변식은 그대로 보존했다(v1 회귀 — 오디오를 너무 일찍 열면 네이티브 착신 통화 자체가 감지되지 않게 됐던 사고 — 를 명시적으로 인지). §21이 명시적으로 허용한 대로 라우트 선택 타이밍과 PCM I/O 타이밍은 서로 다른 안전 경계로 남아 있으며, 이번 세션은 어느 쪽도 변경하지 않았다. 만약 재테스트가 Case A를 FACT로 확정하면, 다음 세션은 §20의 옵션(A/B/C) 중 하나를 **새로운 "Phase 3 CHECKPOINT 2 sub-gate: Pre-Answer Route Preparation"**으로 제안만 하고, 절대 자동으로 구현하지 않는다.

### §25-§26 "Call Audio Driver" stale UI — 근본원인 확정 및 최소 수정 적용 (FACT)

**근본원인(코드로 확정)**: `AudioDriverStatus`(`Sources/JarvisCallBridge/System/AudioDriverStatus.swift`)는 실제 `kJarvisDevicePropertyActive` 프로퍼티를 정확히 읽는다(진짜 드라이버 상태 조회, `CallAudioSessionState`에서 파생하는 게 아님 — 이 부분은 원래도 올바른 설계였다). 문제는 **갱신 트리거**였다: 이 클래스는 자신만의 독립적인 5초 `Timer`에서만 `refresh()`를 호출했다 — `CallAudioSessionController`가 실제로 `kJarvisDevicePropertyActive`를 false로 성공적으로 Set한(teardown) 바로 그 순간과 아무 연결이 없었다. 그 결과 실제 비활성화가 완료된 후에도 UI는 최대 5초간 이전 "Active" 값을 계속 보여줄 수 있었다 — 정확히 이번 실기기 테스트에서 관찰된 증상.

**적용한 최소 수정**: `BridgeViewModel.init`에서 이미 존재하던 `callAudioSession.onRouteMutated` 클로저(Phase 3 CHECKPOINT 1의 Audio Route UI 동기화 수정이 사용하던 바로 그 트랜잭션 경계 — takeover/restore/rollback/ownership-loss/startup-recovery 전부 종료 시 1회 호출됨)에 `audioDriver.refresh()` 호출을 한 줄 추가했다. `refreshRouteSnapshot`과 완전히 동일한 철학: 실제 드라이버 프로퍼티를 다시 읽을 뿐 `CallAudioSessionState`에서 파생하지 않으며, 갱신 실패가 있어도 진단 표시에만 영향을 줄 뿐 통화 롤백/디바이스 재활성화/라우트 변경을 절대 유발하지 않는다(둘 다 순수 프레젠테이션 레이어 호출이고 서로 독립적).

### §32-§36 테스트

- `LoopbackBufferTests.swift`: `JarvisLoopbackBufferGetCounters`에 대해 2개 신규 테스트(write/read/underrun/overrun 카운터가 누적 프레임 수를 정확히 반영하는지, nil out-parameter를 허용하는지).
- `AudioDriver/Plugin/selftest.c`: `CheckPCMDiagnostics` 신설 — 읽기 전용 강제(`IsPropertySettable`==false, `SetPropertyData` 거부), 리셋 후 0 시작, 실제 `DoIOOperation(WriteMix)`→loopback→`DoIOOperation(ReadInput)` 경로를 합성 non-zero Float32 stereo 데이터로 바이트 단위 검증(§22-23이 요구한 "고립된 링 버퍼 테스트보다 중요한" 실제 연산 시맨틱 테스트), non-zero PCM에서 operationCount/frames/nonZeroCallbacks/peak가 정확히 증가, all-silence PCM에서 operationCount/frames는 증가하되 nonZeroCallbacks/peak는 정확히 0으로 유지되는지 확인. `CustomPropertyInfoList`가 이제 3개 항목을 보고하는지도 갱신해 검증.
- `AudioDriverStatusUISynchronizationTests.swift`(신규): `AudioDriverStatus`에 테스트 전용 `refreshCount`를 추가해(진짜 드라이버가 없는 테스트 환경에서는 `state`가 항상 `.notInstalled`라 그것만으로는 회귀를 못 잡음) takeover/restore/rollback 각 트랜잭션 경계에서 `refresh()`가 실제로 호출되는지, 그리고 그 호출이 `callAudioSession.state`에 어떤 영향도 주지 않는지 확인.
- 신규 6개(로열백 카운터 2 + UI 동기화 4) + 기존 260개 = **266개, 266 passed, 0 failed**. 기준 260개 전부 유지, 의도적 축소 없음.

### Build

- `bridge/AudioDriver/Plugin/PlugInInterface.c`, `PlugInTypes.h`, `selftest.c`, `AudioDriver/Shared/JarvisLoopbackBuffer.c/.h` 변경 → `./Scripts/build-driver.sh` 재실행: **컴파일 경고 0, selftest 0 failures**(신규 `CheckPCMDiagnostics` 케이스 전부 PASS 포함).
- `rm -rf .build && swift build --build-tests`: **PASS, 경고 0**
- `swift test`: **PASS, 266/266**
- `./Scripts/build-app.sh`: **PASS**
- `git status --porcelain admin/ api/ web/`: 완전히 비어 있음(clean) — 확인됨.
- 새로 생긴 최상위 디렉토리 없음 — `bridge/call-bridge/`, `swift/`, `mac/`, `desktop/`, `callbridge/` 전부 미생성.
- **드라이버 소스가 변경됐으므로 DRIVER REINSTALL REQUIRED** — 사용자가 직접 `Scripts/uninstall-driver.sh` 후 `Scripts/install-driver.sh`를 실행해야 새 계측/프로퍼티가 실제 coreaudiod에 반영된다. 이번 세션은 install/uninstall을 실행하지 않았다.

### Headless / No-Call 안전성

기존 테스트 스위트(`testStartArmsWorkModeAndAutoAnswerByDefaultWithoutTouchingAudio` 등)가 그대로 통과 — Work Mode ON, 통화 없음 상태에서 Capture/Inject 활성화 호출 0회, Default Output/Input 변경 0회를 계속 보장. 이번 세션의 변경(드라이버 계측은 읽기 전용 프로퍼티만 추가, UI 수정은 `onRouteMutated`에서만 트리거)은 이 불변식에 영향을 주지 않는다.

### 다음 실기기 진단 재테스트 — 정확한 절차

1. 드라이버 소스가 변경됐으므로 먼저 직접(에이전트 아님) `Scripts/uninstall-driver.sh` → `Scripts/install-driver.sh` 실행.
2. 앱 실행, Work Mode ON, Auto Answer OFF(수동 확인을 위해).
3. 실제 셀룰러 착신 전화 1건을 걸어 수동으로 응답.
4. Active + Routed + PCM Running이 될 때까지 대기.
5. 상대방이 계속 5초 이상 말하게 함.
6. **통화가 여전히 Active인 상태에서** 터미널에서 `swift run JarvisAudioDriverTool pcm-inspect` 실행, 출력 전체 저장.
7. (선택, 이미 RX 조사에 충분한 증거가 모였고 TX 계측도 준비됐다고 판단되면) "Send 1 kHz Test Tone"을 **한 번만** 눌러 상대방이 실제로 들었는지 확인.
8. 상대방이 종료, Bridge 로그 저장.

**해석 가이드(사전 작성, §17 결정 매트릭스 그대로)**:
- `ioClientCount`가 통화 내내 1(=Bridge 자신)을 넘지 않음 → Phone.app이 이 디바이스에 IO를 아예 시작하지 않았다는 강한 FACT — Case A 확정, 다음 조사는 라우트 선택 타이밍.
- `outputOperationCount`=0, 또는 frames>0인데 `outputNonZeroCallbacks`=0(상대방이 실제로 말하고 있었는데도) → Phone.app이 데이터를 보내지 않음 — 마찬가지로 Case A.
- `outputNonZeroCallbacks`>0인데 `loopbackReadFrames`가 `loopbackWriteFrames`에 비해 크게 뒤처짐 → HAL loopback 결함(Case B) — 예상 밖의 결과, 추측하지 말고 정확한 스냅샷/로그를 그대로 보존해 재검토.
- `inputOperationCount`/`inputNonZeroCallbacks`가 non-zero인데 Bridge 자신의 `[CALL-PCM]` RX 메트릭 로그는 여전히 -96.0 dBFS → Bridge C IOProc 해석 결함(Case C) — 이 역시 이번 세션의 코드 리뷰/통합 테스트와 모순되므로 예상 밖의 결과, 추측 금지.
- 전부 non-zero → 이번에 재현되지 않은 것 — 새 근거를 만들지 말고 정확한 스냅샷을 그대로 보존.

### 현재 게이트 상태 (갱신)

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **BLOCKED — ROOT CAUSE NOT YET PROVEN / DIAGNOSTIC INSTRUMENTATION READY FOR REAL-DEVICE RETEST** (DRIVER REINSTALL REQUIRED before retest)
- **Phase 4**: **BLOCKED**

에이전트는 실제 전화를 걸지 않았고, 드라이버를 수정/재설치하지 않았고, Realtime/STT/TTS/녹음을 구현하지 않았고, CHECKPOINT 2를 넘어서지 않았다.

## CHECKPOINT 2 — RX Metrics Pipeline 근본원인 조사 + 최소 수정

### §1 두 번째 실기기 재검증 — 이전 추론을 뒤집는 새 FACT

새로 추가한 stage-level 드라이버 계측(`pcm-inspect`)을 반영해 사용자가 실제 셀룰러 통화로 재검증했다. 이번 결과는 이전 라운드의 H1/Case A 추론을 **명시적으로 뒤집는다** — 아래 FACT들은 이전 "Phone.app이 Capture로 오디오를 보내지 않는다"는 추론을 **대체(supersede)**한다:

라우트(Active 중): Default Input=Jarvis Call Inject, Default Output=Jarvis Call Capture, System Output=Mac Studio 스피커.

Capture 드라이버 진단(상대방이 계속 말하는 중):

```
active: true, ioClientCount: 1

Capture OUTPUT:  operationCount=3639  frames=1,623,040  nonZeroCallbacks=3493  peakLinear=0.16633263
Capture LOOPBACK: writeFrames=1,623,040  readFrames=1,576,620  underrunCount=0  overrunFrameCount=23,340
Capture INPUT:   operationCount=1616  frames=1,553,280  nonZeroCallbacks=1565  peakLinear=0.21116002
```

**따라서 다음은 이제 REAL-DEVICE PASS로 확정(FACT)한다**: 통화 PCM → Capture OUTPUT → HAL loopback → Capture INPUT, 전 구간. 이전 CHECKPOINT 2 섹션의 "Phone.app이 이 디바이스에 렌더링하지 않을 가능성이 높다"는 INFERENCE는 **틀린 것으로 판명됐다** — 삭제하지 않고 이 섹션에서 명시적으로 superseded로 표시한다. **Pre-Answer Route Preparation은 구현하지 않으며, route timing도 변경하지 않는다** — 이번 근거는 오히려 현재 Active-only takeover 타이밍이 실제로 유효함을 뒷받침한다.

**`ioClientCount` 해석 정정(중요)**: 이전 섹션은 `ioClientCount==1`을 "Phone.app이 IO를 시작하지 않았다"는 강한 증거로 제시했는데, 이번 실측이 정확히 그 반증이다 — `ioClientCount=1`이면서 동시에 `outputNonZeroCallbacks=3493`, `outputPeakLinear>0`이었다. 즉 **Phone.app은 별도의 `AudioDeviceStart` 클라이언트로 등록되지 않고도(혹은 그 등록이 `ioClientCount`에 반영되지 않는 방식으로도) 실제 PCM을 Capture OUTPUT에 쓸 수 있다** — `ioClientCount`는 보조 진단 정보일 뿐이며, 실제 신호 유무를 판정하는 것은 항상 `outputNonZeroCallbacks`/`outputPeakLinear`(그리고 대칭적으로 `inputNonZeroCallbacks`/`inputPeakLinear`)다. `pcm-inspect`의 해석 가이드 텍스트에서 `ioClientCount` 단독을 Case A의 결정적 증거처럼 서술한 부분은 이 정정을 반영해 더 이상 그렇게 읽지 않는다.

### §2 TX — REAL-DEVICE END-TO-END PASS 확정

같은 통화 중 로그: `test-tone queued`(23:49:59.354) → `started`(23:49:59.519) → `completed`(23:50:00.519). **사용자가 상대방이 실제로 1kHz 톤을 들었음을 확인했다.** 따라서 결정적 톤 생성 → 네이티브 Inject C IOProc → Inject HAL loopback → Phone.app 통화 입력 경로 → 셀룰러 원격 전달까지 전 구간이 **REAL-DEVICE PASS**로 확정됐다. 이번 세션은 TX 아키텍처(톤 상태 머신/주파수/진폭/길이/Inject C IOProc/Inject loopback)를 전혀 변경하지 않았다 — 회귀 위험 없음.

### §3 Teardown — 계속 PASS, 변경 없음

`PCM stop started` → `Inject stopped` → `Capture stopped` → `IO disposed` → `PCM state=idle` → (그 다음에야) `Default Output restored` → `Default Input restored` → `route verification PASS` → `Inject inactive` → `Capture inactive` → `Call Audio state=idle`. 이 순서를 그대로 보존했다 — `SystemCallAudioPCMController.stop()`/`CallAudioSessionController`는 이번 세션에서 손대지 않았다.

### §5-§9 남은 결함 — RX 메트릭 파이프라인, 그리고 근본원인

Capture INPUT(드라이버 측정)은 `nonZeroCallbacks=1565`, `peakLinear=0.21116002`로 명백히 non-zero인데, Bridge UI는 통화 내내 RX RMS/Peak = -96.0/-96.0을 유지했다. 즉 **RX 업스트림(A→B→C→D)은 전부 PASS, RX 메트릭 파이프라인(D 이후 — Bridge C IOProc → atomic → Swift snapshot → dBFS → UI)만 결함**이라는 게 이번 조사의 정확한 실패 경계다.

**§8 파이프라인 데이터 맵(코드 감사로 확정, FACT)**:

```
Stage 1  C IOProc 입력 샘플 타입:        const Float32* (inInputData->mBuffers[i].mData)
Stage 2  로컬 peak/meanSquare 타입:      float / double(sumSquares 누산), 스택 로컬
Stage 3  원자 저장 타입/표현:            _Atomic uint32_t, IEEE-754 비트 패턴(memcpy, 수치 캐스팅 아님)
Stage 4  JarvisPCMMetricsSnapshot 필드:  float rxMeanSquareLinear / rxPeakLinear (C 원본 그대로)
Stage 5  Swift로 임포트된 타입:          동일 C 구조체를 ClangImporter가 직접 임포트 — 별도 Swift 미러 구조체 없음
Stage 6  Swift dB 변환 입력:             Double(sqrt(Double(rxMeanSquareLinear))) → Float, 그리고 rxPeakLinear 그대로
Stage 7  @Published 필드:                CallAudioPCMMetrics.rxRMSDBFS / rxPeakDBFS / rxActive
```

- **Stage 3(비트 패턴 표현)**: `RecordRX`/`JarvisPCMRuntimeReadMetrics` 둘 다 `memcpy(&bits, &floatValue, sizeof(...))`로 IEEE-754 비트 패턴을 그대로 보존한다 — `(uint32_t)floatValue` 같은 수치 캐스팅(0.x 값을 정수 0으로 만드는 버그 클래스)은 코드 어디에도 없음을 확인했다. 아래 §10 테스트로 실측 값(0.16633263, 0.21116002 포함) round-trip을 증명.
- **Stage 4-5(ABI/구조체 레이아웃)**: `JarvisPCMMetricsSnapshot`은 `Sources/JarvisPCMRealtime`이라는 정식 SwiftPM C 타겟의 public header에 선언되어 있고, `JarvisCallBridge`가 `import JarvisPCMRealtime`으로 그 헤더를 직접 임포트한다 — Swift가 보는 `JarvisPCMMetricsSnapshot`은 손으로 미러링한 별도 구조체가 아니라 **ClangImporter가 만든 동일 C 구조체 그 자체**다. 이는 `JarvisAudioDriverTool`이 CFData로 수동 디코딩해야 했던 프로세스 간(cross-process) 상황과 근본적으로 다르다 — ABI/레이아웃 불일치(카테고리 D)는 구조적으로 발생할 수 없다.
- **Stage 6(dBFS 변환)**: `SystemCallAudioPCMController.dBFS`는 `guard linear > 0 else { return floor }`; `20*log10(linear)` — RMS/Peak 각각 올바른 입력(RMS linear from sqrt(meanSquare), Peak linear 그대로)을 받는다. 공식 자체는 코드 리뷰상 정확.

**근본원인(§13 요구사항대로 실측으로 검증)**: `JarvisPCMCaptureIOProc`의 기존 코드는 `inInputData`를 읽기 **전에** `FillSilence(outOutputData)`를 먼저 호출했다. `AudioDeviceIOProc`의 문서화된 계약은 동일 포맷/동일 바이트 크기(양쪽 다 48kHz Float32 stereo)를 가진 단일 콜백·양방향 디바이스에서 `inInputData`와 `outOutputData`가 서로 다른 메모리임을 보장하지 않는다 — 만약 실제 호스트가 이 두 버퍼를 같은 메모리로 넘기는 경우(aliased), 먼저 실행되는 `FillSilence`가 아직 읽지 않은 RX 샘플을 덮어써버려 **정확히 "콜백/프레임은 증가하는데 신호는 항상 0"**이라는 관찰된 증상을 만들어낸다. 이 가설을 in-process로 직접 검증하기 위해 실제 프로덕션 `JarvisPCMCaptureIOProc`를 호출하되 `inInputData`와 `outOutputData`가 **동일 메모리**를 가리키도록 구성한 새 테스트(`testCaptureIOProcReadsInputBeforeAnyPossibleAliasedOutputZeroing`)를 작성 — **수정 전 코드에서 실제로 실패**(RX peak/meanSquare가 알려진 non-zero 입력에도 불구하고 0으로 관측)함을 확인했다. 기존 21개 테스트는 전부 `inInputData`/`outOutputData`를 별도로 `malloc`하므로 이 실패 모드를 절대 재현할 수 없었다 — "이전 테스트가 왜 이걸 못 잡았는가"에 대한 정확한 답.

### §22-§23/§34 최소 수정 (FACT — in-process로 재현·수정·검증됨)

`Sources/JarvisPCMRealtime/JarvisPCMRealtime.c`의 `JarvisPCMCaptureIOProc`에서 순서만 변경했다: `inInputData`를 전부 읽고 `RecordRX`까지 마친 **다음에** `FillSilence(outOutputData)`를 호출하도록 재배치. 버퍼가 실제로 분리돼 있는(기존 모든 합성 테스트가 검증하는) 정상 케이스에서는 동작이 완전히 동일하고, 두 버퍼가 aliased인 경우의 실패 모드를 구조적으로 제거한다. 다른 어떤 것도 바꾸지 않았다 — HAL 드라이버(`AudioDriver/*`), route timing, TX 아키텍처, teardown 순서, RT-safety 불변식(락/로깅/할당/Swift 호출 없음 — 원자 연산과 지역 스택 산술만) 전부 그대로.

수정 후 새 테스트는 PASS, 기존 21개도 전부 그대로 PASS(순서 변경이 분리된 버퍼 케이스의 동작을 바꾸지 않음을 증명).

### §24-§28 새 프로덕션 파이프라인 테스트

`SystemCallAudioPCMControllerComputationTests.swift`에 5개 추가:

- `testCaptureIOProcReadsInputBeforeAnyPossibleAliasedOutputZeroing` — aliased 버퍼 회귀 테스트(위 근본원인 증거).
- `testAtomicFloatBitPatternRoundTripsExactlyForRealDeviceObservedAmplitudes` — 실제 통화에서 관측된 정확한 값(0.16633263, 0.21116002) 포함 5개 진폭이 real production path(`JarvisPCMCaptureIOProc`→`RecordRX`→`JarvisPCMRuntimeReadMetrics`)를 통해 bit-exact round-trip.
- `testProductionRXPipelineAmplitudeToDBFSLadder` — 1.0/0.5/0.25/0.1 진폭 → 실제 `SystemCallAudioPCMController.dBFS` 헬퍼로 0/-6.02/-12.04/-20 dBFS 근사치 검증.
- `testProductionRXPipelineSilenceReportsFloor` — 무음 → floor(-96 dBFS) 확인.
- `testMultiCallbackSilenceSignalSilenceTransitionsAreAllReflected` — silence→signal(0.6)→signal(0.3)→silence 4콜백 연속 호출에서 매번 최신 값으로 갱신됨(첫 콜백에 고착되지 않음)을 확인, 프레임/콜백 카운터는 누적됨을 함께 검증.

`SystemCallAudioPCMControllerComputationTests` 스위트: **32/32 passed**(기존 27 + 신규 5). 전체 스위트: **271/271 passed**(기존 266 + 신규 5), 실패 0, 기준 축소 없음.

### §16/§49 새 저빈도 진단 로그

`SystemCallAudioPCMController.publishMetrics()`(이미 non-RT, 5Hz UI 타이머에서만 실행)에 `[CALL-PCM-METRICS]` 라인을 추가 — `lastMetricsLogAt`로 ~1Hz로 스로틀링, `start()`마다 리셋(이전 통화의 타임스탬프가 새 통화로 새어들지 않음). 필드: `rxFrames`/`rxCallbacks`/`rawMeanSquareLinear`/`rawPeakLinear`/`rmsDbFS`/`peakDbFS`/`activity`. Raw PCM/발신자 정보 없음, 집계값만.

### §18/§20/§21 준수 확인

- **드라이버 미변경**: `AudioDriver/*`, `JarvisLoopbackBuffer`, `kJarvisDevicePropertyPCMDiagnostics` 전부 이번 세션에서 손대지 않음 — `git status --porcelain` 확인. **DRIVER MODIFIED = NO. DRIVER REINSTALL REQUIRED = NO**(이번 수정 범위 한정 — 이전 세션에서 진단 계측 추가로 이미 대기 중이던 재설치 요구는 그 세션 자체의 요구사항으로 별개로 남아 있음).
- **Route timing 미변경**: `CallAudioSessionController`/`attemptTakeover` 전혀 수정하지 않음.
- **TX 미변경**: `JarvisPCMInjectIOProc` 로직 전혀 수정하지 않음(같은 파일 내 `JarvisPCMCaptureIOProc`만 수정).
- **Teardown 미변경**: `stop()` 순서 그대로.
- **Driver-status UI 수정(이전 세션)**: 재구현하지 않음, 그대로 유지.

### Build

- `rm -rf .build && swift build --build-tests`: **PASS, 경고 0**
- `swift test`: **PASS, 271/271**
- `./Scripts/build-app.sh`: **PASS**
- `git status --porcelain admin/ api/ web/`: 비어 있음(clean)
- 새 최상위 디렉토리 없음.
- **DRIVER REINSTALL REQUIRED = NO** — 이 수정은 앱 번들(`Sources/JarvisPCMRealtime`, `Sources/JarvisCallBridge`)에만 있고 `.driver` 번들과 무관하다. 다음 실기기 재테스트는 앱을 재빌드/재실행하기만 하면 된다.

### No-Call 안전성

`testStartArmsWorkModeAndAutoAnswerByDefaultWithoutTouchingAudio` 재확인 — Work Mode ON, 통화 없음 상태에서 Capture/Inject 활성화 0회, Default Output/Input 변경 0회, PCM 관련 로그는 `[CALL-PCM] realtime backend=native-c-ioproc`(정적 초기화 로그) 하나뿐, `[CALL-PCM-METRICS]`는 PCM Running 상태에서만 발행되므로 이 시나리오에서는 전혀 출력되지 않음.

### 다음 실기기 재검증 — 정확한 절차

1. 드라이버 재설치 불필요 — 앱만 재빌드/재실행.
2. Work Mode ON, Auto Answer OFF.
3. 실제 셀룰러 착신 전화 1건, 수동 응답.
4. Active + Routed + PCM Running 대기.
5. 상대방이 5초 이상 계속 말하게 함 → RX Frames/Callbacks 증가, **RX RMS/Peak가 -96 dBFS를 벗어나 반응하는지 확인**(정확한 dB 값은 셀룰러 게인/코덱/잡음억제에 따라 다르므로 미리 정하지 않음 — "신호에 반응하는가"만 확인).
6. 상대방이 2-3초 침묵 → RX RMS/Peak가 다시 floor 쪽으로 낮아지는지 확인.
7. 1kHz 톤은 이미 실기기 종단간 PASS로 확정됐으므로 재테스트 불필요(원하면 해도 무방).
8. 상대방 종료, 로그 저장 — `[CALL-PCM-METRICS]` 라인들이 통화 중 신호 변화를 반영하는지 확인.
9. Idle 복귀, 원래 라우트 복원, Recovery Record=None 확인.

### 현재 게이트 상태 (갱신)

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **IMPLEMENTATION FIX COMPLETE — FINAL PASS PENDING ONE MORE REAL-DEVICE RX RETEST** (DRIVER REINSTALL NOT REQUIRED)
- **Phase 4**: **BLOCKED**

에이전트는 실제 전화를 걸지 않았고, HAL 드라이버를 수정/재설치하지 않았고, route timing을 변경하지 않았고, TX/teardown을 변경하지 않았고, Realtime/STT/TTS/녹음을 구현하지 않았고, Phase 4로 진행하지 않았다.

## CHECKPOINT 2 — RX IOProc Stream Usage / Input Buffer Delivery 조사

### §1/§35 이전 "근본원인"의 정정 — superseded, 대체됨

이전 섹션에서 근본원인으로 지목한 `inInputData`/`outOutputData` 버퍼 aliasing 순서 문제는 **정당한 방어적 버그였고, 그 수정(입력을 먼저 읽고 출력을 나중에 무음화)은 그대로 유지한다** — 회귀 테스트(`testCaptureIOProcReadsInputBeforeAnyPossibleAliasedOutputZeroing`)도 유지된다. **하지만 그 수정을 반영한 이후의 실기기 재통화에서 정확히 동일한 실패가 재현됐다**: 상대방이 계속 말하는 중에도 `rawMeanSquareLinear=0.0`, `rawPeakLinear=0.0`, `rmsDbFS=-96.0`, `peakDbFS=-96.0`, `activity=silence`가 통화 내내 유지됐다. 대표 값:

```
rxFrames=102400   rxCallbacks=200   rawMeanSquareLinear=0.0  rawPeakLinear=0.0
...
rxFrames=2431488  rxCallbacks=4749  rawMeanSquareLinear=0.0  rawPeakLinear=0.0
```

**따라서 버퍼 aliasing 순서 문제는 실제 근본원인이 아니었던 것으로 판명됐다 — "PROVEN"이었던 이전 판정을 superseded로 정정한다.** 되돌리지는 않는다(유효한 방어 코드이므로).

**중요 정정(FACT, 이번 로그로 배제된 가설)**: `rxFrames`/`rxCallbacks`가 계속 증가했다는 사실 자체가 Swift dBFS 변환/SwiftUI 바인딩은 근본원인에서 배제됨을 증명한다 — `JarvisPCMRuntimeReadMetrics`는 C 런타임에 실제로 존재하는 0 값을 정확히 그대로 노출하고 있을 뿐이다. 실패 경계는 `JarvisPCMCaptureIOProc`의 샘플 수집/`RecordRX` 호출 지점 **이전 또는 그 내부**로 좁혀진다.

### §4 증거 갭 — cross-call 추론 금지

이전 라운드의 `pcm-inspect` 실측(Capture OUTPUT nonZeroCallbacks=3493/peak=0.166, Capture INPUT nonZeroCallbacks=1565/peak=0.211)은 **그 통화에 한해서만** 유효한 FACT다. 이번 RX-zero 재현이 발생한 통화에서는 같은 통화 중 `pcm-inspect`를 실행하지 않았으므로, "드라이버 Capture INPUT이 이번에도 non-zero였을 것"이라는 추론은 **하지 않는다**. 다음 실기기 재테스트는 반드시 같은 통화 중에 드라이버 진단과 Bridge 진단을 동시에 수집해야 한다(§37-39).

### §7 로컬 SDK 계약 확인 (FACT, 헤더 원문)

`AudioHardware.h`의 `AudioHardwareIOProcStreamUsage`/`kAudioDevicePropertyIOProcStreamUsage` 문서:

> "If a stream is marked as not being used, the given IOProc will see a corresponding NULL buffer pointer in the AudioBufferList passed to its IO proc. ... when getting the value of the property, one must fill out the mIOProc field of the AudioHardwareIOProcStreamUsage with the address of the IOProc whose stream usage is to be retrieved."

구조체: `void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[1];`(flexible-array-member 관례 — 실제 스트림 개수만큼 뒤에 UInt32가 이어짐, 크기는 `AudioObjectGetPropertyDataSize`로 먼저 조회해야 함). 이 프로퍼티가 default로 어떻게 초기화되는지는 헤더에 명시돼 있지 않음(SDK-header-silent) — 추측하지 않고 그렇게 기록한다.

**중요한 불일치(정직하게 기록)**: 이 문서가 설명하는 유일한 실패 모드는 "스트림 비활성화 → IOProc이 **NULL 버퍼 포인터**를 본다"이다. 그런데 현재 코드의 `JarvisPCMCaptureIOProc`는 `mData == NULL || mDataByteSize == 0`일 때 `continue`(RecordRX 호출 안 함, `rxCallbacks`/`rxFrames` 증가 안 함)로 처리한다 — 즉 NULL 버퍼였다면 `rxCallbacks`/`rxFrames`가 애초에 증가하지 않았어야 한다. 하지만 실측 로그는 이 두 값이 명백히 계속 증가했다 — 이는 버퍼가 **non-NULL이고 mDataByteSize>0로 실제로 전달됐다(readable)**는 뜻이다. **따라서 SDK가 문서화한 "스트림 비활성화" 실패 모드는 관찰된 증상(유효하지만 항상 0인 콘텐츠)과 정확히 일치하지 않는다** — 이 점을 숨기지 않고 명시한다. 가능성은 두 가지로 좁혀진다: (a) 이번 통화 자체에서 드라이버 Capture INPUT도 실제로 0이었을 수 있다(§16 Case D — mute/게인/에코캔슬레이션 등 통화별 요인), 또는 (b) 아직 발견되지 않은 다른 레이어. 같은 통화 중 `pcm-inspect` 없이는 (a)와 (b)를 구분할 수 없다.

### §8/§102 현재 등록 시퀀스 (FACT, 코드 감사)

```
JarvisPCMRuntimeCreate()
  → resolve Capture/Inject deviceID
  → ASBD 검증(48kHz/Float32/2ch/interleaved)
  → AudioDeviceCreateIOProcID(captureID, JarvisPCMCaptureIOProc, ...)
  → [신규] IOProcStreamUsageReader.logSnapshot(capture, input/output scope) — read-only
  → AudioDeviceStart(captureID, ...)
  → (Inject도 동일 패턴)
```

이번 조사 이전에는 `kAudioDevicePropertyIOProcStreamUsage`를 어디서도 조회/설정하지 않았다 — CoreAudio의 암묵적 기본값에 전적으로 의존하고 있었다(코드 전체 grep으로 확인, 0건).

### §9/§103 `JarvisPCMCaptureIOProc`의 NULL/zero 처리 정확성 (FACT, 코드 감사 + 신규 테스트로 검증)

현재 구현은 이미 정확하다 — `mData==NULL`이거나 `mDataByteSize==0`일 때 반드시 `continue`하며, 두 조건 모두 만족(non-NULL && byteSize>0)해야만 `RecordRX`가 호출된다. 즉 **"mDataByteSize>0인데 mData==NULL이라서 프레임이 허위로 증가한다"는 우려(§27)는 코드상 발생할 수 없음**을 확인했다 — 새 테스트(`testCaptureIOProcNullDataWithNonZeroByteSizeProducesTruthfulDiagnosticsNoFabricatedSignal`)로 실측 검증. 여러 버퍼 중 하나가 NULL이어도 나머지 유효 버퍼의 신호는 정확히 감지된다(`testCaptureIOProcMultipleBuffersOneNullOneNonZeroStillDetectsSignal`).

### §10-12 새 RT-safe 입력 형태 진단 (JarvisPCMRuntimeContext/JarvisPCMMetricsSnapshot)

```
rxIOProcInvocations           콜백이 호출된 횟수(무조건, inInputData 무관)
rxNullInputListCallbacks      inInputData 자체가 NULL이었던 횟수
rxZeroBufferCountCallbacks    inInputData는 non-NULL이나 mNumberBuffers==0이었던 횟수
rxInputBufferCountLast        가장 최근 non-NULL inInputData의 mNumberBuffers
rxNullDataBufferCount         mData==NULL인 개별 AudioBuffer 누적 개수
rxReadableDataBufferCount     mData!=NULL && mDataByteSize>0인(읽을 수 있는) 개별 버퍼 누적 개수
rxReadableNonZeroBufferCount  그중 peak>0이었던 개별 버퍼 누적 개수
```

콜백-로컬 스택 누적 후 콜백당 소수의 relaxed 원자 연산만 발행 — 샘플당 원자 연산 없음, 로깅/할당/락 없음(기존 RX 계산과 동일한 패턴). Raw PCM 보존 없음, 집계값만.

### §13 새 read-only `[CALL-PCM-STREAM-USAGE]` 진단

`Sources/JarvisCallBridge/System/CallAudioIOProcStreamUsageDiagnostics.swift` 신설. `IOProcStreamUsageReader.query`가 `kAudioDevicePropertyIOProcStreamUsage`를 실제 라이브 `AudioDeviceIOProcID`(`mIOProc` 필드에 채워 넣음, SDK 문서 요구사항대로)를 사용해 조회 — **`AudioObjectSetPropertyData`는 이 파일 어디에서도 호출하지 않는다(read-only, 코드 확인).** `SystemCallAudioPCMController.start()`에서 `AudioDeviceCreateIOProcID` **직후, `AudioDeviceStart` 이전**(§13/§18의 정확한 순서 요구사항)에 Capture(Input+Output scope)/Inject(Output+Input scope) 각각 호출, `[CALL-PCM-STREAM-USAGE] role=... scope=... streamCount=... enabled=[...]`로 로깅. 조회 실패는 진단 전용으로 처리되며 PCM 시작을 절대 막지 않는다(관찰이지 게이트가 아님).

§14의 지시대로 `JarvisAudioDriverTool`(별도 프로세스)에서는 이 진단을 시도하지 않았다 — 살아있는 IOProcID는 Bridge 프로세스 내부에만 존재하므로, 잘못된 IOProcID로 오도하는 CLI를 만들지 않았다.

`[CALL-PCM-METRICS]`도 위 신규 필드 전부를 포함하도록 확장했다(`ioProcInvocations`/`inputListNullCallbacks`/`inputZeroBufferCountCallbacks`/`inputBufferCountLast`/`inputNullDataBufferCount`/`readableDataBufferCount`/`readableNonZeroBufferCount`), 기존 ~1Hz 스로틀링·raw PCM 미보존 정책 그대로.

### §17 Stream-usage 수정 여부: NOT PROVEN — 수정하지 않음

§7에서 기록한 대로 SDK가 문서화한 유일한 실패 모드("NULL 버퍼")는 관찰된 증상(readable하지만 항상 0인 버퍼)과 정확히 일치하지 않는다. 같은 통화 중 드라이버·Bridge 진단 상관관계 없이 `kAudioDevicePropertyIOProcStreamUsage`를 `AudioObjectSetPropertyData`로 변경하는 것은 **증거 없는 추측성 수정**이 되므로 적용하지 않았다. 이번 세션은 read-only 진단만 추가했다 — §17-§20이 요구하는 "증명된 경우에만 최소 수정" 원칙을 그대로 따른 것이다.

### §21-§25 준수 확인

- **드라이버 미변경**: `AudioDriver/*` 이번 세션 파일 mtime 확인 결과 전혀 건드리지 않음(마지막 수정 시각이 이번 세션 시작 이전). **DRIVER MODIFIED = NO. DRIVER REINSTALL REQUIRED = NO.**
- **Route timing 미변경**: `CallAudioSessionController` 손대지 않음.
- **TX 아키텍처 미변경**: `JarvisPCMInjectIOProc` 로직 미변경(같은 파일의 `JarvisPCMCaptureIOProc`만 계측 추가). 기존 TX 테스트(`testInjectIOProc*`) 전부 그대로 PASS.
- **Teardown 미변경**: `stop()` 순서 그대로.
- **RT 아키텍처 보존**: 여전히 순수 C 네이티브 IOProc, Swift 콜백 없음, `NSLock`/`DispatchQueue` 동기화 추가 없음 — 전부 relaxed 원자 카운터.

### §26-28 신규 테스트

**콜백 형태 테스트**(`SystemCallAudioPCMControllerComputationTests.swift`, 실제 프로덕션 `JarvisPCMCaptureIOProc` 사용): `inInputData==NULL`(크래시 없음, `rxNullInputListCallbacks`만 증가), `mNumberBuffers==0`(`rxZeroBufferCountCallbacks` 증가), `mData==NULL && mDataByteSize>0`(허위 신호 없음, `rxNullDataBufferCount`만 증가), readable all-zero(`rxReadableDataBufferCount` 증가, `rxReadableNonZeroBufferCount`는 0 유지), readable non-zero(둘 다 증가), 다중 버퍼 중 하나만 NULL(나머지 신호 정확히 감지) — 6개.

**Stream-usage 파서 테스트**(`IOProcStreamUsageDiagnosticsTests.swift`, `IOProcStreamUsageReader.parse`를 실제 CoreAudio 없이 순수 바이트 버퍼로 검증 — §28의 "mocks/fakes, 실제 디바이스 라우트 변경 금지" 요구사항 그대로): 전부 활성화, 전부 비활성화, 혼합, 1이 아닌 non-zero 값도 활성화로 처리, 0개 스트림, 1개 스트림(실제 Jarvis 드라이버의 일반적 케이스), 헤더보다 짧은 버퍼(nil), 선언된 스트림 수보다 실제 바이트가 부족한 경우(nil), 빈 버퍼(nil), 다른 포인터 크기 처리 — 10개.

`query()`(실제 `AudioObjectGetPropertyData` 호출부)는 실제 디바이스/라이브 IOProcID가 필요하므로 자동화 테스트에서 직접 실행하지 않음 — 이 프로젝트의 기존 관례(`CoreAudioHelpers`류 코드는 selftest/실기기로만 검증)와 동일.

전체: **287/287 passed**(기존 271 + 신규 16), 0 failures, 기준 축소 없음.

### Build

- `rm -rf .build && swift build --build-tests`: **PASS, 경고 0**
- `swift test`: **PASS, 287/287**
- `./Scripts/build-app.sh`: **PASS**
- `git status --porcelain admin/ api/ web/`: 비어 있음
- **DRIVER REINSTALL REQUIRED = NO** — 앱 번들만 재빌드하면 됨.

### No-Call 안전성

`testStartArmsWorkModeAndAutoAnswerByDefaultWithoutTouchingAudio` 재확인 — Work Mode ON, 통화 없음 상태에서 IOProc 생성/시작 0회이므로 `[CALL-PCM-STREAM-USAGE]`/`[CALL-PCM-METRICS]` 둘 다 전혀 발행되지 않음(둘 다 PCM 시작 시퀀스 내부에서만 호출됨). Stream-usage 로직은 검증된 라우트/PCM 라이프사이클에 도달하기 전에는 아무것도 활성화하지 않는다.

### §40 중요 — RX 수정이 성공해도 Phase 3 COMPLETE 아님

다음 실기기 RX 재검증이 통과하더라도, Phase 3 COMPLETE를 자동으로 선언하지 않는다. PRD가 요구하는 나머지 실기기 검증 게이트: RX-only(진행 중), TX-only(이미 PASS), **동시 RX/TX**(상대가 말하는 동안 TX 오디오 전송 — RX 지속·피드백/드롭아웃 없음 검증, 아직 미검증), **2차 연속 통화 재사용**(두 번째 통화가 이전 통화의 stale tone/메트릭 없이 깨끗하게 시작하는지, 아직 미검증), route restore(이미 반복 PASS), **비상/크래시/에러 복구**(예: Active 중 Work Mode OFF로 PCM이 route restore 전에 먼저 멈추는지 등, startup recovery 자동화 증거로 일부 보완되나 아직 실기기 미검증). 이 게이트들이 명시적으로 충족되기 전까지 Phase 4는 계속 BLOCKED다.

### 다음 실기기 재검증 — SAME-CALL 상관관계 필수

1. 앱 재빌드/재실행(드라이버 재설치 불필요). Work Mode ON, Auto Answer OFF.
2. 실제 셀룰러 착신 전화 1건, 수동 응답, Active+Routed+PCM Running 대기.
3. 상대방이 10초 이상 계속 말하게 함.
4. **같은 통화가 여전히 Active인 상태에서** `swift run JarvisAudioDriverTool pcm-inspect` 실행, 전체 출력 저장.
5. **같은 기간** Bridge 로그에서 `[CALL-PCM-STREAM-USAGE]`(IOProc 시작 시 1회, 통화 시작 시점)와 `[CALL-PCM-METRICS]`(계속) 라인 저장.
6. TX 톤은 이미 실기기 종단간 PASS이므로 재테스트 불필요(원하면 무방).
7. 상대방 종료, 최종 로그 저장.

**같은 통화의 결과를 나란히 놓고 판정**: 드라이버 Capture INPUT(nonZeroCallbacks/peak) vs Bridge `inputBufferCountLast`/`inputNullDataBufferCount`/`readableDataBufferCount`/`readableNonZeroBufferCount`/`rawMeanSquareLinear`/`rawPeakLinear`. 드라이버가 non-zero인데 Bridge가 NULL/미수신 버퍼만 본다면 stream-usage 문제(Case A) — 그때 비로소 최소 `Set` 수정을 고려한다. 드라이버 자체가 이번 통화에서도 0이라면(Case D) 드라이버를 건드리지 않고 증거를 보존한 채 재검토한다.

## CHECKPOINT 2 — pcm-inspect Rpcm 안정성 / AudioObjectID Churn 조사

### §1/§2/§3 같은 통화 실기기 FACT (재확인 — stream-usage 가설 기각)

Stream usage(직전 세션에서 추가한 read-only `[CALL-PCM-STREAM-USAGE]`)는 이번 통화에서 4개 모두 정상이었다: `capture/input enabled=[1]`, `capture/output enabled=[1]`, `inject/output enabled=[1]`, `inject/input enabled=[1]`. **따라서 `kAudioDevicePropertyIOProcStreamUsage`에 대한 `Set` 수정은 이번 세션에서도 적용하지 않는다** — 근거가 없다.

Bridge Capture 콜백 입력 형태 진단도 전부 정상: `inputListNullCallbacks=0`, `inputZeroBufferCountCallbacks=0`, `inputBufferCountLast=1`, `inputNullDataBufferCount=0`, `readableDataBufferCount`가 콜백마다 증가(대표값 `ioProcInvocations=1303`, `readableDataBufferCount=1303`) — 즉 **유효하고 읽을 수 있는 버퍼가 매번 전달됐다.** 하지만 `readableNonZeroBufferCount=0`, `rawMeanSquareLinear=0.0`, `rawPeakLinear=0.0`으로 여전히 무음이었다. 이 사실 자체가 NULL 입력 ABL/0개 버퍼/비활성 스트림으로 인한 NULL mData/Swift dBFS 변환/SwiftUI 바인딩을 전부 배제한다 — 재검토하지 않는다.

### §5 pcm-inspect Rpcm 읽기 실패 — OSStatus 디코드 (FACT, 로컬 SDK 원문 대조)

```
Inject:  OSStatus=2003332927 ('who?') = kAudioHardwareUnknownPropertyError
         (AudioHardwareBase.h에 실제로 정의된 표준 CoreAudio 상수 — "이 오브젝트에 이 프로퍼티가 없다")

Capture: OSStatus=1768911973 ('iote')
         로컬 SDK 헤더 전체(grep)에서 이 FourCC의 정의를 찾지 못함 — 상징적 이름 부여하지 않음,
         raw OSStatus + FourCC로만 기록한다.
```

### §9-§14 Rpcm 프로퍼티 계약 감사 (FACT, 코드 전량 재확인)

- **선언**: `kCustomPropertyInfo`에 `{ kJarvisDevicePropertyPCMDiagnostics, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone }` — 이미 실기기에서 검증된 `kJarvisDevicePropertyActive`(CFBooleanRef)와 정확히 같은 `CFPropertyList` 카테고리 선언 방식.
- **HasProperty**: `inAddress->mScope == kAudioObjectPropertyScopeGlobal`만 검사, 활성/비활성 상태와 무관 — Capture/Inject 동일 코드.
- **GetPropertyDataSize**: 항상 `sizeof(CFTypeRef)`(8바이트, 포인터 크기) — 실제 104바이트 구조체 내용이 아니라 CFTypeRef 핸들 크기다. `kJarvisDevicePropertyActive`와 동일한 패턴.
- **GetPropertyData**: atomic snapshot 로드(`atomic_load`) + `JarvisLoopbackBufferGetCounters`(순수 읽기) + 디바이스 전용 스크래치 `CFMutableDataRef pcmDiagnosticsData`에 `CFDataReplaceBytes`로 최신 스냅샷을 채운 뒤 그 CFTypeRef를 반환. **감사 결과 side effect 없음(FACT)**: `isActive`/`isHidden`/`ioClientCount`를 쓰지 않고(오직 읽기만), `JarvisLoopbackBufferReset`을 호출하지 않고, `PropertiesChanged`/`RequestDeviceConfigurationChange`를 호출하지 않는다. `pcmDiagnosticsData`의 바이트 갱신은 진단 스냅샷 캐시 자체일 뿐 오디오 관련 드라이버 상태가 아니다.
- **CLI 디코딩**(`CoreAudioHelpers.getPCMDiagnostics`): scope/element/qualifier(0/nil)/버퍼 크기(`sizeof(Unmanaged<CFData>?)`=8) 전부 `getBoolProperty`(이미 실기기 검증됨)와 구조적으로 동일. 코드 감사로는 마샬링 계약 위반을 찾지 못했다.

**중요한 관찰(FACT)**: Capture와 Inject가 서로 다른 에러('iote' vs 'who?')를 반환했다. Rpcm 디스패치 코드는 두 디바이스에 대해 완전히 동일하다(같은 함수, `inObjectID`만 다름) — **코드 자체에 결함이 있다면 두 디바이스가 동일한 에러를 반환해야 한다.** 서로 다른 에러가 나온 것은 코드 레벨 버그보다 디바이스별 순간적 상태 차이(둘 중 하나가 이미 비활성화/전환 중이었을 가능성 등)를 더 강하게 시사한다 — 이 역시 INFERENCE이며 FACT로 확정하지 않는다.

**이번 in-process selftest 확장 결과(FACT)**: `GetPropertyDataSize` 정확한 계약(`==sizeof(CFTypeRef)`), undersized 버퍼 거부(`kAudioHardwareBadPropertySizeError`), 20회 연속 읽기가 byte-identical(부작용 없음), 연속 읽기가 `IsHidden`을 절대 바꾸지 않음 — Capture/Inject 둘 다 **0 failures**. 즉 **드라이버의 Rpcm 디스패치 로직 자체는 in-process 검증 범위에서 완전히 정상이다.**

### §16-§18 진단 스테일니스 정정 — CLI가 AudioDeviceID를 단계 간 재사용하고 있었다 (FACT, 코드 결함 확인 및 수정)

`pcm-inspect`의 기존 `printPCM`은 `deviceID`를 함수 시작 시 **한 번만** resolve한 뒤 `active` 읽기와 PCM diagnostics 읽기 두 단계 모두에 **재사용**하고 있었다 — §18이 명시적으로 지적한 정확한 안티패턴. 또한 `active` 읽기는 `try?`로 실패를 조용히 삼켜 아무 것도 출력하지 않았다(성공/실패 여부를 알 수 없었음). **이 두 결함은 이번 세션에서 수정했다** — 근본원인이라는 증거는 없지만, §18의 명시적 요구사항이자 그 자체로 정당한 진단 정확성 결함이었다.

### §31/§32 Route Ownership Loss 감사 (FACT, 코드 확인 — 기존 설계가 이미 올바름)

`CallAudioSessionController.hasLostRouteOwnership`(이번에 `lostRouteOwnershipSnapshot`으로 개명, 로직 동일)은 `current.outputUID != JarvisAudioDeviceUIDs.capture || current.inputUID != JarvisAudioDeviceUIDs.inject` — **UID 문자열 비교이며 AudioObjectID를 전혀 사용하지 않는다.** §32가 요구한 대로 이미 올바르게 설계돼 있었다 — 수정 불필요, 코드 변경 없이 검증만 기록한다. 다만 진단 로그가 빈약했던 것은 사실이라 `[CALL-AUDIO] route-ownership-lost`에 `expectedInputUID`/`observedInputUID`/`expectedOutputUID`/`observedOutputUID` 필드를 추가했다(§31) — 원시 AudioObjectID는 포함하지 않았다: `CallAudioRouteSnapshot` 자체가 설계상 UID만 담고(§32의 "UID 기반 정체성" 아키텍처와 정확히 같은 이유), UID 불일치만으로 왜 ownership이 상실됐는지 완전히 설명되기 때문이다.

### §33/§34 "Input=Unknown Output=Unknown" 원인 (FACT, 코드 확인)

`pcm-inspect`가 사용하던 `CoreAudioHelpers.currentRoute()`는 기본 디바이스 ID 조회 실패든 UID/이름 조회 실패든 디바이스가 아예 없든 **모든 실패 모드를 문자열 "Unknown"으로 뭉뚱그린다** — 다른 명령(`status`/`stress`/`loopbackTest`)에서는 before/after 동등성 비교에만 쓰이므로 문제 없지만, `pcm-inspect`의 진단 목적에는 부족했다. `currentRoute()` 자체는(다른 명령들이 계속 의존하므로) 변경하지 않고, `pcm-inspect` 전용으로 더 상세한 `printRouteIdentity()`를 새로 추가했다 — 항상 숫자 `defaultDeviceID`를 보여주고, `uidReadStatus`/`nameReadStatus`를 명시적으로 `ok`/`failed`로 구분한다. §34가 우려한 "숨겨진 디바이스가 일반 열거에서 빠져서 Unknown이 되는" 경우도 아니다 — 이 헬퍼는 애초에 `kAudioHardwarePropertyDevices` 열거를 전혀 사용하지 않고 `kAudioHardwarePropertyDefault{Input,Output}Device`로 직접 조회한다.

### §17-§20 CLI 강화 (구현 완료)

`Sources/JarvisAudioDriverTool/Commands.swift`의 `pcmInspect()`를 재작성:
- **PRE/POST identity**: Capture/Inject 각각 Rpcm 읽기 "전"과 "후"에 `requestedUID`/`resolvedID`/`readBackUID`를 출력. `active` 읽기와 PCM diagnostics 읽기 **각 단계 직전에 UID를 새로 resolve**(캐시하지 않음) — 두 resolve 결과가 다르면 `AUDIO_OBJECT_ID_CHANGED: resolvedID changed X -> Y`를 명시적으로 로그(§18 — "device missing"으로 오인하지 않음).
- **route identity before/after**: `printRouteIdentity()`를 Rpcm 읽기 전/후 각각 호출 — Default Input/Output/System Output의 `defaultDeviceID`/`uidReadStatus`/`uid`/`nameReadStatus`/`name`을 전부 출력.
- **완전 read-only 유지**: `AudioObjectSetPropertyData`/`AudioDeviceStart`/`AudioDeviceStop`/`AudioDeviceCreateIOProcID`/`AudioDeviceDestroyIOProcID` 호출 0건(코드 확인) — §20 요구사항 그대로.

### §21/§24/§44 새 read-only idle 안정성 하네스

`swift run JarvisAudioDriverTool pcm-inspect-stability [iterations]`(기본 50회) 신설 — Jarvis 디바이스가 idle/inactive인 동안 실행하도록 설계됨. 매 iteration마다 Capture/Inject 각각: UID→ID resolve, ID 변경 감지(`AUDIO_OBJECT_ID_CHANGED`), UID readback 불일치 감지(`UID_READBACK_MISMATCH`), Rpcm 읽기 시도 — 실패를 조용히 재시도하지 않고 전부 카운트해 마지막에 보고. 시작/종료 시점의 `currentRoute()`를 비교해 라우트 불변도 함께 검증. 오직 resolve/read만 수행 — `AudioObjectSetPropertyData`/`AudioDeviceStart`/`AudioDeviceCreateIOProcID` 등 전무.

### §26-§29 selftest/CLI 계약 테스트 강화

- `AudioDriver/Plugin/selftest.c`의 `CheckPCMDiagnostics`에 추가: `GetPropertyDataSize` 정확한 값 검증, undersized `GetPropertyData` 거부 검증, 20회 연속 읽기 byte-identical(부작용 없음) 검증, 연속 읽기가 `IsHidden`을 바꾸지 않는지 검증 — Capture/Inject 둘 다 **0 failures**.
- 새 `CoreAudioHelpers.decodePCMDiagnostics(from:)`(순수 함수, `getPCMDiagnostics`가 유일하게 호출)로 §27의 "두 개의 애매한 디코딩 경로를 두지 말 것"을 만족 — 버전 필드 검증 포함(§28: 버전 불일치 시 나머지 바이트를 절대 재해석하지 않고 `nil` 반환). 새 테스트 타겟 `JarvisAudioDriverToolTests`(`Tests/JarvisAudioDriverToolTests/PCMDiagnosticsDecodingTests.swift`) 신설, 실제 CoreAudio 없이 합성 `Data`로 검증: 정상 페이로드 정확히 디코드(실제 통화에서 관측된 0.16633263/0.21116002 값 포함), 짧은 데이터→nil, 빈 데이터→nil, 버전 불일치(2, 0)→nil, 트레일링 바이트가 있어도(향후 드라이버 확장 대비) 알려진 필드는 정상 디코드, 전부-0 버퍼(version=0 포함)→nil.
- `CallAudioSessionControllerTests.swift`에 2개 추가: ownership-loss 로그 라인에 expected/observed UID가 정확히 포함되는지, 동일 UID가 반복 관측돼도 절대 ownership loss로 취급되지 않는지.

전체: **295/295 passed**(287 + 6 디코딩 + 2 ownership), 0 failures, 기준 축소 없음.

### §7/§8 AudioObjectID Churn — HYPOTHESIS, NOT PROVEN

"pcm-inspect가 드라이버 재생성/AudioObjectID 교체를 유발했다"는 **증명되지 않았다.** 코드 감사로 확인한 FACT들(Rpcm GetPropertyData는 side-effect-free, 디스패치 로직은 in-process 전수 검증 통과, Capture/Inject가 서로 다른 에러를 반환한 것은 균일한 코드 버그와 불일치)은 오히려 **인과관계가 반대일 가능성**(다른 어떤 이벤트가 ownership loss/ID 교체를 먼저 유발했고, pcm-inspect는 이미 전환 중이던 상태를 관찰했을 뿐)을 더 강하게 뒷받침하지만, 이 역시 실기기 재현으로 아직 증명되지 않았다. 이번에 추가한 PRE/POST identity 로그와 idle 안정성 하네스가 다음 실행에서 이를 FACT로 확정하거나 반증할 것이다.

### §37 드라이버 재설치 정책

`AudioDriver/Plugin/PlugInInterface.c`/`PlugInTypes.h`/`AudioDriver/Shared/*`(실제 설치되는 `.driver` 번들 구성 파일) — 이번 세션 파일 mtime 확인 결과 **전혀 수정하지 않음**(직전 세션 이후 변경 없음). `AudioDriver/Plugin/selftest.c`는 수정했지만 이 파일은 `.driver` 번들에 링크되지 않는 별도 검증 실행파일이다(`build-driver.sh` 확인: 번들은 `JarvisLoopbackBuffer.o PlugInEntry.o PlugInInterface.o`만 링크). **DRIVER MODIFIED = NO. DRIVER REINSTALL REQUIRED = NO** (이번 세션 기준 — 이전 세션에서 이미 대기 중이던 재설치 요구가 있었다면 그것은 이 세션이 새로 만든 것이 아니다).

### Build

- `rm -rf .build && swift build --build-tests`: **PASS, 경고 0**
- `swift test`: **PASS, 295/295**
- `./Scripts/build-app.sh`: **PASS**
- `./Scripts/build-driver.sh` + selftest: **0 failures**(selftest.c 변경으로 재빌드했으나 설치는 하지 않음)
- `git status --porcelain admin/ api/ web/`: 비어 있음

### No-Call 안전성

재확인 — Work Mode ON, 통화 없음 상태에서 새 진단은 전혀 관여하지 않는다: `[CALL-PCM-STREAM-USAGE]`/`[CALL-PCM-METRICS]`는 PCM 시작 시퀀스 내부에서만, `pcm-inspect`/`pcm-inspect-stability`는 별도 CLI 프로세스로 앱 자동 실행 경로와 무관하다.

### 다음 단계 — 실기기 재통화 전 필수 순서

1. **먼저(실기기 통화 없이) idle 안정성 확인**: `swift run JarvisAudioDriverTool pcm-inspect-stability 50`을 Work Mode ON·통화 없음 상태에서 실행 — RESULT: PASS(idChanges=0, uidReadbackMismatches=0, rpcmFailures=0, route unchanged)를 확인할 것. 이 단계가 통과할 때까지 실기기 통화 재테스트로 넘어가지 않는다.
2. PASS 확인 후에만 실제 셀룰러 통화 1건 진행 — Active+Routed+PCM Running 대기, 상대방이 계속 말하게 함.
3. **같은 통화 중** `swift run JarvisAudioDriverTool pcm-inspect` 실행 — 이번에는 PRE/POST identity와 route identity가 함께 출력된다. `AUDIO_OBJECT_ID_CHANGED`가 나타나는지, Rpcm 읽기가 이번에는 성공하는지 확인.
4. Bridge 로그(`[CALL-AUDIO] route-ownership-lost`가 있다면 이제 expected/observed UID 포함) 함께 저장.

### 현재 게이트 상태 (갱신)

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **BLOCKED — Rpcm 읽기 실패/AudioObjectID churn 근본원인 미확정. 진단 안정성 하네스 및 강화된 identity 로그 준비 완료 — idle 안정성 확인 후에만 실기기 재통화 재개**
- **Phase 4**: **BLOCKED**

에이전트는 실제 전화를 걸지 않았고, HAL 드라이버를 설치/재설치하지 않았고, route timing을 변경하지 않았고, IOProc stream usage를 변경하지 않았고, RX 신호 처리 코드를 변경하지 않았고, TX를 재검토하지 않았고, teardown 순서를 변경하지 않았고, Realtime/STT/TTS/녹음을 구현하지 않았고, Phase 4로 진행하지 않았다.

## CHECKPOINT 2 — Rpcm 실제 CoreAudio 반복 읽기 실패 / CFPropertyList 소유권 조사

### §1/§2 새로운 결정적 idle 실기기 FACT — AudioObjectID churn 가설 약화

idle 상태에서 단발 `pcm-inspect`는 성공(Capture/Inject 모두 `active=false`, 모든 카운터 0, PRE/POST resolvedID 동일)했지만, 곧이어 같은 idle 상태에서 실행한 `pcm-inspect-stability 50`은:

```
iterations=50  idChanges=0  uidReadbackMismatches=0  rpcmFailures=100  route unchanged=true
RESULT: FAIL

capture#1: 1768911973 ('iote')
inject#1:  2003332927 ('who?')
capture#2..50, inject#2..50: 전부 'who?'
```

**100번의 시도 중 ID 변경 0회, UID 불일치 0회, 라우트 변경 0회였음에도 Rpcm 읽기는 100번 모두 실패했다.** 즉 Rpcm 실패는 AudioObjectID churn 없이도 독립적으로 재현된다 — 이전 라운드의 "Rpcm 실패가 AudioObjectID churn을 유발했다/필요로 한다"는 가설은 **약화됨(재현에 불필요함)**으로 정정한다. 이번 세션은 AudioObjectID churn을 주요 목표로 삼지 않았다(identity 진단 코드는 유지).

### §5-§7 근본원인 — CFPropertyList 소유권 계약 불일치 (STRONG HYPOTHESIS, 텍스트 근거 + 구조적 근거로 뒷받침, 100% 확정은 불가능)

**로컬 SDK 대조 결과(FACT)**: `AudioServerPlugIn.h`의 `Driver_GetPropertyData`/`AudioObjectGetPropertyData` 문서 어디에도 CFTypeRef 반환값의 소유권을 명시하지 않는다("The buffer into which ... will be put"만 서술). 하지만 같은 헤더의 `CopyFromStorage`(CFPropertyList를 다루는 유일한 다른 API)는 명시적으로 **"The caller is responsible for releasing the returned CFObject."**라고 문서화돼 있다 — Apple의 "Copy"/"Create" 네이밍 컨벤션과 일치하는 +1 소유권 계약.

**드라이버 내 기존 CF 반환 프로퍼티 전수 감사(FACT)**: `kJarvisDevicePropertyActive`/`kJarvisDevicePropertyClearBuffers`는 `kCFBooleanTrue`/`kCFBooleanFalse`(Apple 제공 컴파일타임 싱글턴, over-release에 면역), `DeviceUID`/`DeviceName`은 `CFSTR(...)` 컴파일타임 상수 문자열(마찬가지로 면역) — **이 드라이버가 지금까지 반환한 모든 CFTypeRef는 예외 없이 "release해도 절대 죽지 않는" 불멸 객체였다.** Rpcm의 `pcmDiagnosticsData`(`CFDataCreateMutable`로 힙에 생성, `Driver_Initialize`에서 단 한 번 생성해 이후 매 호출마다 추가 `CFRetain` 없이 그대로 반환)는 **이 드라이버가 만든 최초의 진짜(mortal) 힙 CF 객체**다.

**결론(STRONG HYPOTHESIS)**: 만약 실제 코어오디오(coreaudiod)가 이 프로퍼티 경계를 넘는 CFPropertyList 반환값을 `CopyFromStorage`와 동일한 "+1 소유, 호스트가 release" 계약으로 취급한다면 — 첫 읽기: `pcmDiagnosticsData`(retain count 1)를 반환 → coreaudiod가 사용 후 CFRelease → retain count 0 → **객체 해제**. 두 번째 읽기부터: 이미 해제된 포인터에 `CFDataReplaceBytes`를 시도 → undefined behavior → 정확히 관찰된 패턴(첫 실패는 알 수 없는 OSStatus 'iote', 이후 지속적으로 'who?')과 일치한다. Active/ClearBuffers/DeviceUID가 계속 정상 동작해온 것은 이 버그가 없어서가 아니라 **불멸 객체라 증상이 나타날 수 없었기 때문**이라는 설명과도 정확히 맞아떨어진다. **100% 확정은 불가능하다**(coreaudiod 내부 구현은 Apple 소스 없이 직접 확인 불가) — 하지만 사용 가능한 모든 텍스트적·구조적 증거가 일관되게 이 가설을 가리킨다.

### §8/§12/§13 selftest 강화로 실제 계약 모델링

- `ReadPCMDiagnostics` 헬퍼가 이제 반환된 객체의 타입을 검증(`CFGetTypeID == CFDataGetTypeID`)하고 디코딩 후 **항상 `CFRelease`**한다 — "caller releases" 계약을 실제로 모델링.
- 새 100회 반복 테스트: `HasProperty → GetPropertyDataSize → GetPropertyData → decode → release → HasProperty` 전체 사이클을 100번 반복, 매번 성공해야 함 — Capture/Inject 각각 **PASS**.
- 새 동시성 스트레스 테스트: 순수 C `pthread`(Clang block이 아님 — block을 함수 포인터로 캐스팅하는 것은 ABI상 안전하지 않으므로 명시적으로 피함) 두 스레드가 동일 디바이스에 대해 각각 200회 동시 읽기 — 크래시/손상 없이 Capture 400/400, Inject 400/400 성공.
- 이 모든 강화된 selftest는 **수정 전 코드로 실행하지 않았다**(같은 세션에서 수정과 검증을 함께 적용) — §31이 요구한 "selftest PASS만으로 고쳤다고 주장하지 말 것"의 정신에 따라, 최종 검증은 실제 설치된 드라이버에 대한 실기기 idle 재테스트로만 완료된다는 점을 명시한다.

### §21/§22 적용한 최소 수정 (DRIVER MODIFIED = YES)

`AudioDriver/Plugin/PlugInInterface.c`의 `Driver_GetPropertyData`(Rpcm 케이스)를 재작성: 매 호출마다 스냅샷을 스택에 구성한 뒤 `CFDataCreate(kCFAllocatorDefault, ...)`로 **새로운 불변(immutable) CFDataRef를 생성해 반환**(+1 소유) — 더 이상 공유된 mutable `CFMutableDataRef`를 유지·재사용하지 않는다. `PlugInTypes.h`에서 이제 불필요해진 `pcmDiagnosticsData` 필드와 `Driver_Initialize`의 관련 할당 코드를 제거했다.

이 설계를 선택한 이유(§10/§21):
- 계약이 "+1 소유, 호출자가 release"라면 — 정확히 맞다.
- 계약이 그게 아니라면(호스트가 절대 release하지 않는다면) — 매 호출 104바이트 할당은 완전히 통제-평면(control-plane) 전용, RT 콜백에 절대 도달하지 않는 경로(§27)에서 발생하는 미미하고 유계(bounded)인 비용일 뿐이다.
- 어느 쪽이든 안전하다 — 그리고 §11이 우려한 "공유 mutable scratch에 대한 동시 읽기 경합"도 구조적으로 제거된다(각 호출이 자신만의 독립된 객체를 받음).

`Driver_DoIOOperation`(WriteMix/ReadInput)/`JarvisPCMCaptureIOProc`/`JarvisPCMInjectIOProc` 등 실시간 콜백 경로는 전혀 손대지 않았다 — 할당은 오직 `Driver_GetPropertyData`(제어 평면)에만 있다.

### §14/§20/§30 CLI 진단 강화

- **stage 분리**: `CoreAudioHelpers.readPCMDiagnosticsStaged(_:)` 신설 — `HasProperty`(before) → `GetPropertyDataSize` → `GetPropertyData` → decode → `HasProperty`(after) 각 단계 결과를 개별 필드로 반환. `getPCMDiagnostics`(throwing 편의 래퍼)와 `pcm-inspect`/`pcm-inspect-stability` 전부 이 **하나의 정식(canonical) 구현**을 통해서만 Rpcm을 읽는다(§15 — 두 번째의, 미묘하게 다른 프로퍼티 읽기 구현이 존재하지 않음을 코드로 재확인).
- **`pcm-inspect-stability`가 실패 시 정확히 어느 단계가 깨졌는지 출력**: `hasBefore`/`sizeStatus`/`size`/`dataStatus`/`hasAfter`를 실패한 iteration에서만 출력(성공은 조용히 넘어감 — 수백 회 반복에서 스팸 방지).
- **FourCC 포매터**: `CoreAudioHelpers.formatOSStatus`를 신설해 모든 OSStatus 출력에 일괄 적용 — 4바이트가 전부 출력 가능한 ASCII일 때만 FourCC를 덧붙이고, 그렇지 않으면 10진수만 표시. 상징적 이름을 임의로 붙이지 않는다(`'iote'`처럼 SDK에 정의되지 않은 값도 FourCC 형태로는 보여주되 이름을 지어내지 않음).
- **stale `ioClientCount` 해석 문구 교체**: 이전 문구("이게 1을 넘지 않으면 다른 프로세스가 IO를 시작하지 않은 것")를 삭제 — 이전 라운드의 실기기 증거(`ioClientCount=1`이면서 동시에 `outputNonZeroCallbacks=3493`)가 이를 직접 반증했다. 이제 "보조 텔레메트리일 뿐, 실제 신호 증거는 `outputNonZeroCallbacks`/`outputPeakLinear`" 문구로 교체.

### §29 새 Swift 테스트

`Tests/JarvisAudioDriverToolTests/`에 2개 파일 추가: `PCMDiagnosticsDecodingTests`(기존, 유지)와 신규 `PCMDiagnosticsStageTests` — `formatOSStatus`(알려진 상수 'who?', SDK 미정의값 'iote'도 FourCC로 표시, 출력 불가능 바이트는 10진수만, 음수 OSStatus 처리) 4개, `PCMDiagnosticsStageResult.succeeded`의 단계별 조합 로직(모든 단계 통과/`hasPropertyBefore` 실패/`sizeStatus` 실패/`dataStatus` 실패=정확히 이번 실패 패턴/상태는 OK인데 디코딩만 실패/`hasPropertyAfter` 실패) 6개 — 전부 순수 로직, 실제 CoreAudio 없이 검증. 실제 CoreAudio를 호출하는 `readPCMDiagnosticsStaged` 자체는(이 프로젝트의 기존 관례대로) 유닛 테스트하지 않음 — 실기기로만 검증.

전체: **305/305 passed**(295 + 10), 0 failures, 기준 축소 없음.

### §26 드라이버 selftest 결과

`AudioDriver/Plugin/selftest.c` 재빌드 — Capture/Inject 둘 다 **0 failures**, 신규 케이스 전부 PASS: undersized 버퍼 거부, `GetPropertyDataSize` 정확한 계약, 20회 무변경 반복 읽기 byte-identical, **100회 realistic HasProperty→GetSize→GetData→release→HasProperty 사이클 전부 성공**, **동시 200×2 스레드 읽기 크래시/손상 없이 전부 성공**.

### §37 드라이버 재설치 정책 — 이번에는 실제로 필요함

`AudioDriver/Plugin/PlugInInterface.c`와 `PlugInTypes.h`(실제 설치되는 `.driver` 번들 구성 파일)를 이번 세션에서 **직접 수정했다**(파일 mtime으로 확인). **DRIVER MODIFIED = YES. DRIVER REINSTALL REQUIRED = YES.** 에이전트는 설치/재설치를 실행하지 않았다 — 사용자가 직접:

```bash
cd bridge
./Scripts/uninstall-driver.sh
./Scripts/install-driver.sh
```

### Build

- `rm -rf .build && swift build --build-tests`: **PASS, 경고 0**
- `swift test`: **PASS, 305/305**
- `./Scripts/build-app.sh`: **PASS**
- `./Scripts/build-driver.sh` + selftest: **0 failures, 경고 0**
- `git status --porcelain admin/ api/ web/`: 비어 있음

### RT 안전성 재확인

`Driver_DoIOOperation`(WriteMix/ReadInput), `JarvisPCMCaptureIOProc`, `JarvisPCMInjectIOProc` — 전혀 수정하지 않음. 새로 추가된 `CFDataCreate` 할당은 오직 `Driver_GetPropertyData`(제어 평면, 진단 프로퍼티 읽기 전용)에만 있으며, 실시간 콜백에서는 절대 도달할 수 없는 코드 경로다.

### No-Call 안전성

재확인 — Work Mode ON, 통화 없음 상태에서 이번 세션 변경 사항(Rpcm 소유권 수정, CLI 강화)은 전혀 관여하지 않는다. 기존 회귀 테스트 그대로 통과.

### 다음 단계 — 드라이버 재설치 후 idle 재검증부터

1. **사용자가 직접** `./Scripts/uninstall-driver.sh` → `./Scripts/install-driver.sh` 실행.
2. idle 상태에서 `swift run JarvisAudioDriverTool pcm-inspect` — Rpcm 읽기 성공 확인.
3. idle 상태에서 `swift run JarvisAudioDriverTool pcm-inspect-stability 100` — **`rpcmFailures=0`, `RESULT: PASS`**를 확인할 것. 실패 시 이제 정확한 단계(`hasBefore`/`sizeStatus`/`dataStatus`/`hasAfter`)가 출력되므로 그 결과를 그대로 보존해 다음 세션에 전달.
4. 100회 idle 테스트가 PASS할 때까지 실기기 통화 재개하지 않는다. PASS 이후에만 다음 세션에서 same-call RX 상관관계 조사로 복귀한다.

### 현재 게이트 상태 (갱신)

- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **BLOCKED — REAL CORE AUDIO IDLE RETEST REQUIRED (드라이버 재설치 후)**
- **Phase 4**: **BLOCKED**

에이전트는 실제 전화를 걸지 않았고, HAL 드라이버를 직접 설치/재설치하지 않았고(사용자가 직접 수행해야 함), route timing을 변경하지 않았고, IOProc stream usage를 변경하지 않았고, RX 샘플 처리 코드를 변경하지 않았고, TX를 재검토하지 않았고, teardown 순서를 변경하지 않았고, Realtime/STT/TTS/녹음을 구현하지 않았고, Phase 4로 진행하지 않았다.
