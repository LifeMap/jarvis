# Phase 5 — 부재중 콜백 발신 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto Answer가 받을 수 있었던 착신을 놓치면, 스케줄러가 그 번호를 오래된 것부터 한 통씩 `tel:`로 다시 걸고, 연결되면 발신 인사·녹음 보고를, 안 되면 Jarvis `통화`에 고정 요약을 남긴다.

**Architecture:** 부재중 판정·큐·스케줄은 Bridge 순수 로직이다. 걸기는 `tel:` → Phone.app Continuity, 끊기는 기존 FACETIME_NOTIFICATION `종료` 1회다. 연결 안 됨은 `/api/calls` complete에 클라 고정 `summary`를 받아 LLM 없이 `status=failed`로 저장한다. 연결되면 기존 CP2 보고에 `direction=outgoing`만 더한다.

**Tech Stack:** Swift 6, SwiftUI, UserDefaults, `tel:` / NSWorkspace, Cloudflare Worker, vitest / XCTest.

**스펙:** `docs/superpowers/specs/2026-08-24-bridge-missed-callback-design.md`

**바꾸면 안 되는 것:** PCM/mute/barge-in, session.update VAD, 드라이버 수정·재설치, 키패드 AX, 단축어, 070/SIP, 재시도, 임의 번호 걸기, Phase 5 COMPLETE 선언.

작업 디렉터리: `/Volumes/Dev/workspaces/twms/jarvis`  
커밋은 사용자가 요청할 때만 한다.

## File map

| 파일 | 역할 |
|---|---|
| `api/src/calls/types.ts` | 허용 고정 summary |
| `api/src/index.ts` | complete body에서 summary 전달 |
| `api/src/personal-assistant-agent.ts` | 빈 전사 + 고정 summary → LLM 없이 `failed` |
| `api/test/calls.test.ts` | 고정 summary / LLM 미호출 |
| `bridge/.../Call/MissedCallCallbackDecision.swift` | 부재중 여부 순수 함수 |
| `bridge/.../Call/MissedCallCallbackStore.swift` | 큐 + 주기/타임아웃 UserDefaults |
| `bridge/.../Call/CallTelURL.swift` | `tel:` URL. 로그에 쓰지 않음 |
| `bridge/.../Call/CallURLOpening.swift` | NSWorkspace 열기 seam |
| `bridge/.../Call/IncomingEndCallControlMatcher.swift` | 배너 `종료` evidence-lock |
| `bridge/.../Call/EndCallCandidateResolver.swift` | high 1개일 때만 끊기 후보 |
| `bridge/.../Call/MissedCallCallbackController.swift` | idle 시 큐, 틱, 걸기, 대기, 끊기, 실패 보고 |
| `bridge/.../Call/CallLifecycleTracker.swift` | `lastOutcome`, idle에서 Active 증거 |
| `bridge/.../Call/IncomingCallObserver.swift` | idle 전이 때 콜백 컨트롤러에 알림 (resolver reset 전) |
| `bridge/.../Realtime/JarvisAPIClient.swift` | `direction` + optional `summary` |
| `bridge/.../Realtime/RealtimeCallInstructions.swift` | 발신 조합. 빈 인사는 수신 기본문을 넣지 않음 |
| `bridge/.../Realtime/OpenAIRealtimeVoiceSessionController.swift` | `reportDirection` |
| `bridge/.../App/BridgeViewModel.swift` | 배선 |
| `bridge/.../UI/ContentView.swift` | Auto Answer 아래 주기/초/큐 개수. 발신 인사 캡션 수정 |

## 구현 시 고정할 해석

스펙 3절 첫 줄은 `Active / Answering`을 같이 적었지만, 트래커는 상대가 끊어도 후보가 사라지면 `.answering`(grace)을 거친다. **받은 통화로 보는 것은 `.active`만**이다. grace만 보고 끝난 세션은 부재중 후보다.

발신 Continuity는 `응답`이 없을 수 있다. idle에서 Active 증거가 있으면 `.active`로 올린다. 발신 벨 UI가 처음부터 `종료+키패드`면 연결로 오인할 수 있다. 이 체크포인트는 스펙대로 `.active`를 쓴다. 실기기에서 벨만으로 Active가 되면 후속으로 나눈다.

---

### Task 1: complete가 고정 summary를 저장하고 LLM을 안 부른다

**Files:**
- Modify: `api/src/calls/types.ts`
- Modify: `api/src/index.ts`
- Modify: `api/src/personal-assistant-agent.ts`
- Test: `api/test/calls.test.ts`

- [ ] **Step 1: 실패하는 테스트를 추가한다**

`api/test/calls.test.ts`의 `call audio and complete` describe에 붙인다.

```ts
  it("stores an allowed client summary and stays failed when transcript is empty", async () => {
    const created = await createCall({ name: "unknown", phoneNumber: "+821011122233" }, "outgoing");
    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({
        endedAt: "2026-08-24T09:53:21.000Z",
        transcript: [],
        uploadFailed: true,
        summary: "콜백 연결 안 됨",
      }),
    })), testEnv);
    expect(complete.status).toBe(200);
    const body = await complete.json<{ status: string; summary: string | null; hasAudio: boolean }>();
    expect(body.status).toBe("failed");
    expect(body.summary).toBe("콜백 연결 안 됨");
    expect(body.hasAudio).toBe(false);
  });

  it("stores 번호 없음 the same way", async () => {
    const created = await createCall({ name: "unknown", phoneNumber: "unknown" }, "outgoing");
    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({
        endedAt: "2026-08-24T09:53:21.000Z",
        transcript: [],
        uploadFailed: true,
        summary: "번호 없음",
      }),
    })), testEnv);
    const body = await complete.json<{ status: string; summary: string | null }>();
    expect(body.status).toBe("failed");
    expect(body.summary).toBe("번호 없음");
  });

  it("ignores a client summary that is not one of the two fixed phrases", async () => {
    const created = await createCall();
    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({
        endedAt: "2026-08-24T09:53:21.000Z",
        transcript: [],
        summary: "알아서 요약해",
      }),
    })), testEnv);
    const body = await complete.json<{ status: string; summary: string | null }>();
    expect(body.summary).toBeNull();
    expect(body.status).toBe("upload_failed");
  });
```

기존 `does not invent a summary when transcript is empty`는 그대로 둔다.

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run:

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/api && npm test -- test/calls.test.ts
```

Expected: `stores an allowed client summary...` FAIL — `status`가 `upload_failed`, `summary`가 `null`.

- [ ] **Step 3: 최소 구현**

`api/src/calls/types.ts`에 추가:

```ts
export const FIXED_CALLBACK_SUMMARIES = ["콜백 연결 안 됨", "번호 없음"] as const;

