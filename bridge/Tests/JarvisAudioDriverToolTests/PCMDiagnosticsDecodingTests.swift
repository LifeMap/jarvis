import CoreAudio
import XCTest
@testable import JarvisAudioDriverTool

/// Phase 3 CHECKPOINT 2 — Rpcm / pcm-inspect stability investigation (§27/§28/§29). Exercises
/// `CoreAudioHelpers.decodePCMDiagnostics(from:)` — the ONE place the `Rpcm` CFData payload's
/// byte layout is interpreted (§27: "do not maintain two ambiguous decoding paths";
/// `getPCMDiagnostics` is a thin CoreAudio-calling wrapper around this same pure function) —
/// against synthetic `Data`, never touching real CoreAudio or a real driver.
final class PCMDiagnosticsDecodingTests: XCTestCase {
    /// Builds a valid 104-byte payload matching `JarvisPCMDeviceDiagnostics`'s verified offsets
    /// (see `CoreAudioHelpers.decodePCMDiagnostics`'s doc comment), with distinct, recognizable
    /// values in every field so a field-order/offset mistake would fail a test, not just a
    /// coincidentally-zero comparison.
    private func makeValidBytes(version: UInt32 = 1) -> Data {
        var data = Data(count: 104)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: version, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(2), toByteOffset: 4, as: UInt32.self) // ioClientCount
            raw.storeBytes(of: Int64(3639), toByteOffset: 8, as: Int64.self) // outputOperationCount
            raw.storeBytes(of: Int64(1_623_040), toByteOffset: 16, as: Int64.self) // outputFrames
            raw.storeBytes(of: Int64(3493), toByteOffset: 24, as: Int64.self) // outputNonZeroCallbacks
            raw.storeBytes(of: Float(0.16633263), toByteOffset: 32, as: Float.self) // outputPeakLinear
            raw.storeBytes(of: UInt64(1_623_040), toByteOffset: 40, as: UInt64.self) // loopbackWriteFrames
            raw.storeBytes(of: UInt64(1_576_620), toByteOffset: 48, as: UInt64.self) // loopbackReadFrames
            raw.storeBytes(of: UInt64(0), toByteOffset: 56, as: UInt64.self) // loopbackUnderrunCount
            raw.storeBytes(of: UInt64(23_340), toByteOffset: 64, as: UInt64.self) // loopbackOverrunFrameCount
            raw.storeBytes(of: Int64(1616), toByteOffset: 72, as: Int64.self) // inputOperationCount
            raw.storeBytes(of: Int64(1_553_280), toByteOffset: 80, as: Int64.self) // inputFrames
            raw.storeBytes(of: Int64(1565), toByteOffset: 88, as: Int64.self) // inputNonZeroCallbacks
            raw.storeBytes(of: Float(0.21116002), toByteOffset: 96, as: Float.self) // inputPeakLinear
        }
        return data
    }

    func testValidPayloadDecodesExactly() throws {
        let decoded = try XCTUnwrap(CoreAudioHelpers.decodePCMDiagnostics(from: makeValidBytes()))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.ioClientCount, 2)
        XCTAssertEqual(decoded.outputOperationCount, 3639)
        XCTAssertEqual(decoded.outputFrames, 1_623_040)
        XCTAssertEqual(decoded.outputNonZeroCallbacks, 3493)
        XCTAssertEqual(decoded.outputPeakLinear, 0.16633263, accuracy: 0.000001)
        XCTAssertEqual(decoded.loopbackWriteFrames, 1_623_040)
        XCTAssertEqual(decoded.loopbackReadFrames, 1_576_620)
        XCTAssertEqual(decoded.loopbackUnderrunCount, 0)
        XCTAssertEqual(decoded.loopbackOverrunFrameCount, 23_340)
        XCTAssertEqual(decoded.inputOperationCount, 1616)
        XCTAssertEqual(decoded.inputFrames, 1_553_280)
        XCTAssertEqual(decoded.inputNonZeroCallbacks, 1565)
        XCTAssertEqual(decoded.inputPeakLinear, 0.21116002, accuracy: 0.000001)
    }

    func testShortDataReturnsNil() {
        let short = makeValidBytes().prefix(103)
        XCTAssertNil(CoreAudioHelpers.decodePCMDiagnostics(from: Data(short)))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(CoreAudioHelpers.decodePCMDiagnostics(from: Data()))
    }

    /// §28 — a version mismatch must stop decoding entirely rather than reinterpreting an
    /// unknown layout's bytes as if they matched the current one.
    func testUnsupportedVersionReturnsNilRatherThanMisinterpretingLayout() {
        XCTAssertNil(CoreAudioHelpers.decodePCMDiagnostics(from: makeValidBytes(version: 2)))
        XCTAssertNil(CoreAudioHelpers.decodePCMDiagnostics(from: makeValidBytes(version: 0)))
    }

    /// Oversized payload (e.g. a future driver adds trailing fields) must still decode the
    /// fields this client's version actually knows about — forward-compatible, not brittle to
    /// exact length.
    func testOversizedPayloadStillDecodesKnownFields() throws {
        var data = makeValidBytes()
        data.append(Data(count: 16)) // pretend trailing fields from a newer driver
        let decoded = try XCTUnwrap(CoreAudioHelpers.decodePCMDiagnostics(from: data))
        XCTAssertEqual(decoded.ioClientCount, 2)
        XCTAssertEqual(decoded.inputPeakLinear, 0.21116002, accuracy: 0.000001)
    }

    func testAllZeroPayloadDecodesAsAllZeroFields() {
        let decoded = CoreAudioHelpers.decodePCMDiagnostics(from: Data(count: 104))
        // version == 0 in an all-zero buffer is itself an unsupported-version case (the real
        // driver never publishes version 0 — JarvisPCMDeviceDiagnostics.version is always set to
        // 1 before any CFDataReplaceBytes), so this must also decode to nil, not to a
        // "successfully decoded, all fields zero" snapshot.
        XCTAssertNil(decoded)
    }
}
