# Phase 4 CHECKPOINT 3 — 여러 턴 + 상대 끼어들기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 한 통화에서 여러 턴이 이어지고, 전화 상대가 AI 말 중에 말하면 로컬 TX를 비워 상대 폰에서 AI가 즉시 멈추게 한다. 주인 개입은 없다.

**Architecture:** CP2 세션·어댑터·Continuity 탭 RX를 유지한다. `session.update`의 `audio.input.turn_detection`에 `server_vad` + `create_response` + `interrupt_response`를 명시한다. `speech_started`면 adapter TX 큐를 비우고 세션이 제어면에서 `clearTX()`만 호출한다. 클라이언트 `response.cancel`은 보내지 않는다.

**Tech Stack:** Swift 6 / SwiftPM (`bridge/`), 기존 `JarvisPCMRuntimeClearTX`, XCTest. 새 서드파티 없음. 드라이버 수정 없음.

**스펙:** `docs/superpowers/specs/2026-08-23-phase4-cp3-multiturn-barge-in-design.md`

작업 디렉터리: `/Volumes/Dev/workspaces/twms/jarvis`  
테스트: `cd bridge && swift test --filter <TestClass>`

**바꾸면 안 되는 것:** disconnect → pcm.stop 순서, Realtime 실패로 route 롤백 금지, Ringing에서 PCM/Realtime 금지, 주인 takeover UI, 드라이버/070/SIP/Jarvis Agent, 로컬 에너지 VAD, `response.cancel`.

---

## File map

| 파일 | 역할 |
|---|---|
| `docs/Call_Bridge_v2_Phase_4_Report.md` | CP3 계획 경로 |
| `Realtime/RealtimeVoiceAdapting.swift` | `onRemoteSpeechStarted` |
| `Realtime/OpenAIRealtimeVoiceAdapter.swift` | turn_detection JSON, speech_started → 큐 클리어 + 콜백 |
| `Realtime/MockRealtimeVoiceAdapter.swift` | 테스트용 콜백/큐 클리어 |
| `Realtime/RealtimePCMBuffering.swift` | `clearTX()` |
| `System/SystemCallAudioPCMController.swift` | `JarvisPCMRuntimeClearTX` 래핑 |
| `Realtime/OpenAIRealtimeVoiceSessionController.swift` | 콜백에서 `clearTX()`, RX는 유지 |
| 테스트 3개 | adapter JSON/이벤트, 세션 ClearTX, InMemory clearTX |

---

### Task 1: 리포트에 계획 경로

**Files:**
- Modify: `docs/Call_Bridge_v2_Phase_4_Report.md`

- [x] **Step 1:** 헤더 스펙 목록 아래에 계획(CP3) 한 줄을 추가한다.

```markdown
계획(CP3): `docs/superpowers/plans/2026-08-23-phase4-cp3-multiturn-barge-in.md`
```

- [x] **Step 2: Commit**

```bash
git add docs/Call_Bridge_v2_Phase_4_Report.md docs/superpowers/plans/2026-08-23-phase4-cp3-multiturn-barge-in.md
git commit -m "docs: add Phase 4 CP3 implementation plan"
```

---

### Task 2: session.update에 server_vad (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceAdapterTests.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceAdapter.swift`

- [ ] **Step 1: 실패하는 테스트**

`testConnectSendsSessionUpdateWithInstructionsAndPCMFormat` 끝에 아래를 추가한다. 최상위 `session.turn_detection`이 아니라 `session.audio.input.turn_detection`이다.

```swift
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let turn = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(turn["type"] as? String, "server_vad")
        XCTAssertEqual(turn["create_response"] as? Bool, true)
        XCTAssertEqual(turn["interrupt_response"] as? Bool, true)
        XCTAssertNil(session["turn_detection"], "do not send both turn_detection locations")
```

같은 파일에 여러 턴 큐 테스트를 추가한다.

