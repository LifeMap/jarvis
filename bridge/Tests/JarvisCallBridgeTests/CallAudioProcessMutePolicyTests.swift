import XCTest
@testable import JarvisCallBridge

final class CallAudioProcessMutePolicyTests: XCTestCase {
    func testSanitizedDropsCoreAudioDaemons() {
        let input = [
            "com.apple.avconferenced",
            "com.apple.mediaserverd",
            "com.apple.audio.coreaudiod",
            "com.apple.coreaudiod",
        ]
        XCTAssertEqual(CallAudioProcessMutePolicy.sanitized(input), ["com.apple.avconferenced"])
    }
}