export function normalizeFixedCallbackSummary(value: unknown): string | null {
  return value === "콜백 연결 안 됨" || value === "번호 없음" ? value : null;
}
```

`api/src/index.ts` complete 분기에서 `agent.completeCall`에 summary를 넘긴다:

```ts
import { normalizeFixedCallbackSummary, normalizeTranscript, ... } from "./calls/types";

    const result = await agent.completeCall(id, {
      endedAt,
      transcript,
      ...(body.uploadFailed === true ? { uploadFailed: true } : {}),
      ...(normalizeFixedCallbackSummary(body.summary) ? { summary: normalizeFixedCallbackSummary(body.summary)! } : {}),
    });
```

`normalizeFixedCallbackSummary`를 두 번 부르지 말고 지역 변수로 한 번만 쓴다.

`api/src/personal-assistant-agent.ts` `completeCall`:

```ts
  async completeCall(id: string, input: {
    endedAt: string;
    transcript: CallTranscriptTurn[];
    uploadFailed?: boolean;
    summary?: string;
  }) {
    const repository = new CallRepository(this);
    const current = repository.get(id);
    if (!current) return { ok: false as const, code: "NOT_FOUND" };
    if (current.status !== "active") return { ok: false as const, code: "CONFLICT" };
    const fixedSummary = input.transcript.length === 0 ? (input.summary ?? null) : null;
    const summary = fixedSummary ?? await summarizeCallTranscript(input.transcript, createModelProvider(this.env));
    const status = fixedSummary
      ? "failed"
      : current.hasAudio
        ? "completed"
        : input.uploadFailed
          ? "upload_failed"
          : input.transcript.length > 0
            ? "completed"
            : "upload_failed";
    const record = repository.complete(id, {
      endedAt: input.endedAt,
      transcript: input.transcript,
      summary,
      status,
    });
    return record ? { ok: true as const, call: callDetail(record) } : { ok: false as const, code: "NOT_FOUND" };
  }
```

`input.summary`는 라우트가 이미 허용 문구만 넘긴다. 전사가 있으면 클라 summary는 무시하고 기존처럼 LLM을 쓴다.

- [ ] **Step 4: 테스트를 통과시킨다**

Run: `cd /Volumes/Dev/workspaces/twms/jarvis/api && npm test -- test/calls.test.ts`  
Expected: PASS. 빈 전사 기존 케이스의 `summary`는 여전히 `null`.

---

### Task 2: 부재중 판정 + 큐 + 설정

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Call/MissedCallCallbackDecision.swift`
- Create: `bridge/Sources/JarvisCallBridge/Call/MissedCallCallbackStore.swift`
- Test: `bridge/Tests/JarvisCallBridgeTests/MissedCallCallbackDecisionTests.swift`
- Test: `bridge/Tests/JarvisCallBridgeTests/MissedCallCallbackStoreTests.swift`

- [ ] **Step 1: 실패하는 판정 테스트를 작성한다**

```swift
import XCTest
@testable import JarvisCallBridge

final class MissedCallCallbackDecisionTests: XCTestCase {
    private func input(
        workModeOn: Bool = true,
        autoAnswerOn: Bool = true,
        reachedActive: Bool = false,
        ringingDuration: TimeInterval = 5,
        delaySeconds: TimeInterval = 3,
        phoneNumber: String = "+821011122233"
    ) -> MissedCallCallbackInput {
        MissedCallCallbackInput(
            workModeOn: workModeOn,
            autoAnswerOn: autoAnswerOn,
            reachedActive: reachedActive,
            ringingDuration: ringingDuration,
            delaySeconds: delaySeconds,
            phoneNumber: phoneNumber
        )
    }

    func testShortRingDoesNotEnqueue() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(ringingDuration: 2, delaySeconds: 3)), .skip)
    }

    func testLongRingWithNumberEnqueues() {
        XCTAssertEqual(
            MissedCallCallbackDecision.evaluate(input(ringingDuration: 5, delaySeconds: 3)),
            .enqueue(phoneNumber: "+821011122233")
        )
    }

    func testUnknownPhoneReportsNoNumber() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(phoneNumber: "unknown")), .reportNoNumber)
    }

    func testAutoAnswerOffSkips() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(autoAnswerOn: false)), .skip)
    }

    func testWorkModeOffSkips() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(workModeOn: false)), .skip)
    }

    func testReachedActiveSkips() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(reachedActive: true)), .skip)
    }

    func testAnsweringGraceAloneDoesNotSkip() {
        XCTAssertEqual(
            MissedCallCallbackDecision.evaluate(input(reachedActive: false, ringingDuration: 5, delaySeconds: 3)),
            .enqueue(phoneNumber: "+821011122233")
        )
    }
}
```

- [ ] **Step 2: 판정 테스트가 실패하는지 확인한다**

Run:

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge && swift test --filter MissedCallCallbackDecisionTests
```

Expected: FAIL — `MissedCallCallbackDecision` 없음.

- [ ] **Step 3: 판정 타입을 구현한다**

`MissedCallCallbackDecision.swift`:

```swift
import Foundation

struct MissedCallCallbackInput: Equatable {
    var workModeOn: Bool
    var autoAnswerOn: Bool
    var reachedActive: Bool
    var ringingDuration: TimeInterval
    var delaySeconds: TimeInterval
    var phoneNumber: String
}

enum MissedCallCallbackDecision: Equatable {
    case enqueue(phoneNumber: String)
    case reportNoNumber
    case skip

    static func evaluate(_ input: MissedCallCallbackInput) -> MissedCallCallbackDecision {
        guard input.workModeOn, input.autoAnswerOn, !input.reachedActive else { return .skip }
        guard input.ringingDuration >= input.delaySeconds else { return .skip }
        if input.phoneNumber == "unknown" || input.phoneNumber.isEmpty { return .reportNoNumber }
        return .enqueue(phoneNumber: input.phoneNumber)
    }
}
```

- [ ] **Step 4: 판정 테스트를 통과시킨다**

Run: `swift test --filter MissedCallCallbackDecisionTests`  
Expected: PASS.

- [ ] **Step 5: 실패하는 큐/설정 테스트를 작성한다**

```swift
import XCTest
@testable import JarvisCallBridge

final class MissedCallCallbackStoreTests: XCTestCase {
    private func store() -> UserDefaultsMissedCallCallbackStore {
        let defaults = UserDefaults(suiteName: "test.callback.\(UUID().uuidString)")!
        return UserDefaultsMissedCallCallbackStore(defaults: defaults)
    }