```swift
    func testPollTXKeepsTwoResponseDeltas() async {
        let transport = FakeRealtimeWebSocketTransport()
        let adapter = OpenAIRealtimeVoiceAdapter(apiKey: "sk-test", model: "m", transport: transport)
        XCTAssertTrue(await adapter.connect())
        adapter.ingestServerMessage("""
        {"type":"response.output_audio.delta","delta":"\(pcm16Base64([1, 2]))"}
        """)
        adapter.ingestServerMessage("""
        {"type":"response.output_audio.delta","delta":"\(pcm16Base64([3, 4]))"}
        """)
        XCTAssertEqual(adapter.pollTX(), [1, 2])
        XCTAssertEqual(adapter.pollTX(), [3, 4])
        await adapter.disconnect()
    }
```

- [ ] **Step 2:** `cd bridge && swift test --filter OpenAIRealtimeVoiceAdapterTests`  
Expected: FAIL — `turn_detection` 없음.

- [ ] **Step 3:** `sessionUpdateJSON()`의 `audio.input`에 turn_detection을 넣는다.

```swift
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "turn_detection": [
                        "type": "server_vad",
                        "create_response": true,
                        "interrupt_response": true,
                    ],
                ],
                "output": ["format": ["type": "audio/pcm", "rate": 24000]],
            ],
```

Bool이 JSON에서 `NSNumber`로 떨어지면 테스트에서 `(turn["create_response"] as? NSNumber)?.boolValue == true`로 맞춘다. 구현은 Swift `true` 그대로.

- [ ] **Step 4:** 같은 필터 PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceAdapterTests.swift \
  bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceAdapter.swift
git commit -m "feat: enable server VAD with remote interrupt_response"
```

---

### Task 3: speech_started가 TX 큐를 비움 (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceAdapterTests.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceAdapting.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceAdapter.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/MockRealtimeVoiceAdapter.swift`

- [ ] **Step 1: 실패하는 테스트**

```swift
    func testSpeechStartedClearsQueuedTXAndDoesNotSendCancel() async {
        let transport = FakeRealtimeWebSocketTransport()
        let adapter = OpenAIRealtimeVoiceAdapter(apiKey: "sk-test", model: "m", transport: transport)
        var speechCallbacks = 0
        adapter.onRemoteSpeechStarted = { speechCallbacks += 1 }
        XCTAssertTrue(await adapter.connect())
        adapter.ingestServerMessage("""
        {"type":"response.output_audio.delta","delta":"\(pcm16Base64([9, 8, 7]))"}
        """)
        adapter.ingestServerMessage(#"{"type":"input_audio_buffer.speech_started"}"#)
        XCTAssertEqual(adapter.pollTX(), [])
        XCTAssertEqual(speechCallbacks, 1)
        XCTAssertFalse(transport.sentTexts.contains(where: { $0.contains("response.cancel") }))
        await adapter.disconnect()
    }

    func testBareSpeechStartedTypeAlsoClearsTX() async {
        let transport = FakeRealtimeWebSocketTransport()
        let adapter = OpenAIRealtimeVoiceAdapter(apiKey: "sk-test", model: "m", transport: transport)
        XCTAssertTrue(await adapter.connect())
        adapter.ingestServerMessage("""
        {"type":"response.audio.delta","delta":"\(pcm16Base64([5]))"}
        """)
        adapter.ingestServerMessage(#"{"type":"speech_started"}"#)
        XCTAssertEqual(adapter.pollTX(), [])
        await adapter.disconnect()
    }
```

- [ ] **Step 2:** 같은 필터. Expected: FAIL — `onRemoteSpeechStarted` 없음.

- [ ] **Step 3:** 프로토콜에 콜백을 추가한다.

```swift
@MainActor
protocol RealtimeVoiceAdapting: AnyObject {
    var onRemoteSpeechStarted: (() -> Void)? { get set }
    func connect() async -> Bool
    func disconnect() async
    func sendRX(_ pcm16Mono24k: [Int16])
    func pollTX() -> [Int16]
}
```

`OpenAIRealtimeVoiceAdapter`에 `var onRemoteSpeechStarted: (() -> Void)?`를 두고, `ingestServerMessage` switch에:

```swift
        case "input_audio_buffer.speech_started", "speech_started":
            txQueue = []
            onRemoteSpeechStarted?()
```

