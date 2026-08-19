import XCTest
@testable import JarvisLoopbackBuffer

/// Process-local tests of the Capture WriteMix → Bridge RX ring. Heap-backed (no shm) so CI
/// never depends on POSIX shared memory permissions.
final class CaptureRXRingTests: XCTestCase {
    private func makeRing() -> JarvisCaptureRXRing {
        JarvisCaptureRXRing(header: nil, samples: nil, mappingSize: 0, fd: -1, mapped: false, heapAllocated: false, owner: false)
    }

    func testWriteThenTapLatestIsByteIdentical() {
        var ring = makeRing()
        XCTAssertTrue(JarvisCaptureRXRingInitInMemory(&ring, 2, 64))
        defer { JarvisCaptureRXRingClose(&ring) }

        let written: [Float] = (0..<16).map { Float($0) + 0.25 }
        written.withUnsafeBufferPointer { ptr in
            JarvisCaptureRXRingWrite(&ring, ptr.baseAddress, 8)
        }

        var tapped = [Float](repeating: -1, count: 16)
        tapped.withUnsafeMutableBufferPointer { ptr in
            JarvisCaptureRXRingTapLatest(&ring, ptr.baseAddress, 8)
        }
        XCTAssertEqual(tapped, written)
    }

    func testSecondTapDoesNotDrain() {
        var ring = makeRing()
        XCTAssertTrue(JarvisCaptureRXRingInitInMemory(&ring, 2, 64))
        defer { JarvisCaptureRXRingClose(&ring) }

        let written: [Float] = [0.1, 0.2, 0.3, 0.4]
        written.withUnsafeBufferPointer { ptr in
            JarvisCaptureRXRingWrite(&ring, ptr.baseAddress, 2)
        }

        var first = [Float](repeating: 0, count: 4)
        var second = [Float](repeating: 0, count: 4)
        first.withUnsafeMutableBufferPointer { ptr in JarvisCaptureRXRingTapLatest(&ring, ptr.baseAddress, 2) }
        second.withUnsafeMutableBufferPointer { ptr in JarvisCaptureRXRingTapLatest(&ring, ptr.baseAddress, 2) }
        XCTAssertEqual(first, written)
        XCTAssertEqual(second, written)
    }

    func testUnmappedWriteIsNoOpAndTapIsSilence() {
        var ring = makeRing()
        let written: [Float] = [1, 1]
        written.withUnsafeBufferPointer { ptr in
            JarvisCaptureRXRingWrite(&ring, ptr.baseAddress, 1)
        }
        var tapped = [Float](repeating: -1, count: 2)
        tapped.withUnsafeMutableBufferPointer { ptr in
            JarvisCaptureRXRingTapLatest(&ring, ptr.baseAddress, 1)
        }
        XCTAssertEqual(tapped, [0, 0])
        XCTAssertFalse(JarvisCaptureRXRingIsMapped(&ring))
    }
}
