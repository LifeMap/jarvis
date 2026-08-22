# Phase 4 CHECKPOINT 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inject TX를 lock-free 링 하나로 바꾸고, Realtime adapter·변환·세션 순서를 테스트로 고정한다. 앱에는 OpenAI를 붙이지 않는다.

**Architecture:** Inject IOProc은 링만 읽고, 1 kHz는 비실시간 생산자가 같은 링에 쓴다. 변환기(`48k stereo f32 ↔ 24k mono PCM16`)와 mock adapter는 순수 Swift이며 단위 테스트만 탄다. `CallAudioSessionController`는 PCM start 성공 뒤에만 `realtime.connect`하고, restore/rollback/ownership-loss에서는 `disconnect` 다음 `pcm.stop`이다. 앱 기본값은 `NullRealtimeVoiceSessionController`(no-op).

**Tech Stack:** Swift 6 / SwiftPM (`bridge/`), C11 atomics (`JarvisPCMRealtime`), XCTest. 새 서드파티 없음. 드라이버 수정 없음.

**스펙:** `docs/superpowers/specs/2026-08-21-phase4-cp1-realtime-voice-design.md`

**테스트 중 바꿔도 되는 것:** 톤 펌프 주기, 청크 프레임 수, 선형 리샘플 세부.  
**바꾸면 안 되는 것:** TX 소비 경로 하나, Ringing에서 PCM/Realtime 금지, 앱에 provider 미연결, Realtime 실패로 route 롤백 금지, 드라이버/070/SIP/하드웨어 sink.

**underrun 고정 (스펙 보강):** 링이 비고 톤이 idle이면 무음만 쓰고 카운트하지 않는다. `txUnderrunCount`는 톤이 queued/playing인데 콜백을 다 채우지 못할 때만 +1. 톤이 이번 콜백에서 정상 종료되어 나머지가 무음인 경우는 카운트하지 않는다. (유휴 통화 중 콜백마다 underrun이 쌓이면 안 된다.)

작업 디렉터리: `/Volumes/Dev/workspaces/twms/jarvis/bridge`  
테스트: `swift test --filter <TestClass>` 또는 `swift test`

---

## File map

| 파일 | 역할 |
|---|---|
| `docs/Call_Bridge_v2_Phase_3_Report.md` | 헤더만 COMPLETE로 |
| `docs/Call_Bridge_v2_Phase_4_Report.md` | 신규. CP1 IN PROGRESS |
| `bridge/Sources/JarvisPCMRealtime/include/JarvisPCMRealtime.h` | `WriteTXFrames` / `ClearTX` / 링 용량 |
| `bridge/Sources/JarvisPCMRealtime/JarvisPCMRealtime.c` | 링 + IOProc 소비. IOProc에서 사인 삭제 |
| `bridge/Sources/JarvisCallBridge/System/SystemCallAudioPCMController.swift` | 톤 생산자(첫 청크 + 펌프) |
| `bridge/Sources/JarvisCallBridge/Realtime/RealtimeAudioFormat.swift` | 24k/mono/PCM16 상수 |
| `bridge/Sources/JarvisCallBridge/Realtime/RealtimeAudioConverter.swift` | 순수 변환 |
| `bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceAdapting.swift` | adapter 프로토콜 |
| `bridge/Sources/JarvisCallBridge/Realtime/MockRealtimeVoiceAdapter.swift` | 테스트 mock |
| `bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceSessionControlling.swift` | 세션 프로토콜 |
| `bridge/Sources/JarvisCallBridge/Realtime/NullRealtimeVoiceSessionController.swift` | 앱 기본 no-op |
| `bridge/Sources/JarvisCallBridge/System/CallAudioSessionController.swift` | connect/disconnect 순서 |
| `bridge/Tests/JarvisCallBridgeTests/SystemCallAudioPCMControllerComputationTests.swift` | 링·톤 테스트 개편 |
| `bridge/Tests/JarvisCallBridgeTests/RealtimeAudioConverterTests.swift` | 변환 |
| `bridge/Tests/JarvisCallBridgeTests/RealtimeVoiceAdapterTests.swift` | mock adapter |
| `bridge/Tests/JarvisCallBridgeTests/CallAudioSessionSpies.swift` | Realtime 스파이 |
| `bridge/Tests/JarvisCallBridgeTests/CallAudioPCMCoordinationTests.swift` | 세션 순서 테스트 추가 |
| `bridge/Sources/JarvisCallBridge/UI/ContentView.swift` | **변경하지 않음** |

기존 `CallAudioSessionController(...)` 호출부는 새 파라미터에 기본값을 줘서 깨지 않는다.

---

### Task 1: Phase 문서 헤더

**Files:**
- Modify: `docs/Call_Bridge_v2_Phase_3_Report.md` (1–8행만)
- Create: `docs/Call_Bridge_v2_Phase_4_Report.md`

- [ ] **Step 1: Phase 3 헤더를 COMPLETE로 교체**

`docs/Call_Bridge_v2_Phase_3_Report.md` 5–8행을 아래로 바꾼다. 그 아래 과거 이력 문단은 삭제하지 않는다.

```markdown
- **Phase 3 CHECKPOINT 1**: **FINAL PASS**
- **Phase 3 CHECKPOINT 2**: **FINAL PASS** — 실기기: RX, TX 1 kHz, 동시 RX/TX, 연속 2통화, route restore, Active+PCM 중 Work Mode OFF (PCM stop → inject/capture stop → route restore)
- **Phase 3**: **COMPLETE**
- **Phase 4**: 이 문서에서 이어 쓰지 않음 — `docs/Call_Bridge_v2_Phase_4_Report.md`
```