    func testEnqueueDedupsByPhoneAndKeepsOldest() {
        let store = store()
        let first = Date(timeIntervalSince1970: 100)
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: first)
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date(timeIntervalSince1970: 200))
        store.enqueue(phoneNumber: "+821022222222", ringingStartedAt: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.peekOldest()?.phoneNumber, "+821011111111")
        XCTAssertEqual(store.peekOldest()?.ringingStartedAt, first)
    }

    func testPopOldestRemovesOne() {
        let store = store()
        store.enqueue(phoneNumber: "010-1111-1111", ringingStartedAt: Date(timeIntervalSince1970: 1))
        store.enqueue(phoneNumber: "010-2222-2222", ringingStartedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.popOldest()?.phoneNumber, "010-1111-1111")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.peekOldest()?.phoneNumber, "010-2222-2222")
    }

    func testSettingsClamp() {
        let store = store()
        XCTAssertEqual(store.intervalMinutes, 5)
        XCTAssertEqual(store.noAnswerSeconds, 45)
        store.intervalMinutes = 0
        store.noAnswerSeconds = 3
        XCTAssertEqual(store.intervalMinutes, 1)
        XCTAssertEqual(store.noAnswerSeconds, 15)
        store.intervalMinutes = 99
        store.noAnswerSeconds = 200
        XCTAssertEqual(store.intervalMinutes, 60)
        XCTAssertEqual(store.noAnswerSeconds, 120)
    }
}
```

- [ ] **Step 6: 큐 테스트가 실패하는지 확인한다**

Run: `swift test --filter MissedCallCallbackStoreTests`  
Expected: FAIL — store 없음.

- [ ] **Step 7: store를 구현한다**

`MissedCallCallbackStore.swift`:

```swift
import Foundation

struct MissedCallCallbackItem: Codable, Equatable {
    var phoneNumber: String
    var ringingStartedAt: Date
}

protocol MissedCallCallbackStoring: AnyObject {
    var intervalMinutes: Int { get set }
    var noAnswerSeconds: Int { get set }
    var count: Int { get }
    func enqueue(phoneNumber: String, ringingStartedAt: Date)
    func peekOldest() -> MissedCallCallbackItem?
    func popOldest() -> MissedCallCallbackItem?
}

final class UserDefaultsMissedCallCallbackStore: MissedCallCallbackStoring {
    static let queueKey = "jarvis.callback.queue"
    static let intervalKey = "jarvis.callback.intervalMinutes"
    static let noAnswerKey = "jarvis.callback.noAnswerSeconds"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var intervalMinutes: Int {
        get { clamped(defaults.object(forKey: Self.intervalKey) as? Int ?? 5, 1, 60) }
        set { defaults.set(clamped(newValue, 1, 60), forKey: Self.intervalKey) }
    }

    var noAnswerSeconds: Int {
        get { clamped(defaults.object(forKey: Self.noAnswerKey) as? Int ?? 45, 15, 120) }
        set { defaults.set(clamped(newValue, 15, 120), forKey: Self.noAnswerKey) }
    }

    var count: Int { items().count }

    func enqueue(phoneNumber: String, ringingStartedAt: Date) {
        var current = items()
        if current.contains(where: { $0.phoneNumber == phoneNumber }) { return }
        current.append(MissedCallCallbackItem(phoneNumber: phoneNumber, ringingStartedAt: ringingStartedAt))
        save(current)
    }

    func peekOldest() -> MissedCallCallbackItem? {
        items().min(by: { $0.ringingStartedAt < $1.ringingStartedAt })
    }

    func popOldest() -> MissedCallCallbackItem? {
        var current = items()
        guard let oldest = current.min(by: { $0.ringingStartedAt < $1.ringingStartedAt }) else { return nil }
        current.removeAll { $0.phoneNumber == oldest.phoneNumber && $0.ringingStartedAt == oldest.ringingStartedAt }
        save(current)
        return oldest
    }

    private func items() -> [MissedCallCallbackItem] {
        guard let data = defaults.data(forKey: Self.queueKey) else { return [] }
        return (try? JSONDecoder().decode([MissedCallCallbackItem].self, from: data)) ?? []
    }

    private func save(_ items: [MissedCallCallbackItem]) {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.queueKey)
    }

    private func clamped(_ value: Int, _ min: Int, _ max: Int) -> Int {
        Swift.min(max, Swift.max(min, value))
    }
}
```

- [ ] **Step 8: 큐 테스트를 통과시킨다**

Run: `swift test --filter 'MissedCallCallbackDecisionTests|MissedCallCallbackStoreTests'`  
Expected: PASS.

---

### Task 3: 세션 outcome + 발신 Active

**Files:**
- Modify: `bridge/Sources/JarvisCallBridge/Call/CallLifecycleTracker.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Call/CallLifecycleState.swift` (outcome 타입을 여기 두거나 tracker 파일에 둔다)
- Test: `bridge/Tests/JarvisCallBridgeTests/CallLifecycleTrackerTests.swift`

- [ ] **Step 1: 실패하는 테스트를 추가한다**

`CallLifecycleTrackerTests`에:

```swift
    func testFinishSessionRecordsOutcomeWithoutActive() {
        let clock = FakeClock()
        clock.now = Date(timeIntervalSince1970: 10)
        let tracker = CallLifecycleTracker(answerTransitionGrace: 0.1, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        clock.advance(5)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        clock.advance(0.2)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .idle)
        XCTAssertEqual(tracker.lastOutcome?.reachedActive, false)
        XCTAssertEqual(tracker.lastOutcome?.startedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(tracker.lastOutcome?.endedAt, Date(timeIntervalSince1970: 15.2), accuracy: 0.001)
    }

    func testFinishSessionRecordsReachedActive() {
        let tracker = CallLifecycleTracker(endDebounceInterval: 0.1, logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        // debounce를 쓰려면 clock이 필요하다. FakeClock 버전으로 작성한다.
    }

    func testIdleActiveEvidenceBecomesActive() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active)
        XCTAssertNotNil(tracker.currentSession)
    }

    func testResetDoesNotPublishMissedOutcome() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.reset()
        XCTAssertNil(tracker.lastOutcome)
        XCTAssertEqual(tracker.state, .idle)
    }
```

`testFinishSessionRecordsReachedActive`는 아래처럼 clock을 쓴다:

```swift
    func testFinishSessionRecordsReachedActive() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(endDebounceInterval: 0.1, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        clock.advance(0.2)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.lastOutcome?.reachedActive, true)
    }
