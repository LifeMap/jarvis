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
