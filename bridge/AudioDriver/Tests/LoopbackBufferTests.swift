import XCTest
@testable import JarvisLoopbackBuffer

/// Pure, CoreAudio-independent tests of the ring buffer that connects each HAL device's own
/// Output stream to its own Input stream. No coreaudiod, no installed driver, no hardware.
final class LoopbackBufferTests: XCTestCase {
    private func makeBuffer(channels: UInt32 = 2, capacityFrames: UInt32 = 480) -> JarvisLoopbackBuffer {
        var buffer = JarvisLoopbackBuffer(
            channelCount: 0, capacityFrames: 0, writeIndex: 0, readIndex: 0,
            underrunCount: 0, overrunFrameCount: 0, samples: nil
        )
        XCTAssertTrue(JarvisLoopbackBufferInit(&buffer, channels, capacityFrames))
        return buffer
    }

    override func tearDown() {
        super.tearDown()
    }

    func testWriteThenReadRoundTrips() {
        var buffer = makeBuffer()
        defer { JarvisLoopbackBufferDestroy(&buffer) }

        let frameCount = 10
        let written: [Float] = (0..<(frameCount * 2)).map { Float($0) }
        written.withUnsafeBufferPointer { ptr in
            JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, UInt32(frameCount))
        }

        var readBack = [Float](repeating: -1, count: frameCount * 2)
        readBack.withUnsafeMutableBufferPointer { ptr in
            JarvisLoopbackBufferRead(&buffer, ptr.baseAddress, UInt32(frameCount))
        }