```

`Date` equality는 `endedAt`을 `TimeInterval`로 비교한다. `CallSessionOutcome.endedAt`이 `Date`면 `timeIntervalSince1970`으로 단언한다. `XCTAssertEqual`의 `accuracy`는 `Date`에 없다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `swift test --filter CallLifecycleTrackerTests`  
Expected: FAIL — `lastOutcome` 없음.

- [ ] **Step 3: tracker를 고친다**

`CallLifecycleState.swift`에:

```swift
struct CallSessionOutcome: Equatable {
    var startedAt: Date
    var endedAt: Date
    var reachedActive: Bool
}
```

`CallLifecycleTracker`:
- `@Published private(set) var lastOutcome: CallSessionOutcome?`
- `private var sessionReachedActive = false`
- 새 세션 시작 시 `CallSession(startedAt: now(), displayCaller:)` — `Date()`를 쓰지 않는다. 테스트 clock과 맞춘다.
- `.active`로 갈 때 `sessionReachedActive = true`
- `finishSession`: `lastOutcome = CallSessionOutcome(startedAt: currentSession?.startedAt ?? now(), endedAt: now(), reachedActive: sessionReachedActive)` 후 세션/`sessionReachedActive` 클리어
- `reset()`: `lastOutcome = nil`, `sessionReachedActive = false` (기존처럼 세션도 클리어). missed로 쓰지 않는다
- `.idle` / `.ended`:

```swift
        case .idle, .ended:
            if isActiveEvidence(evidence) {
                lastOutcome = nil
                sessionReachedActive = true
                currentSession = CallSession(startedAt: now(), displayCaller: displayCaller)
                transition(to: .active)
            } else if hasAnyCandidate {
                lastOutcome = nil
                sessionReachedActive = false
                let session = CallSession(startedAt: now(), displayCaller: displayCaller)
                currentSession = session
                transition(to: .ringing)
                logger.log("[CALL] candidate discovered, session=\(session.id)")
            }