- [ ] **Step 2: Phase 4 리포트 생성**

`docs/Call_Bridge_v2_Phase_4_Report.md`:

```markdown
# CB v2 Phase 4 Report — Realtime Voice

작성일: 2026-08-21

- **Phase 4 CHECKPOINT 1**: **IN PROGRESS** — TX 링 + 변환 + adapter/세션 순서. 앱에 OpenAI 없음.
- **Phase 4 CHECKPOINT 2**: **BLOCKED** — 실통화 speech-to-speech
- **Phase 4**: **BLOCKED** until CHECKPOINT 1 PASS

스펙: `docs/superpowers/specs/2026-08-21-phase4-cp1-realtime-voice-design.md`  
계획: `docs/superpowers/plans/2026-08-21-phase4-cp1-realtime-foundation.md`
```

- [ ] **Step 3: Commit**

```bash
git add docs/Call_Bridge_v2_Phase_3_Report.md docs/Call_Bridge_v2_Phase_4_Report.md
git commit -m "$(cat <<'EOF'
docs: stamp Phase 3 complete and open Phase 4 CP1 report

EOF
)"
```

---

### Task 2: TX 링 + Inject 소비 + 기존 톤 테스트 개편

**Files:**
- Modify: `bridge/Sources/JarvisPCMRealtime/include/JarvisPCMRealtime.h`
- Modify: `bridge/Sources/JarvisPCMRealtime/JarvisPCMRealtime.c`
- Modify: `bridge/Tests/JarvisCallBridgeTests/SystemCallAudioPCMControllerComputationTests.swift`

이 태스크가 끝날 때까지 `swift test --filter SystemCallAudioPCMControllerComputationTests`는 다시 초록이어야 한다. IOProc을 링 소비로 바꾸면 기존 “IOProc이 사인을 생성” 테스트는 같은 태스크에서 고친다.

- [ ] **Step 1: 헤더에 링 API 추가**

`JarvisPCMRealtime.h`의 `#define JARVIS_PCM_CAPTURE_RENDER_MAX_FRAMES 8192` 아래에:

```c
#define JARVIS_PCM_TX_RING_FRAMES 9600
```

`JarvisPCMRuntimeRequestTone` 선언 뒤에:

```c
/* Control plane. Writes up to frameCount interleaved stereo Float32 frames.
   Returns frames actually stored. Never blocks. */
uint32_t JarvisPCMRuntimeWriteTXFrames(
    JarvisPCMRuntimeContext *context,
    const float *interleaved,
    uint32_t frameCount
);

/* Control plane after both IOProcs have stopped, or during Reset.
   Drops unread TX. Future barge-in may call this; CP1 does not call it while IOProc runs. */
void JarvisPCMRuntimeClearTX(JarvisPCMRuntimeContext *context);
```

Inject IOProc 주석을 “링을 읽고, 부족분은 무음”으로 바꾼다. 사인 생성 문구를 지운다.

파일 상단 ownership 주석: `tonePhase`는 IOProc이 만지지 않는다. 사인은 생산자가 `WriteTXFrames`로 넣는다. `toneFramesRemaining`은 IOProc이 소비 카운트용으로만 유지한다.

- [ ] **Step 2: 링을 쓰는 실패 테스트 추가**

`SystemCallAudioPCMControllerComputationTests.swift`에 헬퍼와 테스트를 추가한다. `WriteTXFrames`가 아직 없으면 컴파일 실패가 올바른 실패다.

```swift
private func writeSine(to ctx: OpaquePointer, frames: Int, startFrame: Int = 0) -> UInt32 {
    var samples = [Float](repeating: 0, count: frames * channelCount)
    for frame in 0..<frames {
        let sample = Float(sin(2 * Double.pi * 1000.0 * Double(startFrame + frame) / 48000.0)) * 0.1
        samples[frame * channelCount] = sample
        samples[frame * channelCount + 1] = sample
    }
    return samples.withUnsafeBufferPointer { buf in
        JarvisPCMRuntimeWriteTXFrames(ctx, buf.baseAddress, UInt32(frames))
    }
}

func testWriteThenInjectCopiesExactFramesAndIdleEmptyRingIsNotUnderrun() {
    guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
    defer { JarvisPCMRuntimeDestroy(ctx) }

    XCTAssertEqual(writeSine(to: ctx, frames: 8), 8)

    let (output, samples, disposeOut) = makeBufferList(frameCount: 8)
    defer { disposeOut() }
    runInjectIOProc(context: ctx, output: output)

    for frame in 0..<8 {
        let expected = Float(sin(2 * Double.pi * 1000.0 * Double(frame) / 48000.0)) * 0.1
        XCTAssertEqual(samples[frame * channelCount], expected, accuracy: 0.0001)
        XCTAssertEqual(samples[frame * channelCount + 1], expected, accuracy: 0.0001)
    }
    XCTAssertEqual(readMetrics(ctx).txUnderrunCount, 0)
    XCTAssertEqual(readMetrics(ctx).txFrames, 8)

    let (output2, samples2, dispose2) = makeBufferList(frameCount: 8, initial: [Float](repeating: 0.7, count: 16))
    defer { dispose2() }
    runInjectIOProc(context: ctx, output: output2)
    for i in 0..<16 { XCTAssertEqual(samples2[i], 0) }
    XCTAssertEqual(readMetrics(ctx).txUnderrunCount, 0, "idle empty ring is silence, not underrun")
}

func testWriteTXFramesReturnsPartialWhenRingIsFull() {
    guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
    defer { JarvisPCMRuntimeDestroy(ctx) }
    let frames = Int(JARVIS_PCM_TX_RING_FRAMES)
    XCTAssertEqual(writeSine(to: ctx, frames: frames), UInt32(frames))
    XCTAssertEqual(writeSine(to: ctx, frames: 16), 0)
}

func testClearTXDropsUnreadFrames() {
    guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
    defer { JarvisPCMRuntimeDestroy(ctx) }
    XCTAssertEqual(writeSine(to: ctx, frames: 32), 32)
    JarvisPCMRuntimeClearTX(ctx)
    let (output, samples, disposeOut) = makeBufferList(frameCount: 8, initial: [Float](repeating: 0.5, count: 16))
    defer { disposeOut() }
    runInjectIOProc(context: ctx, output: output)
    for i in 0..<16 { XCTAssertEqual(samples[i], 0) }
}

func testQueuedToneWithEmptyRingRecordsOneUnderrun() {
    guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
    defer { JarvisPCMRuntimeDestroy(ctx) }
    XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 480))
    let (output, samples, disposeOut) = makeBufferList(frameCount: 10, initial: [Float](repeating: 0.9, count: 20))
    defer { disposeOut() }
    runInjectIOProc(context: ctx, output: output)
    for i in 0..<20 { XCTAssertEqual(samples[i], 0) }
    XCTAssertEqual(readMetrics(ctx).txUnderrunCount, 1)
    XCTAssertEqual(readMetrics(ctx).toneState, 1, "still queued — nothing consumed")
}
```

