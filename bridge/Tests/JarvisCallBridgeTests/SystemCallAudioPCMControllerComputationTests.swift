import CoreAudio
import XCTest
import JarvisLoopbackBuffer
import JarvisPCMRealtime
@testable import JarvisCallBridge

/// Phase 3 CHECKPOINT 2 — C native IOProc real-time hardening (§38/§39/§40/§43). There is now
/// exactly one production algorithm: `JarvisPCMRealtime`'s C `JarvisPCMCaptureIOProc`/
/// `JarvisPCMInjectIOProc` (the actual `AudioDeviceIOProc`s CoreAudio invokes). These tests
/// exercise that C implementation directly — never a duplicate Swift reimplementation kept
/// alive only so old tests would pass — by constructing synthetic `AudioBufferList`s and a real
/// `JarvisPCMRuntimeContext` in memory, with no CoreAudio device involved at all (§43: "keep
/// actual device creation out of automated tests").
final class SystemCallAudioPCMControllerComputationTests: XCTestCase {
    private let channelCount = 2

    /// A dummy, unused-by-the-callback `AudioTimeStamp` — `JarvisPCMCaptureIOProc`/
    /// `JarvisPCMInjectIOProc` ignore `inNow`/`inInputTime`/`inOutputTime` entirely (`(void)` in
    /// the C source), but the parameter type is non-optional so a real pointee is still needed.
    private var dummyTimeStamp = AudioTimeStamp()

    /// Allocates a single-buffer `AudioBufferList` backed by `frameCount * channelCount` Float32
    /// samples (interleaved — matches the driver's actual advertised format). Caller must call
    /// the returned `dispose` closure exactly once.
    private func makeBufferList(frameCount: Int, initial: [Float]? = nil) -> (list: UnsafeMutablePointer<AudioBufferList>, samples: UnsafeMutablePointer<Float>, dispose: () -> Void) {
        let sampleCount = frameCount * channelCount
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        if let initial {
            precondition(initial.count == sampleCount)
            samples.initialize(from: initial, count: sampleCount)
        } else {
            samples.initialize(repeating: 0, count: sampleCount)
        }

        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        list.pointee.mNumberBuffers = 1
        list.pointee.mBuffers.mNumberChannels = UInt32(channelCount)
        list.pointee.mBuffers.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        list.pointee.mBuffers.mData = UnsafeMutableRawPointer(samples)

        return (list, samples, { samples.deallocate(); list.deallocate() })
    }

    /// Invokes the real C `JarvisPCMCaptureIOProc` exactly as CoreAudio would, against a
    /// synthetic input buffer and a fresh (also synthetic) output buffer.
    private func runCaptureIOProc(context: OpaquePointer, input: UnsafeMutablePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        withUnsafePointer(to: &dummyTimeStamp) { ts in
            _ = JarvisPCMCaptureIOProc(0, ts, UnsafePointer(input), ts, output, ts, UnsafeMutableRawPointer(context))
        }
    }

    /// Invokes the real C `JarvisPCMInjectIOProc` exactly as CoreAudio would, against a synthetic
    /// output buffer (the only one this IOProc actually uses).
    private func runInjectIOProc(context: OpaquePointer, output: UnsafeMutablePointer<AudioBufferList>) {
        withUnsafePointer(to: &dummyTimeStamp) { ts in
            var emptyInput = AudioBufferList()
            withUnsafePointer(to: &emptyInput) { inputPtr in
                _ = JarvisPCMInjectIOProc(0, ts, inputPtr, ts, output, ts, UnsafeMutableRawPointer(context))
            }
        }
    }

    private func readMetrics(_ context: OpaquePointer) -> JarvisPCMMetricsSnapshot {
        var snapshot = JarvisPCMMetricsSnapshot()
        JarvisPCMRuntimeReadMetrics(context, &snapshot)
        return snapshot
    }

    // MARK: - Control plane (§10/§11)