```

기존 idle→ringing 로그를 유지한다.

- [ ] **Step 4: 테스트를 통과시킨다**

Run: `swift test --filter 'CallLifecycleTrackerTests|AnswerTransitionGraceTests'`  
Expected: PASS. grace hangup은 `reachedActive=false` outcome을 남긴다.

---

### Task 4: Bridge API 클라 direction + summary

**Files:**
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/JarvisAPIClient.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/JarvisAPIClientTests.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift` (`FakeCallReporter`)
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift` (시그니처만 맞춘다)

- [ ] **Step 1: 실패하는 클라 테스트를 추가한다**

`JarvisAPIClient.swift`에 먼저 이 enum을 두면 테스트가 컴파일된다. enum만 먼저 넣고 메서드는 아직 바꾸지 않으면 create 테스트는 기존 incoming을 유지한 채 새 테스트를 못 짠다. **enum + 프로토콜 시그니처를 이 스텝에서 바꾸고, 구현은 Step 3에서 한다.** 그 사이 프로덕션이 깨지면 바로 Step 3으로 간다.

추가 테스트:

```swift
    func testCreateCallPostsOutgoingDirection() async throws {
        let client = JarvisAPIClient { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["direction"] as? String, "outgoing")
            let data = Data(#"{"id":"call-out","status":"active"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let id = try await client.createCall(
            origin: "https://jarvis-api.twms.ai",
            token: "jarvis-token",
            caller: CallCaller(name: "unknown", phoneNumber: "+821011122233"),
            startedAt: Date(timeIntervalSince1970: 1),
            direction: .outgoing
        )
        XCTAssertEqual(id, "call-out")
    }

    func testCompleteCallPostsFixedSummary() async throws {
        let client = JarvisAPIClient { request in
            XCTAssertEqual(request.url?.path, "/api/calls/call-1/complete")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["summary"] as? String, "콜백 연결 안 됨")
            XCTAssertEqual(body?["uploadFailed"] as? Bool, true)
            let transcript = body?["transcript"] as? [Any]
            XCTAssertEqual(transcript?.count, 0)
            return (Data(#"{"id":"call-1","status":"failed"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await client.completeCall(
            origin: "https://jarvis-api.twms.ai",
            token: "t",
            id: "call-1",
            endedAt: Date(timeIntervalSince1970: 2),
            transcript: [],
            uploadFailed: true,
            summary: "콜백 연결 안 됨"
        )
    }
```

기존 `testCreateCallPostsCallerAndReturnsId`는 `direction: .incoming`을 명시한다.

- [ ] **Step 2: 컴파일/테스트가 깨지는지 확인한다**

Run: `swift test --filter JarvisAPIClientTests`  
Expected: FAIL — `CallReportDirection` 또는 새 인자 없음.

- [ ] **Step 3: 프로토콜과 클라를 고친다**

```swift
enum CallReportDirection: String {
    case incoming
    case outgoing
}

protocol JarvisCallReporting: AnyObject {
    func createCall(
        origin: String, token: String, caller: CallCaller, startedAt: Date,
        direction: CallReportDirection
    ) async throws -> String
    func uploadCallAudio(origin: String, token: String, id: String, data: Data) async throws
    func completeCall(
        origin: String, token: String, id: String, endedAt: Date,
        transcript: [CallTranscriptTurn], uploadFailed: Bool, summary: String?
    ) async throws
}
```

`createCall` body `"direction": direction.rawValue`.  
`completeCall` body에 `summary`가 nil이 아니면 `"summary": summary`를 넣는다. nil이면 키를 생략한다.

`OpenAIRealtimeVoiceSessionController.startCallReport`는 당분간 `direction: .incoming`, complete는 `summary: nil`. `FakeCallReporter` 시그니처를 맞추고 `createdDirection` / `lastSummary`를 기록만 한다.

- [ ] **Step 4: 테스트를 통과시킨다**

Run: `swift test --filter 'JarvisAPIClientTests|OpenAIRealtimeVoiceSessionControllerTests'`  
Expected: PASS.

---

### Task 5: 발신 인사 조합 + reportDirection

**Files:**
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeCallInstructions.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/RealtimeCallInstructionsTests.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift`
- Modify: `bridge/Sources/JarvisCallBridge/UI/ContentView.swift` (캡션만)

- [ ] **Step 1: 실패하는 조합 테스트를 추가한다**

```swift
    func testOutgoingEmptyDoesNotUseIncomingDefaultOpening() {
        let text = RealtimeCallInstructions.composeOutgoing(style: .polite, extra: "")
        XCTAssertTrue(text.contains(OpenAIRealtimeVoiceAdapter.defaultInstructions))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.politeLine))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.defaultOpening))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.verbatimOpeningLine))
    }

    func testOutgoingExtraIsSpokenVerbatim() {
        let text = RealtimeCallInstructions.composeOutgoing(style: .casual, extra: "다시 연락드렸습니다.")
        XCTAssertTrue(text.contains("다시 연락드렸습니다."))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.verbatimOpeningLine))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.defaultOpening))
    }

    func testStoreComposedOutgoingUsesOutgoingGreetingOnly() {
        let defaults = UserDefaults(suiteName: "test.realtime.instructions.\(UUID().uuidString)")!
        let store = UserDefaultsRealtimeCallInstructionStore(defaults: defaults)
        store.incomingGreeting = "수신 인사"
        store.outgoingGreeting = "발신 인사"
        XCTAssertTrue(store.composedInstructions(direction: .outgoing).contains("발신 인사"))
        XCTAssertFalse(store.composedInstructions(direction: .outgoing).contains("수신 인사"))
        XCTAssertFalse(store.composedInstructions(direction: .outgoing).contains(RealtimeCallInstructions.defaultOpening))
    }
```

기존 `composedInstructions()`는 incoming 유지. incoming 오버로드를 `composedInstructions(direction: .incoming)`에 위임해도 된다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `swift test --filter RealtimeCallInstructionsTests`  
Expected: FAIL — `composeOutgoing` 없음.

- [ ] **Step 3: 조합과 세션 direction을 구현한다**

```swift
    static func composeOutgoing(style: RealtimeSpeechStyle, extra: String) -> String {
        let styleLine = style == .polite ? politeLine : casualLine
        let greeting = normalizedExtra(extra)
        if greeting.isEmpty {
            return [OpenAIRealtimeVoiceAdapter.defaultInstructions, styleLine].joined(separator: "\n")
        }
        return [
            OpenAIRealtimeVoiceAdapter.defaultInstructions,
            styleLine,
            verbatimOpeningLine,
            openingOnceLine,
            greeting,
        ].joined(separator: "\n")
    }
```

store:

```swift
    func composedInstructions(direction: CallReportDirection = .incoming) -> String {
        switch direction {
        case .incoming:
            return RealtimeCallInstructions.compose(style: speechStyle, extra: incomingGreeting)
        case .outgoing:
            return RealtimeCallInstructions.composeOutgoing(style: speechStyle, extra: outgoingGreeting)
        }
    }
```

`OpenAIRealtimeVoiceSessionController`:
- `var reportDirection: CallReportDirection = .incoming`
- `loadInstructions` 기본 클로저를 `(CallReportDirection) -> (style, extra, text)`로 바꾼다. extra는 로그용으로 incoming/outgoing greeting.
- `makeAdapter` 기본값은 `nil`을 받아 init 본문에서 채운다:

```swift
        self.makeAdapter = makeAdapter ?? { [weak self] env in
            let direction = self?.reportDirection ?? .incoming
            let store = UserDefaultsRealtimeCallInstructionStore()
            return OpenAIRealtimeVoiceAdapter(
                apiKey: env.apiKey ?? "",
                model: env.model ?? RealtimeEnvFile.defaultModel,
                transport: URLSessionRealtimeWebSocketTransport(),
                instructions: store.composedInstructions(direction: direction),
                followUpInstructions: RealtimeCallInstructions.composeAfterOpening(style: store.speechStyle)
            )
        }
```

기존 `makeAdapter:` 기본 파라미터를 optional로 바꾸고, 테스트가 넘기는 `{ _ in mock }`는 그대로 컴파일되게 한다.

`startCallReport`는 `direction: reportDirection`을 넣는다.

`ContentView` 발신 인사 caption: `"콜백이 연결되면 한 번만 그대로 말합니다. 비우면 수신 기본 인사를 쓰지 않습니다."`

- [ ] **Step 4: 테스트를 통과시킨다**

Run: `swift test --filter 'RealtimeCallInstructionsTests|OpenAIRealtimeVoiceSessionControllerTests'`  
Expected: PASS.

연결 후 보고 테스트가 있으면 `createdDirection == .outgoing`를 하나 추가한다. 기존 incoming 보고 테스트는 `reportDirection` 기본값으로 통과해야 한다.

---

### Task 6: 종료 후보 resolver

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Call/IncomingEndCallControlMatcher.swift`
- Create: `bridge/Sources/JarvisCallBridge/Call/EndCallCandidateResolver.swift`
- Test: `bridge/Tests/JarvisCallBridgeTests/EndCallCandidateResolverTests.swift`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

```swift
import XCTest
@testable import JarvisCallBridge

final class EndCallCandidateResolverTests: XCTestCase {
    func testSingleBannerEndCallIsHigh() {
        let resolved = EndCallCandidateResolver.resolve(from: [TestSnapshots.endCallButton()])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.confidence, .high)
    }

    func testTwoEndCallsAreMedium() {
        let resolved = EndCallCandidateResolver.resolve(from: [
            TestSnapshots.endCallButton(id: "end-1"),
            TestSnapshots.endCallButton(id: "end-2"),
        ])
        XCTAssertEqual(resolved.count, 2)
        XCTAssertTrue(resolved.allSatisfy { $0.confidence == .medium })
    }

    func testAnswerButtonIsNotAnEndCall() {
        XCTAssertTrue(EndCallCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()]).isEmpty)
    }

    func testBarePhoneAppEndIsNotACandidate() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "quit", title: "종료")
        XCTAssertTrue(EndCallCandidateResolver.resolve(from: [snapshot]).isEmpty)
    }
}
```

`ordinaryPhoneAppControl`이 `title`만 받고 `description`은 다른지 픽스처를 확인한다. description `"종료"`인 Phone.app 컨트롤이 있으면 그걸 쓴다. 배너 ancestry가 없으면 matcher가 거절해야 한다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `swift test --filter EndCallCandidateResolverTests`  
Expected: FAIL.

- [ ] **Step 3: matcher + resolver를 구현한다**

`IncomingEndCallControlMatcher`는 `IncomingAnswerControlMatcher`와 동일 구조에 `endDescription = "종료"`만 다르다. owner / window / banner / AXButton / enabled / AXPress를 그대로 요구한다.

`EndCallCandidateResolver`는 `AnswerCandidateResolver`와 같다. 반환 타입은 `AnswerCandidate`를 재사용한다 (같은 snapshot+confidence). 새 타입을 만들지 않는다.

- [ ] **Step 4: 테스트를 통과시킨다**

Run: `swift test --filter EndCallCandidateResolverTests`  
Expected: PASS.

---

### Task 7: 컨트롤러 — 부재중 enqueue / 번호 없음 보고

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Call/CallTelURL.swift`
- Create: `bridge/Sources/JarvisCallBridge/Call/CallURLOpening.swift`
- Create: `bridge/Sources/JarvisCallBridge/Call/MissedCallCallbackController.swift`
- Test: `bridge/Tests/JarvisCallBridgeTests/CallTelURLTests.swift`
- Test: `bridge/Tests/JarvisCallBridgeTests/MissedCallCallbackControllerTests.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Call/IncomingCallObserver.swift`