`MockRealtimeVoiceAdapter`에도 같은 프로퍼티를 둔다.

```swift
    var onRemoteSpeechStarted: (() -> Void)?

    func fireRemoteSpeechStarted() {
        txQueue = []
        onRemoteSpeechStarted?()
    }
```

`disconnect()`에서 `onRemoteSpeechStarted = nil`은 하지 않아도 된다. 세션이 adapter를 버리면 충분하다.

- [ ] **Step 4:** 필터 PASS. `sentTexts`에 `response.cancel`이 생겼으면 구현에서 그 send를 삭제한다.

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceAdapting.swift \
  bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceAdapter.swift \
  bridge/Sources/JarvisCallBridge/Realtime/MockRealtimeVoiceAdapter.swift \
  bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceAdapterTests.swift
git commit -m "feat: drop queued AI audio when remote speech starts"
```

---

### Task 4: RealtimePCMBuffering.clearTX (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift` (`InMemoryRealtimePCMBuffer`)
- Test: `bridge/Tests/JarvisCallBridgeTests/SystemCallAudioPCMControllerComputationTests.swift` (`testClearTXDropsUnreadFrames`가 이미 C API를 친다 — 유지)
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/RealtimePCMBuffering.swift`
- Modify: `bridge/Sources/JarvisCallBridge/System/SystemCallAudioPCMController.swift`

- [ ] **Step 1: 실패하는 테스트**

`InMemoryRealtimePCMBuffer`에 `clearTX()`가 없으면 컴파일이 깨진다. 먼저 세션 테스트 파일 하단에 인메모리 동작을 고정한다.

```swift
    func testInMemoryClearTXDropsQueuedFramesOnly() {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.rx = [0.1, 0.1]
        pcm.tx = [0.2, 0.2, 0.3, 0.3]
        pcm.clearTX()
        XCTAssertEqual(pcm.tx, [])
        XCTAssertEqual(pcm.rx, [0.1, 0.1])
        XCTAssertEqual(pcm.queuedTXFrames(), 0)
    }
```

- [ ] **Step 2:** `cd bridge && swift test --filter OpenAIRealtimeVoiceSessionControllerTests`  
Expected: FAIL — `clearTX` 프로토콜 요구 누락.

- [ ] **Step 3:**

`RealtimePCMBuffering.swift`:

```swift
    func clearRX()
    func clearTX()
```

`InMemoryRealtimePCMBuffer`:

```swift
    func clearRX() { rx = [] }
    func clearTX() { tx = [] }
```

`SystemCallAudioPCMController`의 `clearRX()` 옆에:

```swift
    func clearTX() {
        guard let runtime else { return }
        JarvisPCMRuntimeClearTX(runtime)
    }
```

기존 `testClearTXDropsUnreadFrames`는 그대로 통과해야 한다.

- [ ] **Step 4:**  
`swift test --filter OpenAIRealtimeVoiceSessionControllerTests` PASS  
`swift test --filter SystemCallAudioPCMControllerComputationTests/testClearTXDropsUnreadFrames` PASS

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/RealtimePCMBuffering.swift \
  bridge/Sources/JarvisCallBridge/System/SystemCallAudioPCMController.swift \
  bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift
git commit -m "feat: expose ClearTX on the Realtime PCM buffer"
```

---

### Task 5: 세션이 speech_started에서 clearTX만 (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift`
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift` (`InMemoryRealtimePCMBuffer`에 카운터)

- [ ] **Step 1: 실패하는 테스트**

`InMemoryRealtimePCMBuffer`에 카운터를 둔다.

```swift
    private(set) var clearRXCount = 0
    private(set) var clearTXCount = 0

    func clearRX() {
        clearRXCount += 1
        rx = []
    }

    func clearTX() {
        clearTXCount += 1
        tx = []
    }