        XCTAssertEqual(readBack, written)
        XCTAssertEqual(buffer.underrunCount, 0)
        XCTAssertEqual(buffer.overrunFrameCount, 0)
    }

    func testUnderrunFillsSilenceAndCountsIt() {
        var buffer = makeBuffer()
        defer { JarvisLoopbackBufferDestroy(&buffer) }

        // Write fewer frames than we then try to read.
        let written: [Float] = [1, 1, 2, 2] // 2 frames, 2 channels
        written.withUnsafeBufferPointer { ptr in
            JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, 2)
        }

        var readBack = [Float](repeating: -1, count: 4 * 2) // ask for 4 frames
        readBack.withUnsafeMutableBufferPointer { ptr in
            JarvisLoopbackBufferRead(&buffer, ptr.baseAddress, 4)
        }

        XCTAssertEqual(Array(readBack[0..<4]), [1, 1, 2, 2])
        XCTAssertEqual(Array(readBack[4..<8]), [0, 0, 0, 0], "missing tail must be silence, not garbage")
        XCTAssertEqual(buffer.underrunCount, 1)
    }

    func testOverrunDropsOldestFramesDeterministically() {
        var buffer = makeBuffer(channels: 1, capacityFrames: 4)
        defer { JarvisLoopbackBufferDestroy(&buffer) }

        // Write 6 frames into a 4-frame ring — the oldest 2 must be dropped.
        let written: [Float] = [1, 2, 3, 4, 5, 6]
        written.withUnsafeBufferPointer { ptr in
            JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, 6)
        }

        var readBack = [Float](repeating: -1, count: 4)
        readBack.withUnsafeMutableBufferPointer { ptr in
            JarvisLoopbackBufferRead(&buffer, ptr.baseAddress, 4)
        }

        XCTAssertEqual(readBack, [3, 4, 5, 6], "reader must resync to the newest capacityFrames after an overrun")
        XCTAssertGreaterThan(buffer.overrunFrameCount, 0)
    }

    func testResetClearsStaleAudioAndCounters() {
        var buffer = makeBuffer(channels: 1, capacityFrames: 4)
        defer { JarvisLoopbackBufferDestroy(&buffer) }

        let written: [Float] = [9, 9, 9, 9, 9, 9] // forces an overrun too
        written.withUnsafeBufferPointer { ptr in
            JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, 6)
        }
        XCTAssertGreaterThan(buffer.overrunFrameCount, 0)

        JarvisLoopbackBufferReset(&buffer)
        XCTAssertEqual(buffer.writeIndex, 0)
        XCTAssertEqual(buffer.readIndex, 0)
        XCTAssertEqual(buffer.underrunCount, 0)
        XCTAssertEqual(buffer.overrunFrameCount, 0)

        var readBack = [Float](repeating: -1, count: 4)
        readBack.withUnsafeMutableBufferPointer { ptr in
            JarvisLoopbackBufferRead(&buffer, ptr.baseAddress, 4)
        }
        XCTAssertEqual(readBack, [0, 0, 0, 0], "a fresh session after reset must never play back stale audio")
    }

    /// Capture and Inject each own a wholly separate `JarvisLoopbackBuffer` instance in the real
    /// driver (see PlugInInterface.c) — this test documents and guards that isolation contract:
    /// writing into one instance can never be observed by reading another.
    func testTwoIndependentBuffersNeverCrossContaminate() {
        var captureBuffer = makeBuffer(channels: 1, capacityFrames: 8)
        var injectBuffer = makeBuffer(channels: 1, capacityFrames: 8)
        defer {
            JarvisLoopbackBufferDestroy(&captureBuffer)
            JarvisLoopbackBufferDestroy(&injectBuffer)
        }

        let signalA: [Float] = [1, 1, 1, 1]
        let signalB: [Float] = [2, 2, 2, 2]
        signalA.withUnsafeBufferPointer { ptr in JarvisLoopbackBufferWrite(&captureBuffer, ptr.baseAddress, 4) }
        signalB.withUnsafeBufferPointer { ptr in JarvisLoopbackBufferWrite(&injectBuffer, ptr.baseAddress, 4) }

        var readCapture = [Float](repeating: -1, count: 4)
        var readInject = [Float](repeating: -1, count: 4)
        readCapture.withUnsafeMutableBufferPointer { ptr in JarvisLoopbackBufferRead(&captureBuffer, ptr.baseAddress, 4) }
        readInject.withUnsafeMutableBufferPointer { ptr in JarvisLoopbackBufferRead(&injectBuffer, ptr.baseAddress, 4) }

        XCTAssertEqual(readCapture, signalA)
        XCTAssertEqual(readInject, signalB)
        XCTAssertNotEqual(readCapture, readInject)
    }

    /// Phase 3 CHECKPOINT 2 RX investigation (§10) — `JarvisLoopbackBufferGetCounters` is what the
    /// driver's new read-only PCM diagnostics property reuses instead of duplicating a second
    /// counter set; this pins its contract directly against the buffer, independent of the driver.
    func testGetCountersReflectsWriteReadUnderrunOverrun() {
        var buffer = makeBuffer(channels: 1, capacityFrames: 4)
        defer { JarvisLoopbackBufferDestroy(&buffer) }

        var writeFrames: UInt64 = 999, readFrames: UInt64 = 999, underrun: UInt64 = 999, overrun: UInt64 = 999
        JarvisLoopbackBufferGetCounters(&buffer, &writeFrames, &readFrames, &underrun, &overrun)
        XCTAssertEqual(writeFrames, 0)
        XCTAssertEqual(readFrames, 0)
        XCTAssertEqual(underrun, 0)
        XCTAssertEqual(overrun, 0)

        // 6 frames into a 4-frame ring: triggers an overrun on write, which itself advances
        // readIndex to resync the reader to the newest capacityFrames (2 frames dropped, so
        // readIndex jumps from 0 to 2 as part of the write, before any Read call happens).
        let written: [Float] = [1, 2, 3, 4, 5, 6]
        written.withUnsafeBufferPointer { ptr in JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, 6) }
        JarvisLoopbackBufferGetCounters(&buffer, &writeFrames, &readFrames, &underrun, &overrun)
        XCTAssertEqual(writeFrames, 6, "writeIndex is a cumulative frame count, not a ring offset")
        XCTAssertEqual(readFrames, 2, "overrun handling advances readIndex on the WRITE side, before any Read call")
        XCTAssertEqual(overrun, 2)

        // Read 5 frames when only 4 are actually buffered (writeIndex 6 - readIndex 2): triggers
        // an underrun, and readIndex only advances by the 4 frames actually copied, not the 5
        // requested.
        var readBack = [Float](repeating: -1, count: 5)
        readBack.withUnsafeMutableBufferPointer { ptr in JarvisLoopbackBufferRead(&buffer, ptr.baseAddress, 5) }
        JarvisLoopbackBufferGetCounters(&buffer, &writeFrames, &readFrames, &underrun, &overrun)
        XCTAssertEqual(readFrames, 6, "readIndex only advances by frames actually copied (4), not the 5 requested")
        XCTAssertEqual(underrun, 1)
    }

    /// ReadInput on a full-duplex default-output device has two readers (Phone.app's unused
    /// duplex input + Bridge). Exclusive drain lets the first starve the second; a tap must
    /// return the same latest frames to every reader.
    func testTapLatestIsNonDestructiveAndReturnsNewestFrames() {
        var buffer = makeBuffer(channels: 1, capacityFrames: 8)
        defer { JarvisLoopbackBufferDestroy(&buffer) }

        let first: [Float] = [1, 2, 3, 4]
        first.withUnsafeBufferPointer { ptr in JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, 4) }

        var tapA = [Float](repeating: -1, count: 4)
        var tapB = [Float](repeating: -1, count: 4)
        tapA.withUnsafeMutableBufferPointer { ptr in JarvisLoopbackBufferTapLatest(&buffer, ptr.baseAddress, 4) }
        tapB.withUnsafeMutableBufferPointer { ptr in JarvisLoopbackBufferTapLatest(&buffer, ptr.baseAddress, 4) }
        XCTAssertEqual(tapA, first)
        XCTAssertEqual(tapB, first, "a second tap must not see silence just because another reader already tapped")
        XCTAssertEqual(buffer.readIndex, 0, "tap must not advance the exclusive-drain cursor")

        let second: [Float] = [5, 6, 7, 8]
        second.withUnsafeBufferPointer { ptr in JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, 4) }

        var tapNewest = [Float](repeating: -1, count: 4)
        tapNewest.withUnsafeMutableBufferPointer { ptr in JarvisLoopbackBufferTapLatest(&buffer, ptr.baseAddress, 4) }
        XCTAssertEqual(tapNewest, second, "tap of N frames after a later write of N must return the newest N")
    }

    func testTapLatestUnderrunSilencePadsTheTail() {
        var buffer = makeBuffer(channels: 1, capacityFrames: 8)
        defer { JarvisLoopbackBufferDestroy(&buffer) }

        let written: [Float] = [9, 8]
        written.withUnsafeBufferPointer { ptr in JarvisLoopbackBufferWrite(&buffer, ptr.baseAddress, 2) }

        var tapped = [Float](repeating: -1, count: 4)
        tapped.withUnsafeMutableBufferPointer { ptr in JarvisLoopbackBufferTapLatest(&buffer, ptr.baseAddress, 4) }
        XCTAssertEqual(tapped, [9, 8, 0, 0])
        XCTAssertEqual(buffer.underrunCount, 1)
        XCTAssertEqual(buffer.readIndex, 0)
    }

    func testGetCountersToleratesNilOutParameters() {
        var buffer = makeBuffer()
        defer { JarvisLoopbackBufferDestroy(&buffer) }
        // Must not crash when the caller only wants a subset of the counters.
        JarvisLoopbackBufferGetCounters(&buffer, nil, nil, nil, nil)
    }
}