기존 테스트 수정 요지 (구현 후 같은 파일에서):

- `testRequestToneFromIdleSucceedsExactlyOnce` / `testSecondRequestWhileQueuedIsRejected` — 그대로.
- `testSecondRequestWhilePlayingIsRejected`: `RequestTone` → `writeSine(10)` → `runInjectIOProc(10)` → state 2 → 두 번째 `RequestTone` false.
- `testInjectIOProcTransitionsQueuedToPlayingOnFirstConsumption`: `RequestTone` + `writeSine(10)` 후 IOProc.
- `testInjectIOProcWritesExactDeterministicSineAtConfiguredFrequencyAndAmplitude`: `writeSine(480)` 후 IOProc. `RequestTone`은 샘플 값에 필요 없다.
- `testInjectIOProcTonePhaseIsContinuousAcrossMultipleInvocations`: `writeSine(200)` 한 번, IOProc 100 + IOProc 100. 두 번째 첫 샘플은 frame 100 위상.
- `testInjectIOProcCompletionTransitionsPlayingToIdleAndSilencesRemainder`: `RequestTone(30)` + `writeSine(30)` + IOProc 100. 프레임 30..<100은 0, `toneState == 0`, **underrun == 0**.
- `testStaleRequestCannotReplayOnALaterInvocationAfterCompletion`: 위와 같이 소비 완료 후 두 번째 IOProc은 무음.
- `testResetClearsAllPreviousMetricsAndPendingRequest`: Reset 후 링도 비어 있어야 한다. Reset 경로에서 `ClearTX` 호출.

`testReset...`가 톤을 큐하고 IOProc을 돌리는 기존 흐름이 있으면, Reset 전에 쓴 링이 Reset 후 재생되지 않는지를 한 줄 추가한다.

- [ ] **Step 3: 테스트가 컴파일/실패하는지 확인**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter SystemCallAudioPCMControllerComputationTests
```

Expected: `JarvisPCMRuntimeWriteTXFrames` / `JARVIS_PCM_TX_RING_FRAMES` / `JarvisPCMRuntimeClearTX` 미정의로 실패.

- [ ] **Step 4: 링 구현 + IOProc 소비**

`JarvisPCMRealtime.c`의 `struct JarvisPCMRuntimeContext`에 추가:

```c
float txRing[JARVIS_PCM_TX_RING_FRAMES * JARVIS_PCM_CHANNEL_COUNT];
uint32_t txRingWritePos;
uint32_t txRingReadPos;
_Atomic uint32_t txRingCount;
```

`JarvisPCMRuntimeReset` 끝에서 `JarvisPCMRuntimeClearTX(context);` 호출.

`JarvisPCMRuntimeAtomicsAreLockFree`에 `txRingCount` 추가.

```c
void JarvisPCMRuntimeClearTX(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return;
    atomic_store_explicit(&context->txRingCount, 0, memory_order_relaxed);
    context->txRingWritePos = 0;
    context->txRingReadPos = 0;
}

uint32_t JarvisPCMRuntimeWriteTXFrames(
    JarvisPCMRuntimeContext *context,
    const float *interleaved,
    uint32_t frameCount
) {
    if (context == NULL || interleaved == NULL || frameCount == 0) return 0;
    uint32_t used = atomic_load_explicit(&context->txRingCount, memory_order_acquire);
    uint32_t space = JARVIS_PCM_TX_RING_FRAMES - used;
    uint32_t take = frameCount < space ? frameCount : space;
    uint32_t pos = context->txRingWritePos;
    for (uint32_t f = 0; f < take; f++) {
        uint32_t idx = ((pos + f) % JARVIS_PCM_TX_RING_FRAMES) * JARVIS_PCM_CHANNEL_COUNT;
        context->txRing[idx] = interleaved[f * JARVIS_PCM_CHANNEL_COUNT];
        context->txRing[idx + 1] = interleaved[f * JARVIS_PCM_CHANNEL_COUNT + 1];
    }
    context->txRingWritePos = (pos + take) % JARVIS_PCM_TX_RING_FRAMES;
    atomic_fetch_add_explicit(&context->txRingCount, take, memory_order_release);
    return take;
}

