import XCTest
@testable import JarvisCallBridge

final class EndCallCandidateResolverTests: XCTestCase {
    func testSingleBannerEndCallIsHigh() {
        let resolved = EndCallCandidateResolver.resolve(from: [TestSnapshots.endCallButton()])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.confidence, .high)
    }

    func testTwoEndCallsAreMedium() {
        let resolved = EndCallCandidateResolver.resolve(from: [
            TestSnapshots.endCallButton(id: "end-1"),
            TestSnapshots.endCallButton(id: "end-2"),
        ])
        XCTAssertEqual(resolved.count, 2)
        XCTAssertTrue(resolved.allSatisfy { $0.confidence == .medium })
    }

    func testAnswerButtonIsNotAnEndCall() {
        XCTAssertTrue(EndCallCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()]).isEmpty)
    }

    func testBarePhoneAppEndIsNotACandidate() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "quit", title: "종료", description: "종료")
        XCTAssertTrue(EndCallCandidateResolver.resolve(from: [snapshot]).isEmpty)
    }
}