    func testCreateReturnsAFreshlyResetContext() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail("allocation failed") }
        defer { JarvisPCMRuntimeDestroy(ctx) }

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxFrames, 0)
        XCTAssertEqual(metrics.rxCallbacks, 0)
        XCTAssertEqual(metrics.rxMeanSquareLinear, 0)
        XCTAssertEqual(metrics.rxPeakLinear, 0)
        XCTAssertEqual(metrics.txFrames, 0)
        XCTAssertEqual(metrics.txCallbacks, 0)
        XCTAssertEqual(metrics.txUnderrunCount, 0)
        XCTAssertEqual(metrics.toneState, 0, "0 = idle")
    }

    func testResetClearsAllPreviousMetricsAndPendingRequest() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail("allocation failed") }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let (input, _, disposeIn) = makeBufferList(frameCount: 10, initial: [Float](repeating: 1.0, count: 20))
        let (output, _, disposeOut) = makeBufferList(frameCount: 10)
        runCaptureIOProc(context: ctx, input: input, output: output)
        disposeIn(); disposeOut()
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 48000))
        XCTAssertGreaterThan(readMetrics(ctx).rxFrames, 0)

        JarvisPCMRuntimeReset(ctx)

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxFrames, 0)
        XCTAssertEqual(metrics.toneState, 0, "no request from before reset may survive it")
    }

    func testAtomicsReportLockFree() {
        XCTAssertTrue(JarvisPCMRuntimeAtomicsAreLockFree(), "every atomic type this runtime relies on must be lock-free on this build target")
    }

    func testAUInputCallbackWithoutAttachedUnitIsSafe() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        let status = JarvisPCMCaptureAUInputCallback(UnsafeMutableRawPointer(ctx), &flags, &timestamp, 1, 64, nil)
        XCTAssertEqual(status, kAudioUnitErr_Uninitialized)
        XCTAssertEqual(readMetrics(ctx).rxIOProcInvocations, 1)
    }

    func testAUInputCallbackPublishesNonZeroMetricsFromAttachedRXRing() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }

        var ring = JarvisCaptureRXRing(header: nil, samples: nil, mappingSize: 0, fd: -1, mapped: false, heapAllocated: false, owner: false)
        XCTAssertTrue(JarvisCaptureRXRingInitInMemory(&ring, 2, 128))
        defer { JarvisCaptureRXRingClose(&ring) }

        let tone: [Float] = (0..<128).map { _ in Float(0.25) }
        tone.withUnsafeBufferPointer { ptr in
            JarvisCaptureRXRingWrite(&ring, ptr.baseAddress, 64)
        }
        let adopted = withUnsafeMutablePointer(to: &ring) { ptr in
            JarvisPCMRuntimeAdoptCaptureRXRing(ctx, UnsafeMutableRawPointer(ptr))
        }
        XCTAssertTrue(adopted)

        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        let status = JarvisPCMCaptureAUInputCallback(UnsafeMutableRawPointer(ctx), &flags, &timestamp, 1, 64, nil)
        XCTAssertEqual(status, noErr)

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxIOProcInvocations, 1)
        XCTAssertEqual(metrics.rxCallbacks, 1)
        XCTAssertEqual(metrics.rxFrames, 64)
        XCTAssertGreaterThan(metrics.rxPeakLinear, 0)
        XCTAssertGreaterThan(metrics.rxReadableNonZeroBufferCount, 0)
    }

    func testPublishRXFramesIngestsFallbackChunk() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let tone: [Float] = [0.5, -0.5, 0.25, -0.25]
        tone.withUnsafeBufferPointer { ptr in
            JarvisPCMRuntimePublishRXFrames(ctx, ptr.baseAddress!, 2)
        }
        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxCallbacks, 1)
        XCTAssertEqual(metrics.rxFrames, 2)
        XCTAssertGreaterThan(metrics.rxPeakLinear, 0)
    }

    // MARK: - §39: RX via the real C Capture IOProc

    func testCaptureIOProcSilentBufferProducesZeroMetrics() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let (input, _, disposeIn) = makeBufferList(frameCount: 480) // all-zero
        let (output, _, disposeOut) = makeBufferList(frameCount: 480)
        defer { disposeIn(); disposeOut() }

        runCaptureIOProc(context: ctx, input: input, output: output)

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxCallbacks, 1)
        XCTAssertEqual(metrics.rxFrames, 480)
        XCTAssertEqual(metrics.rxMeanSquareLinear, 0)
        XCTAssertEqual(metrics.rxPeakLinear, 0)
    }

    func testCaptureIOProcFullScaleSignalProducesMeanSquareAndPeakOfOne() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let frameCount = 100
        let (input, _, disposeIn) = makeBufferList(frameCount: frameCount, initial: [Float](repeating: 1.0, count: frameCount * channelCount))
        let (output, _, disposeOut) = makeBufferList(frameCount: frameCount)
        defer { disposeIn(); disposeOut() }

        runCaptureIOProc(context: ctx, input: input, output: output)

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxMeanSquareLinear, 1.0, accuracy: 0.0001, "a constant full-scale signal has mean-square exactly 1.0")
        XCTAssertEqual(metrics.rxPeakLinear, 1.0, accuracy: 0.0001)
    }

    func testCaptureIOProcAccumulatesFrameAndCallbackCountsAcrossMultipleInvocations() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        for _ in 0..<3 {
            let (input, _, disposeIn) = makeBufferList(frameCount: 10)
            let (output, _, disposeOut) = makeBufferList(frameCount: 10)
            runCaptureIOProc(context: ctx, input: input, output: output)
            disposeIn(); disposeOut()
        }
        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxCallbacks, 3)
        XCTAssertEqual(metrics.rxFrames, 30)
    }

    /// Phase 3 CHECKPOINT 2 RX-metrics investigation (§13) — every other test in this file
    /// allocates `inInputData`/`outOutputData` as two independently-allocated buffers (via two
    /// separate `makeBufferList` calls), which is exactly why none of them could have caught a
    /// buffer-order bug: CoreAudio's own documented contract for a single-callback full-duplex
    /// device does not guarantee those two `AudioBufferList`s never share underlying memory for a
    /// device whose Input and Output streams have identical format/byte size (both are here:
    /// 48kHz Float32 stereo on both sides). This test deliberately aliases them — one buffer,
    /// referenced by BOTH `inInputData` and `outOutputData` — with known non-zero content, and
    /// proves RX metrics reflect that content. If `JarvisPCMCaptureIOProc` ever zeroes
    /// `outOutputData` before finishing reading `inInputData`, this is exactly the test that
    /// would silently see all-zero RX metrics despite real, non-zero caller audio having been
    /// present in the shared buffer — the precise real-device symptom under investigation.
    func testCaptureIOProcReadsInputBeforeAnyPossibleAliasedOutputZeroing() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }

        let frameCount = 64
        let sampleCount = frameCount * channelCount
        let sharedSamples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { sharedSamples.deallocate() }
        let knownSignal: [Float] = (0..<sampleCount).map { 0.2 + Float($0) * 0.0001 }
        sharedSamples.initialize(from: knownSignal, count: sampleCount)

        var inputList = AudioBufferList()
        inputList.mNumberBuffers = 1
        inputList.mBuffers.mNumberChannels = UInt32(channelCount)
        inputList.mBuffers.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        inputList.mBuffers.mData = UnsafeMutableRawPointer(sharedSamples)

        var outputList = AudioBufferList()
        outputList.mNumberBuffers = 1
        outputList.mBuffers.mNumberChannels = UInt32(channelCount)
        outputList.mBuffers.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        outputList.mBuffers.mData = UnsafeMutableRawPointer(sharedSamples) // SAME memory as input, on purpose

        withUnsafePointer(to: &dummyTimeStamp) { ts in
            withUnsafePointer(to: &inputList) { inputPtr in
                withUnsafeMutablePointer(to: &outputList) { outputPtr in
                    _ = JarvisPCMCaptureIOProc(0, ts, inputPtr, ts, outputPtr, ts, UnsafeMutableRawPointer(ctx))
                }
            }
        }

        let metrics = readMetrics(ctx)
        XCTAssertGreaterThan(metrics.rxPeakLinear, 0, "RX peak must reflect the real input signal, not a zeroed-before-read aliased output buffer")
        XCTAssertGreaterThan(metrics.rxMeanSquareLinear, 0, "RX mean-square must reflect the real input signal")
    }

    /// Allocates an `AudioBufferList` sized for `entries.count` `AudioBuffer`s (real CoreAudio
    /// devices with >1 stream get an `AudioBufferList` allocated the same way — `mBuffers` is a
    /// C "array of 1" flexible-array-member idiom, so a real multi-buffer list needs extra bytes
    /// past `sizeof(AudioBufferList)`, located via `MemoryLayout.offset(of:)` rather than a
    /// hand-computed offset). Used only by the multi-buffer NULL/non-NULL mix test below.
    private func makeMultiBufferInputList(entries: [(data: UnsafeMutableRawPointer?, byteSize: UInt32, channels: UInt32)]) -> (list: UnsafeMutablePointer<AudioBufferList>, dispose: () -> Void) {
        let mBuffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        let totalSize = mBuffersOffset + entries.count * MemoryLayout<AudioBuffer>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(entries.count)
        let bufferArray = (raw + mBuffersOffset).bindMemory(to: AudioBuffer.self, capacity: entries.count)
        for (i, entry) in entries.enumerated() {
            bufferArray[i] = AudioBuffer(mNumberChannels: entry.channels, mDataByteSize: entry.byteSize, mData: entry.data)
        }
        return (list, { raw.deallocate() })
    }

    // MARK: - §26/§27: RX IOProc stream usage / input buffer delivery investigation — callback-shape tests

    func testCaptureIOProcNullInputListDoesNotCrashAndRecordsNoFalseSignal() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let (output, _, disposeOut) = makeBufferList(frameCount: 8)
        defer { disposeOut() }

        // inInputData is imported as non-Optional (CF_ASSUME_NONNULL_BEGIN in the header), but
        // real CoreAudio's own nonnull annotations are documentation, not a runtime guarantee —
        // JarvisPCMCaptureIOProc's own `if (inInputData == NULL)` check is genuine defensive
        // code, so this test constructs an actually-null pointer of the expected (non-Optional)
        // Swift type to exercise it.
        let nullInputList = unsafeBitCast(Optional<UnsafeRawPointer>.none, to: UnsafePointer<AudioBufferList>.self)
        withUnsafePointer(to: &dummyTimeStamp) { ts in
            _ = JarvisPCMCaptureIOProc(0, ts, nullInputList, ts, output, ts, UnsafeMutableRawPointer(ctx))
        }

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxIOProcInvocations, 1, "the callback still ran")
        XCTAssertEqual(metrics.rxNullInputListCallbacks, 1)
        XCTAssertEqual(metrics.rxFrames, 0, "no false frame count from a NULL input list")
        XCTAssertEqual(metrics.rxCallbacks, 0)
        XCTAssertEqual(metrics.rxPeakLinear, 0)
    }

    func testCaptureIOProcZeroBufferCountIsHandledCorrectly() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        var inputList = AudioBufferList()
        inputList.mNumberBuffers = 0
        let (output, _, disposeOut) = makeBufferList(frameCount: 8)
        defer { disposeOut() }

        withUnsafePointer(to: &dummyTimeStamp) { ts in
            withUnsafePointer(to: &inputList) { inputPtr in
                _ = JarvisPCMCaptureIOProc(0, ts, inputPtr, ts, output, ts, UnsafeMutableRawPointer(ctx))
            }
        }

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxIOProcInvocations, 1)
        XCTAssertEqual(metrics.rxNullInputListCallbacks, 0, "the list itself was non-NULL")
        XCTAssertEqual(metrics.rxZeroBufferCountCallbacks, 1)
        XCTAssertEqual(metrics.rxInputBufferCountLast, 0)
        XCTAssertEqual(metrics.rxFrames, 0)
    }

    func testCaptureIOProcNullDataWithNonZeroByteSizeProducesTruthfulDiagnosticsNoFabricatedSignal() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        var inputList = AudioBufferList()
        inputList.mNumberBuffers = 1
        inputList.mBuffers.mNumberChannels = UInt32(channelCount)
        inputList.mBuffers.mDataByteSize = UInt32(64 * channelCount * MemoryLayout<Float>.size) // claims real data...
        inputList.mBuffers.mData = nil // ...but the pointer is NULL - malformed/unreadable
        let (output, _, disposeOut) = makeBufferList(frameCount: 8)
        defer { disposeOut() }

        withUnsafePointer(to: &dummyTimeStamp) { ts in
            withUnsafePointer(to: &inputList) { inputPtr in
                _ = JarvisPCMCaptureIOProc(0, ts, inputPtr, ts, output, ts, UnsafeMutableRawPointer(ctx))
            }
        }

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxInputBufferCountLast, 1, "the buffer was seen, just not readable")
        XCTAssertEqual(metrics.rxNullDataBufferCount, 1)
        XCTAssertEqual(metrics.rxReadableDataBufferCount, 0, "must never be counted as readable when mData is NULL")
        XCTAssertEqual(metrics.rxFrames, 0, "no fabricated frames/samples from an unreadable buffer")
        XCTAssertEqual(metrics.rxCallbacks, 0)
    }

    func testCaptureIOProcReadableAllZeroBufferIsCountedReadableButNotNonZero() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let (input, _, disposeIn) = makeBufferList(frameCount: 32) // all-zero, but genuinely readable
        let (output, _, disposeOut) = makeBufferList(frameCount: 32)
        defer { disposeIn(); disposeOut() }

        runCaptureIOProc(context: ctx, input: input, output: output)

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxReadableDataBufferCount, 1, "a genuinely delivered buffer, even all-zero, is readable")
        XCTAssertEqual(metrics.rxReadableNonZeroBufferCount, 0)
        XCTAssertEqual(metrics.rxNullDataBufferCount, 0)
    }

    func testCaptureIOProcReadableNonZeroBufferIncrementsBothReadableAndNonZeroCounts() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let frameCount = 32
        let (input, _, disposeIn) = makeBufferList(frameCount: frameCount, initial: [Float](repeating: 0.7, count: frameCount * channelCount))
        let (output, _, disposeOut) = makeBufferList(frameCount: frameCount)
        defer { disposeIn(); disposeOut() }

        runCaptureIOProc(context: ctx, input: input, output: output)

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxReadableDataBufferCount, 1)
        XCTAssertEqual(metrics.rxReadableNonZeroBufferCount, 1)
        XCTAssertGreaterThan(metrics.rxPeakLinear, 0)
    }

    func testCaptureIOProcMultipleBuffersOneNullOneNonZeroStillDetectsSignal() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }

        let frameCount = 8
        let sampleCount = frameCount * channelCount
        let nonZeroSamples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        nonZeroSamples.initialize(repeating: 0.4, count: sampleCount)
        defer { nonZeroSamples.deallocate() }
        let byteSize = UInt32(sampleCount * MemoryLayout<Float>.size)

        let (inputList, disposeIn) = makeMultiBufferInputList(entries: [
            (data: nil, byteSize: byteSize, channels: UInt32(channelCount)),
            (data: UnsafeMutableRawPointer(nonZeroSamples), byteSize: byteSize, channels: UInt32(channelCount)),
        ])
        defer { disposeIn() }
        let (output, _, disposeOut) = makeBufferList(frameCount: frameCount)
        defer { disposeOut() }

        withUnsafePointer(to: &dummyTimeStamp) { ts in
            _ = JarvisPCMCaptureIOProc(0, ts, UnsafePointer(inputList), ts, output, ts, UnsafeMutableRawPointer(ctx))
        }

        let metrics = readMetrics(ctx)
        XCTAssertEqual(metrics.rxInputBufferCountLast, 2)
        XCTAssertEqual(metrics.rxNullDataBufferCount, 1, "the NULL buffer must be counted, not silently ignored")
        XCTAssertEqual(metrics.rxReadableDataBufferCount, 1, "only the real buffer is readable")
        XCTAssertEqual(metrics.rxReadableNonZeroBufferCount, 1)
        XCTAssertEqual(metrics.rxPeakLinear, 0.4, accuracy: 0.0001, "signal from the valid buffer must still be detected despite the other buffer being NULL")
    }

    func testCaptureIOProcZeroesItsOwnOutputBuffer() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let (input, _, disposeIn) = makeBufferList(frameCount: 4)
        let (output, outputSamples, disposeOut) = makeBufferList(frameCount: 4, initial: [Float](repeating: 1, count: 8)) // stale
        defer { disposeIn(); disposeOut() }

        runCaptureIOProc(context: ctx, input: input, output: output)

        for i in 0..<8 { XCTAssertEqual(outputSamples[i], 0, "Capture's own OUTPUT side is not ours to fill; must never hold stale memory") }
    }

    /// Phase 3 CHECKPOINT 2 RX-metrics investigation (§28/§29) — atomic float bit-pattern
    /// round-trip through the REAL production path (`JarvisPCMCaptureIOProc` → `RecordRX`'s
    /// `memcpy`-based bit-preserving store → `JarvisPCMRuntimeReadMetrics`'s matching
    /// `memcpy`-based load), using the exact real-device peak values this investigation is about
    /// (0.16633263 = Capture OUTPUT peak, 0.21116002 = Capture INPUT peak from the user's
    /// `pcm-inspect` output) plus standard reference amplitudes. `JarvisPCMMetricsSnapshot` is
    /// Swift's direct ClangImporter-imported view of the same C struct `JarvisPCMRealtime.h`
    /// declares (no hand-mirrored Swift struct anywhere in this in-process path, unlike
    /// `JarvisAudioDriverTool`'s necessarily-separate-process CFData decoding) — so there is no
    /// ABI/layout class of bug possible here; this test exists to prove that FACT empirically,
    /// not just assert it in a comment.
    func testAtomicFloatBitPatternRoundTripsExactlyForRealDeviceObservedAmplitudes() {
        for amplitude: Float in [0.1, 0.16633263, 0.21116002, 0.5, 1.0] {
            guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
            defer { JarvisPCMRuntimeDestroy(ctx) }
            let frameCount = 32
            let (input, _, disposeIn) = makeBufferList(frameCount: frameCount, initial: [Float](repeating: amplitude, count: frameCount * channelCount))
            let (output, _, disposeOut) = makeBufferList(frameCount: frameCount)
            defer { disposeIn(); disposeOut() }

            runCaptureIOProc(context: ctx, input: input, output: output)

            let metrics = readMetrics(ctx)
            XCTAssertEqual(metrics.rxPeakLinear, amplitude, accuracy: 0.000001, "peak must round-trip bit-exact (within Float precision) through the atomic bit-pattern store/load, amplitude=\(amplitude)")
            XCTAssertEqual(metrics.rxMeanSquareLinear, amplitude * amplitude, accuracy: 0.000001, "mean-square of a constant-amplitude signal is amplitude^2, amplitude=\(amplitude)")
        }
    }

    /// Phase 3 CHECKPOINT 2 RX-metrics investigation (§25/§26) — production end-to-end amplitude
    /// ladder: real `JarvisPCMCaptureIOProc` → real `JarvisPCMRuntimeReadMetrics` →
    /// `SystemCallAudioPCMController.dBFS` (the actual presentation-layer conversion, not a
    /// reimplementation), against the standard reference points.
    func testProductionRXPipelineAmplitudeToDBFSLadder() {
        let cases: [(amplitude: Float, expectedDBFS: Float)] = [
            (1.0, 0.0),
            (0.5, -6.0206),
            (0.25, -12.0412),
            (0.1, -20.0),
        ]
        for (amplitude, expectedDBFS) in cases {
            guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
            defer { JarvisPCMRuntimeDestroy(ctx) }
            let frameCount = 32
            let (input, _, disposeIn) = makeBufferList(frameCount: frameCount, initial: [Float](repeating: amplitude, count: frameCount * channelCount))
            let (output, _, disposeOut) = makeBufferList(frameCount: frameCount)
            defer { disposeIn(); disposeOut() }

            runCaptureIOProc(context: ctx, input: input, output: output)

            let metrics = readMetrics(ctx)
            let rmsLinear = sqrt(Double(metrics.rxMeanSquareLinear))
            let rmsDBFS = SystemCallAudioPCMController.dBFS(Float(rmsLinear))
            let peakDBFS = SystemCallAudioPCMController.dBFS(metrics.rxPeakLinear)
            XCTAssertEqual(rmsDBFS, expectedDBFS, accuracy: 0.1, "constant-amplitude \(amplitude) RMS dBFS")
            XCTAssertEqual(peakDBFS, expectedDBFS, accuracy: 0.1, "constant-amplitude \(amplitude) peak dBFS")
        }
    }

    func testProductionRXPipelineSilenceReportsFloor() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let (input, _, disposeIn) = makeBufferList(frameCount: 32) // all-zero
        let (output, _, disposeOut) = makeBufferList(frameCount: 32)
        defer { disposeIn(); disposeOut() }

        runCaptureIOProc(context: ctx, input: input, output: output)

        let metrics = readMetrics(ctx)
        let rmsDBFS = SystemCallAudioPCMController.dBFS(Float(sqrt(Double(metrics.rxMeanSquareLinear))))
        let peakDBFS = SystemCallAudioPCMController.dBFS(metrics.rxPeakLinear)
        XCTAssertEqual(rmsDBFS, CallAudioPCMMetrics.silenceFloorDBFS)
        XCTAssertEqual(peakDBFS, CallAudioPCMMetrics.silenceFloorDBFS)
    }

    /// Phase 3 CHECKPOINT 2 RX-metrics investigation (§27) — the published snapshot represents
    /// the MOST RECENT callback's peak/mean-square (documented, intentional design — see
    /// `JarvisPCMRealtime.h`'s `JarvisPCMMetricsSnapshot` doc comment), not a running max and not
    /// permanently stuck at the first-ever value. Feeds silence → signal → silence and confirms
    /// each transition is visible, so a real call's silence-then-speech-then-silence pattern is
    /// correctly represented rather than latched to whatever the first callback happened to be.
    func testMultiCallbackSilenceSignalSilenceTransitionsAreAllReflected() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let frameCount = 16

        let (silentIn1, _, disposeSilentIn1) = makeBufferList(frameCount: frameCount)
        let (silentOut1, _, disposeSilentOut1) = makeBufferList(frameCount: frameCount)
        runCaptureIOProc(context: ctx, input: silentIn1, output: silentOut1)
        disposeSilentIn1(); disposeSilentOut1()
        XCTAssertEqual(readMetrics(ctx).rxPeakLinear, 0, "callback 1 (silence)")

        let (signalIn, _, disposeSignalIn) = makeBufferList(frameCount: frameCount, initial: [Float](repeating: 0.6, count: frameCount * channelCount))
        let (signalOut, _, disposeSignalOut) = makeBufferList(frameCount: frameCount)
        runCaptureIOProc(context: ctx, input: signalIn, output: signalOut)
        disposeSignalIn(); disposeSignalOut()
        XCTAssertEqual(readMetrics(ctx).rxPeakLinear, 0.6, accuracy: 0.0001, "callback 2 (signal) must be visible, not stuck at callback 1's silence")

        let (signalIn2, _, disposeSignalIn2) = makeBufferList(frameCount: frameCount, initial: [Float](repeating: 0.3, count: frameCount * channelCount))
        let (signalOut2, _, disposeSignalOut2) = makeBufferList(frameCount: frameCount)
        runCaptureIOProc(context: ctx, input: signalIn2, output: signalOut2)
        disposeSignalIn2(); disposeSignalOut2()
        XCTAssertEqual(readMetrics(ctx).rxPeakLinear, 0.3, accuracy: 0.0001, "callback 3 (different amplitude) must update, not stick at callback 2's value")

        let (silentIn2, _, disposeSilentIn2) = makeBufferList(frameCount: frameCount)
        let (silentOut2, _, disposeSilentOut2) = makeBufferList(frameCount: frameCount)
        runCaptureIOProc(context: ctx, input: silentIn2, output: silentOut2)
        disposeSilentIn2(); disposeSilentOut2()
        XCTAssertEqual(readMetrics(ctx).rxPeakLinear, 0, "callback 4 (silence again) must return toward floor, not stay latched at callback 3's signal")

        // Frame/callback counters, unlike peak/mean-square, are cumulative across all 4 callbacks.
        XCTAssertEqual(readMetrics(ctx).rxCallbacks, 4)
        XCTAssertEqual(readMetrics(ctx).rxFrames, Int64(frameCount * 4))
    }

    // MARK: - §40: TX via the real C Inject IOProc

    func testInjectIOProcWithNoQueuedToneWritesAllZeroSilence() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let (output, samples, disposeOut) = makeBufferList(frameCount: 100, initial: [Float](repeating: 0.5, count: 200))
        defer { disposeOut() }

        runInjectIOProc(context: ctx, output: output)

        for i in 0..<200 { XCTAssertEqual(samples[i], 0) }
        XCTAssertEqual(readMetrics(ctx).txFrames, 100)
        XCTAssertEqual(readMetrics(ctx).txUnderrunCount, 0)
    }

    func testRequestToneFromIdleSucceedsExactlyOnce() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 48000))
        XCTAssertEqual(readMetrics(ctx).toneState, 1, "1 = queued")
    }

    func testSecondRequestWhileQueuedIsRejected() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 48000))
        XCTAssertFalse(JarvisPCMRuntimeRequestTone(ctx, 48000))
    }

    func testSecondRequestWhilePlayingIsRejected() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 48000))
        let (output, _, disposeOut) = makeBufferList(frameCount: 10) // one callback claims Queued -> Playing
        runInjectIOProc(context: ctx, output: output)
        disposeOut()
        XCTAssertEqual(readMetrics(ctx).toneState, 2, "2 = playing")

        XCTAssertFalse(JarvisPCMRuntimeRequestTone(ctx, 48000))
    }

    func testInjectIOProcTransitionsQueuedToPlayingOnFirstConsumption() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 48000))
        let (output, _, disposeOut) = makeBufferList(frameCount: 10)
        defer { disposeOut() }

        runInjectIOProc(context: ctx, output: output)

        XCTAssertEqual(readMetrics(ctx).toneState, 2)
    }

    func testInjectIOProcWritesExactDeterministicSineAtConfiguredFrequencyAndAmplitude() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 480))
        let (output, samples, disposeOut) = makeBufferList(frameCount: 480)
        defer { disposeOut() }

        runInjectIOProc(context: ctx, output: output)

        let sampleRate = 48000.0
        let frequencyHz = 1000.0
        let amplitude: Float = 0.1
        for frame in 0..<480 {
            let expected = Float(sin(2 * Double.pi * frequencyHz * Double(frame) / sampleRate)) * amplitude
            XCTAssertEqual(samples[frame * channelCount + 0], expected, accuracy: 0.0001, "channel 0 frame \(frame)")
            XCTAssertEqual(samples[frame * channelCount + 1], expected, accuracy: 0.0001, "stereo — same signal on both channels, frame \(frame)")
        }
    }

    func testInjectIOProcTonePhaseIsContinuousAcrossMultipleInvocations() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 200))

        let (output1, _, disposeOut1) = makeBufferList(frameCount: 100)
        runInjectIOProc(context: ctx, output: output1)
        disposeOut1()

        let (output2, samples2, disposeOut2) = makeBufferList(frameCount: 100)
        defer { disposeOut2() }
        runInjectIOProc(context: ctx, output: output2)

        // Frame 100 (first frame of the second callback) must continue the phase exactly where
        // frame 99 (last frame of the first callback) left off — no reset-to-zero-phase glitch.
        let expectedFrame100 = Float(sin(2 * Double.pi * 1000.0 * 100.0 / 48000.0)) * 0.1
        XCTAssertEqual(samples2[0], expectedFrame100, accuracy: 0.0001)
    }

    func testInjectIOProcCompletionTransitionsPlayingToIdleAndSilencesRemainder() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 30)) // fewer frames than the callback will request
        let (output, samples, disposeOut) = makeBufferList(frameCount: 100, initial: [Float](repeating: 0.9, count: 200))
        defer { disposeOut() }

        runInjectIOProc(context: ctx, output: output)

        for frame in 30..<100 {
            XCTAssertEqual(samples[frame * channelCount + 0], 0, "frame \(frame) must be silence after the tone ran out")
            XCTAssertEqual(samples[frame * channelCount + 1], 0)
        }
        XCTAssertEqual(readMetrics(ctx).toneState, 0, "0 = idle — must have marked itself complete")
    }

    func testStaleRequestCannotReplayOnALaterInvocationAfterCompletion() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        XCTAssertTrue(JarvisPCMRuntimeRequestTone(ctx, 5))
        let (output1, _, disposeOut1) = makeBufferList(frameCount: 5)
        runInjectIOProc(context: ctx, output: output1)
        disposeOut1()
        XCTAssertEqual(readMetrics(ctx).toneState, 0)

        // §9/§21 — nothing re-queued a request; a later invocation must produce pure silence,
        // never replay the completed tone.
        let (output2, samples2, disposeOut2) = makeBufferList(frameCount: 10, initial: [Float](repeating: 0.7, count: 20))
        defer { disposeOut2() }
        runInjectIOProc(context: ctx, output: output2)
        for i in 0..<20 { XCTAssertEqual(samples2[i], 0) }
    }

    func testInjectIOProcMalformedBufferRecordsUnderrunNotCrash() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { list.deallocate() }
        list.pointee.mNumberBuffers = 1
        list.pointee.mBuffers.mNumberChannels = UInt32(channelCount)
        list.pointee.mBuffers.mDataByteSize = 0
        list.pointee.mBuffers.mData = nil // malformed — nothing to write into

        runInjectIOProc(context: ctx, output: list)

        XCTAssertEqual(readMetrics(ctx).txUnderrunCount, 1)
    }

    // MARK: - §41: concurrency correctness of the one real cross-thread primitive — the
    // idle->queued compare-exchange. Fully deterministic (no sleeps): many concurrent requesters
    // race the same context, and the CAS's own atomicity guarantees at most one can ever win.

    func testConcurrentToneRequestsExactlyOneWinnerNoDeadlockNoCrash() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let runtime = SendableRuntimeHandle(ctx)
        let winCount = ManagedCounter()
        let iterations = 200

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            if JarvisPCMRuntimeRequestTone(runtime.pointer, 48000) {
                winCount.increment()
            }
        }

        XCTAssertEqual(winCount.value, 1, "the compare-exchange must guarantee exactly one winner even under real concurrent contention")
        XCTAssertEqual(readMetrics(ctx).toneState, 1)
    }

    /// Genuinely concurrent (not just interleaved-by-scheduling) writer/reader stress against the
    /// C runtime's atomics — the whole point of this test is real cross-thread contention, so the
    /// runtime pointer and the pure buffer-construction helper are both wrapped/copied in ways
    /// that don't require capturing `self` (an `XCTestCase`, not `Sendable`) into `@Sendable`
    /// closures.
    func testMetricsReadsWhileSyntheticCallbacksUpdateDoNotDeadlock() {
        guard let ctx = JarvisPCMRuntimeCreate() else { return XCTFail() }
        defer { JarvisPCMRuntimeDestroy(ctx) }
        let runtime = SendableRuntimeHandle(ctx)
        let channels = channelCount
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            var timeStamp = AudioTimeStamp()
            for _ in 0..<200 {
                let sampleCount = 16 * channels
                let inputSamples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
                inputSamples.initialize(repeating: 0, count: sampleCount)
                let inputList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
                inputList.pointee.mNumberBuffers = 1
                inputList.pointee.mBuffers.mNumberChannels = UInt32(channels)
                inputList.pointee.mBuffers.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
                inputList.pointee.mBuffers.mData = UnsafeMutableRawPointer(inputSamples)

                let outputSamples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
                outputSamples.initialize(repeating: 0, count: sampleCount)
                let outputList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
                outputList.pointee.mNumberBuffers = 1
                outputList.pointee.mBuffers.mNumberChannels = UInt32(channels)
                outputList.pointee.mBuffers.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
                outputList.pointee.mBuffers.mData = UnsafeMutableRawPointer(outputSamples)

                withUnsafePointer(to: &timeStamp) { ts in
                    _ = JarvisPCMCaptureIOProc(0, ts, UnsafePointer(inputList), ts, outputList, ts, UnsafeMutableRawPointer(runtime.pointer))
                }
                inputSamples.deallocate(); inputList.deallocate()
                outputSamples.deallocate(); outputList.deallocate()
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            var snapshot = JarvisPCMMetricsSnapshot()
            for _ in 0..<200 {
                JarvisPCMRuntimeReadMetrics(runtime.pointer, &snapshot)
            }
            group.leave()
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "metrics reads racing real-time-style writes must never deadlock")
    }

    // MARK: - Format (§48)

    func testExpectedFormatMatchesPhase1DriverContract() {
        let expected = CallAudioPCMFormat.expected
        XCTAssertEqual(expected.sampleRate, 48000)
        XCTAssertEqual(expected.channelCount, 2)
        XCTAssertEqual(expected.bytesPerFrame, 8)
        XCTAssertTrue(expected.isFloat)
        XCTAssertTrue(expected.isInterleaved)
    }

    func testWrongSampleRateIsNotEqualToExpectedFormat() {
        let wrong = CallAudioPCMFormat(sampleRate: 44100, channelCount: 2, bytesPerFrame: 8, isFloat: true, isInterleaved: true)
        XCTAssertNotEqual(wrong, .expected)
    }

    func testWrongChannelCountIsNotEqualToExpectedFormat() {
        let wrong = CallAudioPCMFormat(sampleRate: 48000, channelCount: 1, bytesPerFrame: 4, isFloat: true, isInterleaved: true)
        XCTAssertNotEqual(wrong, .expected)
    }

    func testNonFloatSampleTypeIsNotEqualToExpectedFormat() {
        let wrong = CallAudioPCMFormat(sampleRate: 48000, channelCount: 2, bytesPerFrame: 8, isFloat: false, isInterleaved: true)
        XCTAssertNotEqual(wrong, .expected)
    }

    func testNonInterleavedIsNotEqualToExpectedFormat() {
        let wrong = CallAudioPCMFormat(sampleRate: 48000, channelCount: 2, bytesPerFrame: 8, isFloat: true, isInterleaved: false)
        XCTAssertNotEqual(wrong, .expected)
    }

    // MARK: - dBFS conversion (§16 — now exercised only as a non-real-time, presentation-layer
    // Swift helper; the C runtime itself never computes dBFS)

    func testDBFSFullScaleIsZero() {
        XCTAssertEqual(SystemCallAudioPCMController.dBFS(1.0), 0, accuracy: 0.01)
    }

    func testDBFSSilenceClampsToFloor() {
        XCTAssertEqual(SystemCallAudioPCMController.dBFS(0), CallAudioPCMMetrics.silenceFloorDBFS)
    }

    func testDBFSKnownAmplitudeMatchesExpectedDecibels() {
        XCTAssertEqual(SystemCallAudioPCMController.dBFS(0.1), -20, accuracy: 0.1)
    }
}

/// `OpaquePointer` isn't `Sendable` by default (it carries no compiler-provable thread-safety
/// guarantee for arbitrary pointees) — this wrapper documents that, for `JarvisPCMRuntimeContext`
/// specifically, every operation reachable through it is one of this test file's own C runtime
/// functions, each of which is internally lock-free/atomic-safe for concurrent access by design
/// (that safety is exactly what these stress tests exist to exercise).
private struct SendableRuntimeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// Plain lock-protected counter for the stress tests' OWN bookkeeping only (never on any
/// callback-reachable path) — just needs to count how many of the concurrent attempts above
/// returned `true`, which is not itself real-time code.
private final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