static uint32_t ConsumeTXRing(JarvisPCMRuntimeContext *ctx, float *out, uint32_t frameCount) {
    uint32_t available = atomic_load_explicit(&ctx->txRingCount, memory_order_acquire);
    uint32_t take = available < frameCount ? available : frameCount;
    uint32_t pos = ctx->txRingReadPos;
    for (uint32_t f = 0; f < take; f++) {
        uint32_t idx = ((pos + f) % JARVIS_PCM_TX_RING_FRAMES) * JARVIS_PCM_CHANNEL_COUNT;
        out[f * JARVIS_PCM_CHANNEL_COUNT] = ctx->txRing[idx];
        out[f * JARVIS_PCM_CHANNEL_COUNT + 1] = ctx->txRing[idx + 1];
    }
    ctx->txRingReadPos = (pos + take) % JARVIS_PCM_TX_RING_FRAMES;
    if (take > 0) {
        atomic_fetch_sub_explicit(&ctx->txRingCount, take, memory_order_release);
    }
    return take;
}
```

`JarvisPCMInjectIOProc`의 사인 루프를 교체한다. 한 버퍼에 대해:

```c
uint32_t copied = ConsumeTXRing(ctx, samples, (uint32_t)frameCount);
if (copied < (uint32_t)frameCount) {
    memset(samples + copied * JARVIS_PCM_CHANNEL_COUNT, 0,
           (size_t)(frameCount - (int64_t)copied) * JARVIS_PCM_CHANNEL_COUNT * sizeof(Float32));
}

int32_t tone = atomic_load_explicit(&ctx->toneState, memory_order_acquire);
if (ctx->toneFramesRemaining <= 0 && copied > 0) {
    int32_t requested = 0;
    if (PollQueuedToneRequest(ctx, &requested)) {
        ctx->toneFramesRemaining = requested;
    }
}
if (ctx->toneFramesRemaining > 0) {
    int64_t consumed = copied < (uint32_t)ctx->toneFramesRemaining
        ? (int64_t)copied : ctx->toneFramesRemaining;
    ctx->toneFramesRemaining -= consumed;
    if (ctx->toneFramesRemaining == 0) {
        MarkToneComplete(ctx);
        tone = 0;
    } else {
        tone = 2;
    }
}
/* Underrun: tone still queued/playing and this callback was not fully filled.
   Completing the tone mid-callback (copied < frameCount but remaining hit 0) is not underrun. */
int32_t toneNow = atomic_load_explicit(&ctx->toneState, memory_order_acquire);
if (copied < (uint32_t)frameCount && (toneNow == 1 || toneNow == 2)) {
    RecordTXUnderrun(ctx);
}

RecordTX(ctx, frameCount);
```

`tonePhase`는 IOProc에서 읽거나 쓰지 않는다. `#include <math.h>`의 `sin`이 IOProc에서 사라지면, math.h는 다른 곳이 쓰지 않으면 남겨 두어도 된다.

- [ ] **Step 5: 기존 톤 테스트를 write-then-consume으로 수정한 뒤 스위트 통과**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter SystemCallAudioPCMControllerComputationTests
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add bridge/Sources/JarvisPCMRealtime/include/JarvisPCMRealtime.h \
        bridge/Sources/JarvisPCMRealtime/JarvisPCMRealtime.c \
        bridge/Tests/JarvisCallBridgeTests/SystemCallAudioPCMControllerComputationTests.swift
git commit -m "$(cat <<'EOF'
feat: consume Inject TX from a lock-free ring

EOF
)"
```

---

### Task 3: 1 kHz를 링 생산자로 옮기기

**Files:**
- Modify: `bridge/Sources/JarvisCallBridge/System/SystemCallAudioPCMController.swift`
- Test: 기존 computation 테스트가 C 경로를 커버. 이 태스크는 앱 `sendTestTone`만 생산자로 바꾼다.

- [ ] **Step 1: 톤 펌프 상태 추가**

`SystemCallAudioPCMController`에:

```swift
private var tonePumpTimer: Timer?
private var toneFramesLeftToWrite: Int = 0
private var tonePhaseFrame: Int = 0
```

`stop`의 `stopMetricsTimer()` 옆에 `stopTonePump()`를 호출한다. 펌프가 돌아도 IOProc이 이미 죽은 뒤에는 `WriteTXFrames`를 호출하지 않는다 (`runtime == nil`이면 return).

```swift
private func stopTonePump() {
    tonePumpTimer?.invalidate()
    tonePumpTimer = nil
    toneFramesLeftToWrite = 0
    tonePhaseFrame = 0
}