- [ ] **Step 1: tel URL 테스트**

```swift
final class CallTelURLTests: XCTestCase {
    func testBuildsTelFromStoredNumber() {
        XCTAssertEqual(CallTelURL.make(phoneNumber: "+821011122233")?.absoluteString, "tel:+821011122233")
    }

    func testRejectsUnknown() {
        XCTAssertNil(CallTelURL.make(phoneNumber: "unknown"))
        XCTAssertNil(CallTelURL.make(phoneNumber: ""))
    }
}
```

구현:

```swift
enum CallTelURL {
    static func make(phoneNumber: String) -> URL? {
        let compact = phoneNumber.filter { $0.isNumber || $0 == "+" }
        guard !compact.isEmpty, compact != "unknown" else { return nil }
        return URL(string: "tel:\(compact)")
    }
}
```

`CallURLOpening.swift`:

```swift
import AppKit
import Foundation

protocol CallURLOpening: AnyObject {
    func open(_ url: URL) -> Bool
}

final class WorkspaceCallURLOpener: CallURLOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: 컨트롤러 enqueue 테스트를 작성한다**

테스트 더블:

```swift
@MainActor
final class SpyCallURLOpener: CallURLOpening {
    var opened: [URL] = []
    var result = true
    func open(_ url: URL) -> Bool {
        opened.append(url)
        return result
    }
}

@MainActor
final class SpyFailedCallReporter: JarvisCallReporting {
    var created: [(CallCaller, CallReportDirection)] = []
    var summaries: [String?] = []

    func createCall(origin: String, token: String, caller: CallCaller, startedAt: Date, direction: CallReportDirection) async throws -> String {
        created.append((caller, direction))
        return "call-failed"
    }
    func uploadCallAudio(origin: String, token: String, id: String, data: Data) async throws {}
    func completeCall(origin: String, token: String, id: String, endedAt: Date, transcript: [CallTranscriptTurn], uploadFailed: Bool, summary: String?) async throws {
        summaries.append(summary)
    }
}
```

컨트롤러 테스트 (요지):

```swift
    func testMissedLongRingEnqueuesOncePerNumber() async {
        // ringing 5s, delay 3, phone found → queue 1
        // 같은 번호 다시 → 여전히 1
    }

    func testShortRingLeavesQueueEmpty() async {
        // ringing 2s, delay 3 → 0
    }

    func testUnknownPhoneReportsNoNumberAndDoesNotEnqueue() async {
        // queue 0, create outgoing + summary 번호 없음
    }

    func testActiveSessionDoesNotEnqueue() async {
        // lastOutcome.reachedActive true → 0
    }
```

컨트롤러 API:

```swift
    func handleIncomingBecameIdle()
```

내부에서 `tracker.lastOutcome`, `resolveCaller()`, AA/WorkMode/delay provider를 읽는다. 로그:

- enqueue: `[CALL-CALLBACK] result=enqueued phone=found`
- skip: `[CALL-CALLBACK] result=skipped phone=found|missing`
- no number: `[CALL-CALLBACK] result=no_number phone=missing`

번호·이름·`tel:` 전체를 로그에 쓰지 않는다.

실패 보고 헬퍼 (컨트롤러 private):

```swift
    private func reportFailed(caller: CallCaller, summary: String) async
```

`createCall(..., direction: .outgoing)` 후 `completeCall(..., transcript: [], uploadFailed: true, summary: summary)`. origin/token은 `RealtimeEnvFile`과 같은 `loadEnv` 클로저에서 읽는다. 테스트는 고정 origin/token을 넣는다. env가 비면 보고를 건너뛰고 `result=skipped`만 남긴다.

- [ ] **Step 3: 테스트가 실패하는지 확인한다**

Run: `swift test --filter MissedCallCallbackControllerTests`  
Expected: FAIL.

- [ ] **Step 4: 컨트롤러 enqueue 경로와 observer 배선을 구현한다**

`IncomingCallObserver`에 `callback: MissedCallCallbackController? = nil`. idle 전이에서 **`onCallerSessionEnded`보다 먼저**:

```swift
        if !wasIdle && tracker.state == .idle {
            await callback?.handleIncomingBecameIdle()
            autoAnswer.resetForNewCall()
            onCallerSessionEnded?()
        }
```

`handleIncomingBecameIdle`이 비동기로 보고할 수 있으니 `async`로 둔다. 기존 테스트는 `callback` nil이라 동작이 같다.

Work Mode OFF 분기의 `tracker.reset()`은 outcome을 안 남기므로 큐에 안 들어간다.

- [ ] **Step 5: 테스트를 통과시킨다**

Run: `swift test --filter 'MissedCallCallbackControllerTests|IncomingCallObserverTests|CallTelURLTests'`  
Expected: PASS.

---

### Task 8: 스케줄 틱 — 한 통 pop + tel: + 게이트

**Files:**
- Modify: `MissedCallCallbackController.swift`
- Modify: `MissedCallCallbackControllerTests.swift`

- [ ] **Step 1: 실패하는 틱 테스트를 작성한다**

```swift
    func testTickDialsOldestOnly() async {
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date(timeIntervalSince1970: 1))
        store.enqueue(phoneNumber: "+821022222222", ringingStartedAt: Date(timeIntervalSince1970: 2))
        await controller.tick()
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(opener.opened.first?.absoluteString, "tel:+821011111111")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.peekOldest()?.phoneNumber, "+821022222222")
    }

    func testTickSkipsWhenRinging() async {
        tracker.update(hasAnyCandidate: true, evidence: .none)
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date())
        await controller.tick()
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(store.count, 1)
    }

    func testTickSkipsWhenAutoAnswerOff() async {
        autoAnswer.isEnabled = false
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date())
        await controller.tick()
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(store.count, 1)
    }

    func testTickSkipsWhenAlreadyDialing() async {
        controller.beginDialingForTest()
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date())
        await controller.tick()
        XCTAssertTrue(opener.opened.isEmpty)
    }