```

세션 테스트:

```swift
    func testRemoteSpeechStartedClearsTXAndLeavesRXAndPCMRunning() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = [0.4, 0.4]
        pcm.tx = [0.9, 0.9]
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([100, 101])
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        mock.fireRemoteSpeechStarted()
        XCTAssertEqual(pcm.clearTXCount, 1)
        XCTAssertEqual(pcm.clearRXCount, 0)
        XCTAssertEqual(pcm.tx, [])
        XCTAssertEqual(pcm.rx, [0.4, 0.4])
        XCTAssertTrue(pcm.isRunning)
        XCTAssertEqual(mock.pollTX(), [])
        XCTAssertEqual(session.uiState, .connected)
    }
```

- [ ] **Step 2:** 같은 필터. Expected: FAIL — connect 후 콜백이 연결되지 않아 `clearTXCount == 0`.

- [ ] **Step 3:** `connect`가 adapter를 만든 직후(성공 후) 콜백을 건다. `pumpOnce`가 아니라 이벤트에서 바로 `clearTX`.

```swift
        guard ok else {
            uiState = .failed("network")
            self.adapter = nil
            return
        }
        adapter.onRemoteSpeechStarted = { [weak self] in
            self?.handleRemoteSpeechStarted()
        }
        isConnectedNow = true
```

```swift
    private func handleRemoteSpeechStarted() {
        guard isConnectedNow else { return }
        pcm.clearTX()
    }
```

`disconnect`에서는 기존처럼 `clearRX()`를 유지하고, 추가로 `clearTX()`를 호출해도 된다(다음 통화를 깨끗하게). 끼어들기 테스트는 disconnect 전에 assert하므로 영향 없다.

주인 개입 버튼/로컬 마이크 믹스는 추가하지 않는다.

- [ ] **Step 4:** 필터 PASS. `testDisconnectLeavesPCMRunning`도 PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift \
  bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift
git commit -m "feat: clear Inject TX when the remote party starts speaking"
```

---

### Task 6: 전체 스위트 + 리포트

**Files:**
- Modify: `docs/Call_Bridge_v2_Phase_4_Report.md`

- [ ] **Step 1:** `cd bridge && swift test`  
Expected: 기존 368 + 신규 전부 PASS (대략 372+). 실패 0.

- [ ] **Step 2:** 리포트 자동화 줄에 CP3 통과 수와 날짜를 적는다. 실기기 PASS를 선언하지 않는다. Phase 5를 시작하지 않는다.

- [ ] **Step 3: Commit**

```bash
git add docs/Call_Bridge_v2_Phase_4_Report.md
git commit -m "test: record Phase 4 CP3 automated coverage"
```

---

### Task 7: 실기기 (사용자)

에이전트는 전화/OpenAI 실연결을 하지 않는다. 앱만 `bridge/Scripts/build-app.sh`로 다시 빌드한다. 드라이버 재설치 없음.

사용자가 확인할 것:

1. Realtime 토글 ON, 실통화 Connected
2. 턴 1 → 답이 끝난 뒤 턴 2 (가능하면 턴 3)
3. AI가 말하는 동안 상대가 끼어듦 → 상대 폰에서 AI가 바로 끊김
4. `~/Documents` RX/TX WAV + 로그를 에이전트에게 전달
5. 주인 마이크/개입 버튼은 보지 않음

실기기 PASS 뒤에만 Phase 4 COMPLETE. 에이전트는 Phase 5를 자동으로 열지 않는다.

---

## Self-review

| 스펙 | 태스크 |
|---|---|
| `server_vad` + create/interrupt true | Task 2 |
| 두 경로 turn_detection 동시 금지 | Task 2 assert `session["turn_detection"] == nil` |
| 여러 턴 delta 큐 | Task 2 `testPollTXKeepsTwoResponseDeltas` |
| speech_started / speech_started 단명 | Task 3 |
| txQueue 클리어, response.cancel 없음 | Task 3 |
| `clearTX` 프로토콜 + 런타임 래핑 | Task 4 |
| 끼어들기 때 clearTX 1, clearRX 0, PCM running | Task 5 |
| 주인 takeover 없음 | Task 5 — UI/마이크 추가 금지 |
| 자동화 수 + 실기기 게이트 | Task 6–7 |
| 드라이버/Agent/녹음 | 어떤 태스크도 만지지 않음 |