private func writeToneFrames(to runtime: OpaquePointer, maxFrames: Int) -> Int {
    let frames = min(maxFrames, toneFramesLeftToWrite)
    guard frames > 0 else { return 0 }
    var samples = [Float](repeating: 0, count: frames * 2)
    let sampleRate = CallAudioPCMFormat.expected.sampleRate
    for frame in 0..<frames {
        let sample = Float(sin(2 * Double.pi * 1000.0 * Double(tonePhaseFrame + frame) / sampleRate)) * 0.1
        samples[frame * 2] = sample
        samples[frame * 2 + 1] = sample
    }
    let written = samples.withUnsafeBufferPointer { buf in
        Int(JarvisPCMRuntimeWriteTXFrames(runtime, buf.baseAddress, UInt32(frames)))
    }
    tonePhaseFrame += written
    toneFramesLeftToWrite -= written
    return written
}
```

- [ ] **Step 2: `sendTestTone`이 첫 청크를 동기적으로 쓰게 변경**

`JarvisPCMRuntimeRequestTone` 성공 직후:

```swift
testToneState = .queued
logger.log("[CALL-PCM] test-tone queued")
toneFramesLeftToWrite = Int(frameCount)
tonePhaseFrame = 0
_ = writeToneFrames(to: runtime, maxFrames: Int(JARVIS_PCM_TX_RING_FRAMES))
stopTonePump()
if toneFramesLeftToWrite > 0 {
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.pumpTone() }
    }
    tonePumpTimer = timer
    RunLoop.main.add(timer, forMode: .common)
}
```

```swift
private func pumpTone() {
    guard state == .running, let runtime, toneFramesLeftToWrite > 0 else {
        stopTonePump()
        return
    }
    _ = writeToneFrames(to: runtime, maxFrames: 4800)
    if toneFramesLeftToWrite == 0 { stopTonePump() }
}
```

`completed` 로그는 기존 5Hz `publishMetrics`가 `toneState` 0 전이를 보는 경로를 유지한다. 생산자가 다 썼다고 `completed`를 찍지 않는다.

- [ ] **Step 3: 컴파일과 기존 테스트**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter SystemCallAudioPCMControllerComputationTests
swift test --filter CallAudioPCMCoordinationTests
```

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/System/SystemCallAudioPCMController.swift
git commit -m "$(cat <<'EOF'
feat: stream the 1 kHz test tone into the TX ring

EOF
)"
```

---

### Task 4: Realtime 변환기

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeAudioFormat.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeAudioConverter.swift`
- Create: `bridge/Tests/JarvisCallBridgeTests/RealtimeAudioConverterTests.swift`

- [ ] **Step 1: 실패 테스트**

```swift
import XCTest
@testable import JarvisCallBridge

final class RealtimeAudioConverterTests: XCTestCase {
    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(RealtimeAudioConverter.toProviderRX(interleavedStereo48k: []).isEmpty)
        XCTAssertTrue(RealtimeAudioConverter.toHALTX(mono24kPCM16: []).isEmpty)
    }

    func testSilenceRoundTripStaysQuiet() {
        let stereo = [Float](repeating: 0, count: 480) // 240 frames, L/R
        let pcm16 = RealtimeAudioConverter.toProviderRX(interleavedStereo48k: stereo)
        XCTAssertEqual(pcm16.count, 120) // 48k/24k = 2, 240 frames → 120
        XCTAssertTrue(pcm16.allSatisfy { $0 == 0 })
        let back = RealtimeAudioConverter.toHALTX(mono24kPCM16: pcm16)
        XCTAssertEqual(back.count, 480)
        XCTAssertTrue(back.allSatisfy { abs($0) < 0.001 })
    }

    func testToneKeepsEnergyAfterRoundTrip() {
        var stereo = [Float](repeating: 0, count: 960)
        for frame in 0..<480 {
            let s = Float(sin(2 * Double.pi * 1000.0 * Double(frame) / 48000.0)) * 0.1
            stereo[frame * 2] = s
            stereo[frame * 2 + 1] = s
        }
        let pcm16 = RealtimeAudioConverter.toProviderRX(interleavedStereo48k: stereo)
        let peakIn = pcm16.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peakIn, 1000)
        let back = RealtimeAudioConverter.toHALTX(mono24kPCM16: pcm16)
        let peakOut = back.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peakOut, 0.05)
    }

    func testOddLengthStereoIsRejected() {
        XCTAssertTrue(RealtimeAudioConverter.toProviderRX(interleavedStereo48k: [0.1]).isEmpty)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter RealtimeAudioConverterTests
```

Expected: `RealtimeAudioConverter` 없음으로 실패.

- [ ] **Step 3: 구현**

`RealtimeAudioFormat.swift`:

```swift
enum RealtimeAudioFormat {
    static let sampleRate: Double = 24_000
    static let channelCount = 1
    static let halSampleRate: Double = 48_000
    static let halChannelCount = 2
}
```

`RealtimeAudioConverter.swift`:

```swift
enum RealtimeAudioConverter {
    static func toProviderRX(interleavedStereo48k: [Float]) -> [Int16] {
        guard interleavedStereo48k.count >= 2, interleavedStereo48k.count % 2 == 0 else { return [] }
        let mono48k: [Float] = stride(from: 0, to: interleavedStereo48k.count, by: 2).map { i in
            (interleavedStereo48k[i] + interleavedStereo48k[i + 1]) * 0.5
        }
        let mono24k = resampleLinear(mono48k, inRate: RealtimeAudioFormat.halSampleRate, outRate: RealtimeAudioFormat.sampleRate)
        return mono24k.map { sample in
            let clamped = max(-1, min(1, sample))
            return Int16((clamped * 32767.0).rounded())
        }
    }

    static func toHALTX(mono24kPCM16: [Int16]) -> [Float] {
        guard !mono24kPCM16.isEmpty else { return [] }
        let mono24k = mono24kPCM16.map { Float($0) / 32768.0 }
        let mono48k = resampleLinear(mono24k, inRate: RealtimeAudioFormat.sampleRate, outRate: RealtimeAudioFormat.halSampleRate)
        var stereo = [Float](repeating: 0, count: mono48k.count * 2)
        for i in mono48k.indices {
            stereo[i * 2] = mono48k[i]
            stereo[i * 2 + 1] = mono48k[i]
        }
        return stereo
    }

    private static func resampleLinear(_ input: [Float], inRate: Double, outRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        if inRate == outRate { return input }
        let ratio = inRate / outRate
        let outCount = max(1, Int((Double(input.count) / ratio).rounded(.down)))
        var output = [Float](repeating: 0, count: outCount)
        let last = input.count - 1
        for i in 0..<outCount {
            let src = Double(i) * ratio
            let i0 = Int(src)
            let frac = Float(src - Double(i0))
            let s0 = input[min(i0, last)]
            let s1 = input[min(i0 + 1, last)]
            output[i] = s0 + (s1 - s0) * frac
        }
        return output
    }
}
```