```

`beginDialingForTest()` 대신 `isDialing`을 내부에서 켜는 첫 틱을 두 번 연속 호출해도 된다. 한 틱이 Active를 기다리면 두 번째 틱이 겹치지 않아야 한다.

로그: `[CALL-CALLBACK] result=dial phone=found`. opened URL을 로그에 넣지 않는다.

틱 게이트:

```text
AA off → return
Work Mode off → return (스펙 정지 표에는 없지만 제품 트리거와 같게)
state in ringing/answering/active/ending → return
isDialing → return
queue empty → return
```

한 건 pop 후 `isDialing = true`, `reportDirection = .outgoing`, `tel:` open.

이 Task에서는 대기를 바로 끝내지 말고, **open 후 Active 대기 루프를 아주 짧게** 두되 테스트 clock/`noAnswerSeconds`를 주입한다. 기본 테스트는 `noAnswerSeconds = 0` 또는 즉시 timeout으로 끊기 경로를 Task 9에 맡긴다.

틱 테스트가 hang 하지 않게 `waitForActive`를 `noAnswerSeconds == 0`이면 즉시 no-answer로 두거나, 테스트에서 `tracker`를 바로 `.active`로 만든다.

`testTickDialsOldestOnly`는 건 뒤 큐에서 이미 빠진 것만 보면 된다. 대기는 `noAnswerSeconds = 0` + hangup spy로 즉시 끝나게 한다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `swift test --filter MissedCallCallbackControllerTests`  
Expected: FAIL — `tick` 없음 또는 게이트 없음.

- [ ] **Step 3: `tick()`과 타이머 start/stop을 구현한다**

```swift
    func start() {
        stop()
        let interval = TimeInterval(store.intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }
```

단위 테스트는 `start()`를 부르지 않고 `tick()`만 부른다. `BridgeViewModel.start()`에서 `callback.start()`를 호출하는 것은 Task 10.

- [ ] **Step 4: 테스트를 통과시킨다**

Run: `swift test --filter MissedCallCallbackControllerTests`  
Expected: PASS.

---

### Task 9: 미응답 끊기 + 실패 보고

**Files:**
- Modify: `MissedCallCallbackController.swift`
- Modify: `MissedCallCallbackControllerTests.swift`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

```swift
    func testNoAnswerHangsUpOnceAndReportsFixedSummary() async {
        store.noAnswerSeconds = 1
        store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        // hangup scanner returns one high 종료
        scanner.snapshotsToReturn = [TestSnapshots.endCallButton()]
        await controller.tick()
        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(scanner.pressedSnapshotIDs, ["end-call-1"])
        XCTAssertEqual(reporter.summaries, ["콜백 연결 안 됨"])
        XCTAssertEqual(reporter.created.last?.1, .outgoing)
        XCTAssertFalse(controller.isDialing)
        XCTAssertEqual(store.count, 0)
    }

    func testTelOpenFailureStillReportsNoAnswer() async {
        opener.result = false
        store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        await controller.tick()
        XCTAssertEqual(reporter.summaries, ["콜백 연결 안 됨"])
        XCTAssertEqual(store.count, 0)
    }

    func testAmbiguousEndCallDoesNotPressButStillReports() async {
        scanner.snapshotsToReturn = [
            TestSnapshots.endCallButton(id: "end-1"),
            TestSnapshots.endCallButton(id: "end-2"),
        ]
        store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        await controller.tick()
        XCTAssertEqual(scanner.pressCallCount, 0)
        XCTAssertEqual(reporter.summaries, ["콜백 연결 안 됨"])
    }
```

로그: `result=no_answer` 후 끊기 시도 시 `result=hangup`. 둘 다 `phone=found`.

Active가 제한 시간 안에 오면 hangup/report를 하지 않는다:

```swift
    func testActiveBeforeTimeoutDoesNotHangup() async {
        store.noAnswerSeconds = 2
        store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        // tick 시작 직후 tracker를 active로 만드는 방법은
        // wait 루프가 tracker.state를 보도록 하고, 테스트에서
        // Task { clock/advance; tracker.update(..., activeEvidence) } 를 겹친다.
    }
```

대기 루프:

```swift
        let deadline = now().addingTimeInterval(TimeInterval(store.noAnswerSeconds))
        while now() < deadline {
            if tracker.state == .active { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
```

테스트 clock을 쓰면 `now()`가 안 가서 루프가 돈다. **대기에는 실제 `Task.sleep` + 실시간 `noAnswerSeconds`를 쓰고, 테스트는 1초를 쓴다.** 또는 `sleeper`를 주입해 테스트에서 즉시 한 바퀴만 돌린다.

권장 seam:

```swift
    var waitSlice: TimeInterval = 0.05
    private let now: () -> Date
```

테스트:

```swift
        var now = Date(timeIntervalSince1970: 0)
        let controller = MissedCallCallbackController(..., now: { now }, waitSlice: 0)
        // tick 내부: slice 0이면 한 번 state만 보고 deadline 비교
        now = Date(timeIntervalSince1970: 2) // noAnswerSeconds=1 이면 timeout
```

`waitSlice == 0`이면 sleep 없이 `now()`만 다시 읽고 끝낸다. 테스트가 루프 전에 `now`를 미래로 밀면 timeout. Active 테스트는 루프 전에 tracker를 active로 둔다 — 그런데 tick 게이트가 active면 걸지 않는다.

Active 테스트 순서:
1. idle에서 enqueue
2. tick이 pop+dial 후 wait에 들어감
3. 같은 tick의 wait 중에 state가 active여야 함

`onDial` 훅을 테스트에만 둔다:

```swift
    var onDidDial: (() -> Void)?
```

프로덕션은 nil. 테스트:

```swift
        controller.onDidDial = {
            tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        }
```

그러면 게이트를 지난 뒤에 Active가 된다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `swift test --filter MissedCallCallbackControllerTests`  
Expected: FAIL.

- [ ] **Step 3: wait / hangup / report를 구현한다**

끊기:

```swift
        let resolved = EndCallCandidateResolver.resolve(from: scanner.scanCallRelevantElements())
        let high = resolved.filter { $0.confidence == .high }
        if high.count == 1, let end = high.first {
            _ = scanner.press(end.snapshot)
            logger.log("[CALL-CALLBACK] result=hangup phone=found")
        }
```

그 다음 항상 `reportFailed(summary: "콜백 연결 안 됨")`, `isDialing = false`.

연결 시: `logger.log("[CALL-CALLBACK] result=connected phone=found")`, `isDialing = false`. Realtime/녹음은 기존 Active 경로. `reportDirection`은 outgoing으로 유지하고, 다음 착신 ringing에서 incoming으로 되돌린다.

observer:

```swift
        if wasIdle && tracker.state == .ringing && callback?.isDialing != true {
            realtimeSession.reportDirection = .incoming
        }
```

observer가 realtime을 모르면 컨트롤러가 `onIncomingRinging()`에서 `session.reportDirection = .incoming`을 한다. **컨트롤러가 session을 약하게 들고 있는 편이 맞다.**

```swift
        weak var realtimeSession: OpenAIRealtimeVoiceSessionController?
```

dial 직전 `realtimeSession?.reportDirection = .outgoing`.  
incoming ringing (observer → `callback.noteIncomingRinging()`): `isDialing == false`일 때만 incoming.

- [ ] **Step 4: 테스트를 통과시킨다**

Run: `swift test --filter MissedCallCallbackControllerTests`  
Expected: PASS. 로그 assertion은 prefix만. 번호 문자열이 로그에 있으면 fail.

---

### Task 10: ViewModel + UI 배선

**Files:**
- Modify: `bridge/Sources/JarvisCallBridge/App/BridgeViewModel.swift`
- Modify: `bridge/Sources/JarvisCallBridge/UI/ContentView.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Call/IncomingCallObserver.swift` (callback 주입)

- [ ] **Step 1: ViewModel에 컨트롤러를 붙인다**

```swift
    let callback: MissedCallCallbackController
```

init에서 store / opener / scanner / tracker / autoAnswer / logger / resolveCaller / loadEnv / reporter(`JarvisAPIClient`)로 만든다. `realtimeSessionController`를 `callback.realtimeSession`에 넣는다.

`incomingCallObserver` init에 `callback: callback`을 준다. observer가 tracker보다 나중에 만들어지므로 순서는: tracker → autoAnswer → callback → observer.

`start()` 끝에 `callback.start()`.

- [ ] **Step 2: ContentView Auto Answer 바로 아래에 둔다**

```swift
                HStack {
                    Text("콜백 주기").foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.callback.intervalMinutes },
                        set: { model.callback.intervalMinutes = $0 }
                    )) {
                        Text("1분").tag(1)
                        Text("5분").tag(5)
                        Text("10분").tag(10)
                        Text("15분").tag(15)
                        Text("30분").tag(30)
                        Text("60분").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Text("미응답 후 끊기").foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.callback.noAnswerSeconds },
                        set: { model.callback.noAnswerSeconds = $0 }
                    )) {
                        Text("15초").tag(15)
                        Text("30초").tag(30)
                        Text("45초").tag(45)
                        Text("60초").tag(60)
                        Text("90초").tag(90)
                        Text("120초").tag(120)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Text("큐 \(model.callback.queueCount)").foregroundStyle(.secondary)
                }
