import CoreAudio
import XCTest
@testable import JarvisCallBridge

/// Phase 3 CHECKPOINT 2 — RX IOProc Stream Usage / Input Buffer Delivery investigation (§28).
/// Exercises `IOProcStreamUsageReader.parse(rawBytes:)` — the pure, CoreAudio-independent half of
/// the stream-usage diagnostic — against synthetic byte buffers shaped like a real
/// `AudioHardwareIOProcStreamUsage` payload. `query(deviceID:procID:scope:)`, the half that
/// actually calls `AudioObjectGetPropertyData` against a real device, is intentionally NOT
/// exercised here (would require a real installed driver + live IOProcID; automated tests must
/// never mutate/query the real macOS device route per project convention — see
/// `CoreAudioIOProcStreamUsageDiagnostics.swift`'s own doc comment).
final class IOProcStreamUsageDiagnosticsTests: XCTestCase {
    /// Builds a raw byte buffer shaped like `mIOProc` (pointerSize bytes, content irrelevant to
    /// parsing) + `mNumberStreams` (UInt32) + `mNumberStreams` × UInt32 `mStreamIsOn` values.
    private func makeRawBytes(pointerSize: Int = 8, streamValues: [UInt32]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xAA, count: pointerSize) // mIOProc placeholder
        withUnsafeBytes(of: UInt32(streamValues.count)) { bytes.append(contentsOf: $0) }
        for value in streamValues {
            withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    func testAllStreamsEnabled() {
        let bytes = makeRawBytes(streamValues: [1, 1])
        let snapshot = IOProcStreamUsageReader.parse(rawBytes: bytes)
        XCTAssertEqual(snapshot, .init(streamCount: 2, enabled: [true, true]))
    }

    func testAllStreamsDisabled() {
        let bytes = makeRawBytes(streamValues: [0, 0])
        let snapshot = IOProcStreamUsageReader.parse(rawBytes: bytes)
        XCTAssertEqual(snapshot, .init(streamCount: 2, enabled: [false, false]))
    }

    func testMixedUsage() {
        let bytes = makeRawBytes(streamValues: [1, 0, 1])
        let snapshot = IOProcStreamUsageReader.parse(rawBytes: bytes)
        XCTAssertEqual(snapshot, .init(streamCount: 3, enabled: [true, false, true]))
    }

    /// Any non-zero value means "enabled" per the SDK's own doc comment ("Any other value means
    /// the stream is to be used") — not just literal 1.
    func testNonOneNonZeroValueCountsAsEnabled() {
        let bytes = makeRawBytes(streamValues: [42])
        let snapshot = IOProcStreamUsageReader.parse(rawBytes: bytes)
        XCTAssertEqual(snapshot, .init(streamCount: 1, enabled: [true]))
    }

    func testZeroStreams() {
        let bytes = makeRawBytes(streamValues: [])
        let snapshot = IOProcStreamUsageReader.parse(rawBytes: bytes)
        XCTAssertEqual(snapshot, .init(streamCount: 0, enabled: []))
    }

    func testSingleStreamCountHandledCorrectly() {
        // The real Jarvis driver exposes exactly one stream per direction (Capture: 1 input + 1
        // output; Inject: 1 output + 1 input) - the expected common case, verified explicitly
        // rather than only via the multi-stream cases above (§19 - "do not assume exactly one
        // stream... enumerate/derive actual counts", proven by exercising 0/1/2/3 all correctly).
        let bytes = makeRawBytes(streamValues: [1])
        let snapshot = IOProcStreamUsageReader.parse(rawBytes: bytes)
        XCTAssertEqual(snapshot, .init(streamCount: 1, enabled: [true]))
    }

    func testUndersizedBufferForHeaderReturnsNil() {
        // Fewer bytes than even the mIOProc+mNumberStreams header requires.
        let bytes = [UInt8](repeating: 0, count: 4)
        XCTAssertNil(IOProcStreamUsageReader.parse(rawBytes: bytes))
    }

    func testIncorrectReturnedByteSizeForClaimedStreamCountReturnsNil() {
        // Header claims 4 streams but only 1 UInt32's worth of stream data actually follows -
        // exactly the "incorrect returned byte size" defensive case (§28).
        var bytes = [UInt8](repeating: 0, count: 8) // mIOProc
        withUnsafeBytes(of: UInt32(4)) { bytes.append(contentsOf: $0) } // claims mNumberStreams = 4
        withUnsafeBytes(of: UInt32(1)) { bytes.append(contentsOf: $0) } // but only 1 value present
        XCTAssertNil(IOProcStreamUsageReader.parse(rawBytes: bytes))
    }

    func testEmptyBufferReturnsNil() {
        XCTAssertNil(IOProcStreamUsageReader.parse(rawBytes: []))
    }

    func testDifferentPointerSizeIsHonored() {
        // parse() takes pointerSize as a parameter specifically so it isn't hard-coded to one
        // platform's pointer width; verify a smaller header offset still parses correctly.
        let bytes = makeRawBytes(pointerSize: 4, streamValues: [1, 0])
        let snapshot = IOProcStreamUsageReader.parse(rawBytes: bytes, pointerSize: 4)
        XCTAssertEqual(snapshot, .init(streamCount: 2, enabled: [true, false]))
    }

    func testEncodeRoundTripsThroughParse() {
        let encoded = IOProcStreamUsageReader.encode(enabled: [true, false, true], pointerSize: 8)
        XCTAssertEqual(IOProcStreamUsageReader.parse(rawBytes: encoded, pointerSize: 8), .init(streamCount: 3, enabled: [true, false, true]))
    }

    func testEncodeSingleDisabledStreamMatchesJarvisCaptureOutputPlan() {
        let encoded = IOProcStreamUsageReader.encode(enabled: IOProcStreamUsageReader.flags(streamCount: 1, used: false))
        XCTAssertEqual(IOProcStreamUsageReader.parse(rawBytes: encoded), .init(streamCount: 1, enabled: [false]))
    }

    func testCaptureOutputPlanDisablesEveryStream() {
        XCTAssertEqual(IOProcStreamUsageReader.flags(streamCount: 1, used: false), [false])
        XCTAssertEqual(IOProcStreamUsageReader.flags(streamCount: 2, used: false), [false, false])
        XCTAssertEqual(IOProcStreamUsageReader.flags(streamCount: 0, used: false), [])
    }

    func testCaptureInputPlanKeepsEveryStreamEnabled() {
        XCTAssertEqual(IOProcStreamUsageReader.flags(streamCount: 1, used: true), [true])
        XCTAssertEqual(IOProcStreamUsageReader.flags(streamCount: 2, used: true), [true, true])
    }
}