`toProviderRX`의 480 샘플(240 프레임) → 120 PCM16이 실패하면 `outCount` 계산을 `Int(Double(input.count) * outRate / inRate)`로 바꾼다. 테스트가 진실이다.

- [ ] **Step 4: 테스트 통과**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter RealtimeAudioConverterTests
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/RealtimeAudioFormat.swift \
        bridge/Sources/JarvisCallBridge/Realtime/RealtimeAudioConverter.swift \
        bridge/Tests/JarvisCallBridgeTests/RealtimeAudioConverterTests.swift
git commit -m "$(cat <<'EOF'
feat: add 48k stereo to 24k mono PCM16 converter

EOF
)"
```

---

### Task 5: Adapter 프로토콜 + mock

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceAdapting.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/MockRealtimeVoiceAdapter.swift`
- Create: `bridge/Tests/JarvisCallBridgeTests/RealtimeVoiceAdapterTests.swift`

앱 타깃에 OpenAI 구현을 넣지 않는다. `CallAudioSessionController`는 이 프로토콜을 몰라도 된다.

- [ ] **Step 1: 실패 테스트**

```swift
import XCTest
@testable import JarvisCallBridge

@MainActor
final class RealtimeVoiceAdapterTests: XCTestCase {
    func testMockConnectDisconnectAndBuffers() async {
        let mock = MockRealtimeVoiceAdapter()
        XCTAssertFalse(mock.isConnected)
        XCTAssertTrue(await mock.connect())
        XCTAssertTrue(mock.isConnected)

        let rx = RealtimeAudioConverter.toProviderRX(interleavedStereo48k: [0.1, 0.1, 0.1, 0.1])
        mock.sendRX(rx)
        XCTAssertEqual(mock.sentRX.count, 1)
        XCTAssertEqual(mock.sentRX[0], rx)

        mock.enqueueTX([0, 1, 2])
        XCTAssertEqual(mock.pollTX(), [0, 1, 2])
        XCTAssertEqual(mock.pollTX(), [])

        await mock.disconnect()
        XCTAssertFalse(mock.isConnected)
        XCTAssertTrue(mock.sentRX.isEmpty)
    }

    func testMockConnectFailure() async {
        let mock = MockRealtimeVoiceAdapter()
        mock.failConnect = true
        XCTAssertFalse(await mock.connect())
        XCTAssertFalse(mock.isConnected)
    }
}
```

- [ ] **Step 2: 실패 확인**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter RealtimeVoiceAdapterTests
```

Expected: 타입 없음으로 실패.

- [ ] **Step 3: 구현**

```swift
@MainActor
protocol RealtimeVoiceAdapting: AnyObject {
    func connect() async -> Bool
    func disconnect() async
    func sendRX(_ pcm16Mono24k: [Int16])
    func pollTX() -> [Int16]
}

@MainActor
final class MockRealtimeVoiceAdapter: RealtimeVoiceAdapting {
    var failConnect = false
    private(set) var isConnected = false
    private(set) var sentRX: [[Int16]] = []
    private var txQueue: [[Int16]] = []

    func connect() async -> Bool {
        if failConnect { return false }
        isConnected = true
        return true
    }

    func disconnect() async {
        isConnected = false
        sentRX = []
        txQueue = []
    }

    func sendRX(_ pcm16Mono24k: [Int16]) {
        guard isConnected else { return }
        sentRX.append(pcm16Mono24k)
    }

    func enqueueTX(_ pcm16Mono24k: [Int16]) {
        txQueue.append(pcm16Mono24k)
    }

    func pollTX() -> [Int16] {
        guard isConnected, !txQueue.isEmpty else { return [] }
        return txQueue.removeFirst()
    }
}
```

- [ ] **Step 4: 테스트 통과 + commit**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter RealtimeVoiceAdapterTests
```

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceAdapting.swift \
        bridge/Sources/JarvisCallBridge/Realtime/MockRealtimeVoiceAdapter.swift \
        bridge/Tests/JarvisCallBridgeTests/RealtimeVoiceAdapterTests.swift
git commit -m "$(cat <<'EOF'
feat: add mock Realtime voice adapter

EOF
)"
```

---

### Task 6: 세션 순서 — disconnect 후 PCM stop

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceSessionControlling.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/NullRealtimeVoiceSessionController.swift`
- Modify: `bridge/Sources/JarvisCallBridge/System/CallAudioSessionController.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/CallAudioSessionSpies.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/CallAudioPCMCoordinationTests.swift`

