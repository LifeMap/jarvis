import XCTest
@testable import JarvisCallBridge

final class AACM4AEncoderTests: XCTestCase {
    func testEncodesOneSecondOfPCM16WithoutAborting() throws {
        var pcm = [Int16](repeating: 0, count: 24_000)
        for index in pcm.indices {
            pcm[index] = Int16(sin(Double(index) * 440 * 2 * .pi / 24_000) * 8_000)
        }
        let data = try AACM4AEncoder().encodeM4A(pcm16Mono24k: pcm)
        XCTAssertGreaterThan(data.count, 16)
        XCTAssertNotNil(data.range(of: Data("ftyp".utf8)))
        XCTAssertNotNil(data.range(of: Data("moov".utf8)), "m4a must be finalized so players can open it")
    }

    func testEncodesLongCallSizedBuffer() throws {
        let pcm = [Int16](repeating: 1_200, count: 414_400)
        let data = try AACM4AEncoder().encodeM4A(pcm16Mono24k: pcm)
        XCTAssertGreaterThan(data.count, 100)
        XCTAssertNotNil(data.range(of: Data("ftyp".utf8)))
        XCTAssertNotNil(data.range(of: Data("moov".utf8)))
    }

    func testEncodesStereoWithoutAborting() throws {
        var pcm = [Int16](repeating: 0, count: 24_000 * 2)
        for frame in 0..<24_000 {
            pcm[frame * 2] = Int16(sin(Double(frame) * 440 * 2 * .pi / 24_000) * 4_000)
            pcm[frame * 2 + 1] = Int16(sin(Double(frame) * 660 * 2 * .pi / 24_000) * 4_000)
        }
        let data = try AACM4AEncoder().encodeM4A(pcm16: pcm, channels: 2)
        XCTAssertNotNil(data.range(of: Data("ftyp".utf8)))
        XCTAssertNotNil(data.range(of: Data("moov".utf8)))
    }
}