```

`ContentView`에 `@ObservedObject var callback: MissedCallCallbackController`를 두고 init에서 `model.callback`을 넣는다.

컨트롤러:

```swift
    @Published var intervalMinutes: Int {
        didSet {
            store.intervalMinutes = intervalMinutes
            restartTimerIfRunning()
        }
    }
    @Published var noAnswerSeconds: Int {
        didSet { store.noAnswerSeconds = noAnswerSeconds }
    }
    @Published private(set) var queueCount: Int = 0
```

enqueue/pop 후 `queueCount = store.count`.

설정 setter는 clamp를 store에 맡기고 published를 다시 store 값으로 맞춘다.

- [ ] **Step 3: 앱을 빌드한다**

Run: `cd /Volumes/Dev/workspaces/twms/jarvis/bridge && ./Scripts/build-app.sh`  
Expected: 성공. 드라이버 스크립트는 실행하지 않는다.

기존 `BridgeViewModelPhase3Tests`가 새 의존성 때문에 깨지면, 테스트용 opener/reporter를 기본값(`WorkspaceCallURLOpener`, `JarvisAPIClient`)으로 두면 생성자는 그대로다.

---

### Task 11: 자동화 전부 + 실기기 체크리스트

**Files:** 없음 (검증만)

- [ ] **Step 1: API**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/api && npm test -- test/calls.test.ts
```

Expected: PASS.

- [ ] **Step 2: Bridge**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge && swift test --filter 'MissedCallCallback|CallTelURL|EndCallCandidate|CallLifecycleTrackerTests|RealtimeCallInstructionsTests|JarvisAPIClientTests|OpenAIRealtimeVoiceSessionControllerTests|IncomingCallObserverTests'
```

Expected: PASS.

- [ ] **Step 3: 앱 빌드**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge && ./Scripts/build-app.sh
```

Expected: 성공. `AudioDriver/` diff 없음.

- [ ] **Step 4: 실기기는 사용자 확인 전 PASS 금지**

스펙 8절:

1. AA 3초, 1초 만에 상대가 끊음 → 콜백 없음
2. AA 3초, 5초 울린 뒤 못 받음 → 주기(테스트 1분) 뒤 그 번호로 발신
3. 안 받으면 제한 시간에 끊김, Admin `콜백 연결 안 됨`
4. 받으면 발신 인사, 녹음 `S_…`
5. 로그에 번호/이름/`tel:` 전체 없음

이 체크포인트만으로 Phase 5 COMPLETE를 쓰지 않는다.

---

## Self-review

**스펙 커버**

| 스펙 | Task |
|---|---|
| 트리거 / 짧은 벨 / AA·WM off / Active면 제외 | 2, 7 |
| unknown은 큐 없이 `번호 없음` | 1, 7 |
| 큐 중복·oldest 1통·1회 pop | 2, 8 |
| `tel:` only | 7, 8 |
| 미응답 초 / 종료 1회 / 실패 이력 | 1, 6, 9 |
| 연결 시 발신 인사, 수신 기본문 금지, outgoing 보고 | 5, 9 |
| 스케줄 정지 (통화 중 / 발신 중) | 8 |
| 로그 토큰, 번호 없음 | 7–9 |
| UI 주기/초/큐 | 10 |
| 드라이버 미변경 | 11 |
| Phase 5 COMPLETE 안 함 | 11 |

**플레이스홀더:** 없음. 실기기 4번은 사용자 확인이다.

**타입:** `CallReportDirection`, `MissedCallCallbackDecision`, `CallSessionOutcome`, `FIXED_CALLBACK_SUMMARIES` / `"콜백 연결 안 됨"` / `"번호 없음"`를 전 Task에서 그대로 쓴다.
