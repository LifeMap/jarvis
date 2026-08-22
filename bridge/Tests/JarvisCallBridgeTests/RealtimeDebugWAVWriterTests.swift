import XCTest
@testable import JarvisCallBridge

final class RealtimeDebugWAVWriterTests: XCTestCase {
    func testWritesPCM16Mono24kHeaderAndSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = RealtimeDebugWAVWriter(url: url)
        try writer.open()
        writer.append(pcm16: [0, 32767, -32768, 16])
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(data.uint16LE(at: 20), 1) // PCM
        XCTAssertEqual(data.uint16LE(at: 22), 1) // mono
        XCTAssertEqual(data.uint32LE(at: 24), 24_000)
        XCTAssertEqual(data.uint16LE(at: 34), 16)
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")
        XCTAssertEqual(data.uint32LE(at: 40), 8)
        XCTAssertEqual(data.int16LE(at: 44), 0)
        XCTAssertEqual(data.int16LE(at: 46), 32767)
        XCTAssertEqual(data.int16LE(at: 48), -32768)
        XCTAssertEqual(data.int16LE(at: 50), 16)
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }
}