기존 `makeSpies()` 5튜플은 유지한다. Null이 기본이라 기존 테스트의 `orderLog`에 realtime 항목이 생기지 않는다. `testPCMStopHappensImmediatelyBeforeRouteRestorationOnConfirmedIdle`의 `pcm-start` 다음이 `pcm-stop`인 단언은 그대로 통과해야 한다.

- [ ] **Step 1: 스파이와 실패 테스트**

`CallAudioSessionSpies.swift`에:

```swift
@MainActor
final class RealtimeVoiceSessionControllingSpy: RealtimeVoiceSessionControlling {
    var failConnect = false
    var orderLog: CallAudioOperationOrderLog?
    private(set) var connectCalls: [String] = []
    private(set) var disconnectCalls: [String] = []

    func connect(reason: String) async {
        connectCalls.append(reason)
        orderLog?.record("realtime-connect")
        _ = failConnect
    }

    func disconnect(reason: String) async {
        disconnectCalls.append(reason)
        orderLog?.record("realtime-disconnect")
    }
}
```

`CallAudioPCMCoordinationTests`에 (컨트롤러 생성 시 `realtimeSession: spy` 전달):

```swift
func testRealtimeConnectsOnlyAfterSuccessfulPCMStartOnActive() async {
    let spies = CallAudioTestFixtures.makeSpies()
    let realtime = RealtimeVoiceSessionControllingSpy()
    let log = CallAudioTestFixtures.attachOrderLog(to: spies)
    realtime.orderLog = log
    let controller = CallAudioSessionController(
        routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
        pcmController: spies.pcm, processMute: spies.mute, realtimeSession: realtime,
        logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
    )
    let session = CallSession()
    await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
    XCTAssertTrue(realtime.connectCalls.isEmpty)
    await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
    XCTAssertEqual(realtime.connectCalls, ["takeover"])
    let pcmStart = log.entries.firstIndex(of: "pcm-start")!
    let rtConnect = log.entries.firstIndex(of: "realtime-connect")!
    XCTAssertLessThan(pcmStart, rtConnect)
}

func testRealtimeDisconnectsBeforePCMStopOnWorkModeOff() async {
    let spies = CallAudioTestFixtures.makeSpies()
    let realtime = RealtimeVoiceSessionControllingSpy()
    let log = CallAudioTestFixtures.attachOrderLog(to: spies)
    realtime.orderLog = log
    let controller = CallAudioSessionController(
        routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
        pcmController: spies.pcm, processMute: spies.mute, realtimeSession: realtime,
        logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
    )
    let session = CallSession()
    await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
    await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: false)
    XCTAssertEqual(realtime.disconnectCalls.last, "work-mode-off")
    let disconnect = log.entries.lastIndex(of: "realtime-disconnect")!
    let pcmStop = log.entries.lastIndex(of: "pcm-stop")!
    let restoreOutput = log.entries[pcmStop...].firstIndex(of: "route-set-output")!
    XCTAssertLessThan(disconnect, pcmStop)
    XCTAssertLessThan(pcmStop, restoreOutput)
}

func testRealtimeDisconnectsBeforePCMStopOnOwnershipLoss() async {
    let spies = CallAudioTestFixtures.makeSpies()
    let realtime = RealtimeVoiceSessionControllingSpy()
    let log = CallAudioTestFixtures.attachOrderLog(to: spies)
    realtime.orderLog = log
    let controller = CallAudioSessionController(
        routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
        pcmController: spies.pcm, processMute: spies.mute, realtimeSession: realtime,
        logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
    )
    let session = CallSession()
    await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
    spies.route.currentSnapshot = CallAudioRouteSnapshot(
        inputUID: "com.example.airpods", outputUID: "com.example.airpods",
        systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
    )
    await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
    XCTAssertEqual(realtime.disconnectCalls.last, "ownership-loss")
    XCTAssertLessThan(log.entries.lastIndex(of: "realtime-disconnect")!, log.entries.lastIndex(of: "pcm-stop")!)
}

func testRealtimeConnectFailureDoesNotRollbackRoute() async {
    let spies = CallAudioTestFixtures.makeSpies()
    let realtime = RealtimeVoiceSessionControllingSpy()
    realtime.failConnect = true
    let controller = CallAudioSessionController(
        routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
        pcmController: spies.pcm, processMute: spies.mute, realtimeSession: realtime,
        logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
    )
    await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)
    XCTAssertEqual(controller.state, .routed)
    XCTAssertTrue(spies.pcm.isRunning)
    XCTAssertEqual(spies.route.currentSnapshot?.outputUID, JarvisAudioDeviceUIDs.capture)
}
```

`failConnect`는 스파이에서 로그만 남기고 connect는 반환값이 없다. 세션 프로토콜은 `func connect(reason: String) async` (실패해도 route 유지). 스파이는 `failConnect`여도 호출만 기록한다. “실패해도 routed”는 Null/스파이 모두 connect가 던지지 않으면 이미 참이다.

추가 의미가 있는 실패 테스트는 mock adapter 쪽(Task 5)에 이미 있다. 여기서는 **순서**가 핵심이다. `failConnect` 테스트는 “connect를 호출하되 내부에서 실패를 삼켜도 routed 유지”로 남긴다. 스파이 구현:

```swift
func connect(reason: String) async {
    connectCalls.append(reason)
    orderLog?.record("realtime-connect")
    // failConnect: still do not throw; session controller ignores adapter-level failure
}
```

`testRealtimeConnectFailureDoesNotRollbackRoute`는 그대로 routed를 단언하면 된다.

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter CallAudioPCMCoordinationTests
```

Expected: `RealtimeVoiceSessionControlling` / init 파라미터 없음으로 실패.

- [ ] **Step 3: 프로토콜 + Null + 컨트롤러 배선**

`RealtimeVoiceSessionControlling.swift`:

```swift
@MainActor
protocol RealtimeVoiceSessionControlling: AnyObject {
    func connect(reason: String) async
    func disconnect(reason: String) async
}
```

`NullRealtimeVoiceSessionController.swift`:

```swift
@MainActor
final class NullRealtimeVoiceSessionController: RealtimeVoiceSessionControlling {
    func connect(reason: String) async {}
    func disconnect(reason: String) async {}
}
```

`CallAudioSessionController`에:

```swift
private let realtimeSession: RealtimeVoiceSessionControlling
```

`init`에 `realtimeSession: RealtimeVoiceSessionControlling? = nil`을 추가하고  
`self.realtimeSession = realtimeSession ?? NullRealtimeVoiceSessionController()`.

`startPCMIfNeeded` — PCM start 성공 후:

```swift
pcmStarted = true
await realtimeSession.connect(reason: "takeover")
```

`restore` / `rollback` / ownership-loss — 기존 `pcmController.stop` **바로 앞**:

```swift
await realtimeSession.disconnect(reason: reason) // rollback은 reason: "rollback", ownership-loss는 "ownership-loss"
await pcmController.stop(reason: reason)
```

ownership-loss의 현재 reason 문자열은 `"ownership-loss"`다. rollback은 `"rollback"`. restore는 인자 `reason`을 그대로 쓴다.

- [ ] **Step 4: 테스트 통과**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test --filter CallAudioPCMCoordinationTests
swift test --filter CallAudioSessionControllerTests
```

Expected: PASS. 기존 생성 호출은 기본값 Null이라 수정하지 않는다.

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceSessionControlling.swift \
        bridge/Sources/JarvisCallBridge/Realtime/NullRealtimeVoiceSessionController.swift \
        bridge/Sources/JarvisCallBridge/System/CallAudioSessionController.swift \
        bridge/Tests/JarvisCallBridgeTests/CallAudioSessionSpies.swift \
        bridge/Tests/JarvisCallBridgeTests/CallAudioPCMCoordinationTests.swift
git commit -m "$(cat <<'EOF'
feat: disconnect Realtime before PCM stop on restore

EOF
)"
```

---

### Task 7: 전체 테스트 + 실기기 게이트

**Files:** 없음 (실행과 리포트만)

- [ ] **Step 1: bridge 전체 테스트**

```bash
cd /Volumes/Dev/workspaces/twms/jarvis/bridge
swift test
```

Expected: 기존 332 + 신규 테스트 전부 PASS. 실패하면 해당 태스크로 돌아가 고친다. OpenAI/드라이버로 도망가지 않는다.

- [ ] **Step 2: Phase 4 리포트에 자동화 결과를 한 줄 추가**

`docs/Call_Bridge_v2_Phase_4_Report.md` 하단에 실행한 `swift test` 요약(통과 수)을 적는다. CHECKPOINT 1을 FINAL PASS로 올리지 않는다. 실기기 1 kHz가 남았다.

- [ ] **Step 3: 실기기 체크리스트 (사람이 수행)**

앱만 재빌드. 드라이버 재설치 없음.

1. Work Mode ON, Auto Answer는 기존과 동일
2. 실통화 Active, 로그에 `state=running`, Realtime provider 연결 로그 없음
3. Send 1 kHz Test Tone 한 번
4. 상대 폰에서 1초 삐가 끊기지 않으면 PASS
5. 로그: `test-tone queued` → `test-tone started` → `test-tone completed`
6. 끊거나 Work Mode OFF: `realtime` disconnect는 Null이라 로그가 없어도 된다. 기존처럼 `stop started` → `inject stopped` → `capture stopped` → route restore

실패 시 Task 2–3만 본다.

- [ ] **Step 4: 실기기 PASS 후 (이 세션이 아님)**

리포트 헤더를 `CHECKPOINT 1: FINAL PASS`로 바꾸고 CHECKPOINT 2는 사용자 승인 전까지 BLOCKED로 둔다. 에이전트가 자동으로 OpenAI에 들어가지 않는다.

---

## Self-review

스펙 대비:

| 스펙 | 태스크 |
|---|---|
| TX 링 + IOProc 소비 | 2 |
| 1 kHz 생산자, completed는 소비 후 | 3 (로그는 기존 metrics) |
| 변환기 | 4 |
| adapter + mock | 5 |
| Null 세션, connect after PCM, disconnect before stop | 6 |
| Realtime 실패로 route 롤백 금지 | 5 + 6 |
| UI 변경 없음 | file map |
| 드라이버/OpenAI/VAD 없음 | 전 태스크 |
| 실기기 1 kHz | 7 |
| Phase 3 COMPLETE 문서 | 1 |

잠긴 이름: `JarvisPCMRuntimeWriteTXFrames`, `JarvisPCMRuntimeClearTX`, `JARVIS_PCM_TX_RING_FRAMES`, `RealtimeAudioConverter`, `RealtimeVoiceAdapting`, `MockRealtimeVoiceAdapter`, `RealtimeVoiceSessionControlling`, `NullRealtimeVoiceSessionController`, `RealtimeVoiceSessionControllingSpy`.
