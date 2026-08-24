import XCTest
@testable import JarvisCallBridge

final class MissedCallCallbackDecisionTests: XCTestCase {
    private func input(
        workModeOn: Bool = true,
        autoAnswerOn: Bool = true,
        reachedActive: Bool = false,
        ringingDuration: TimeInterval = 5,
        delaySeconds: TimeInterval = 3,
        phoneNumber: String = "+821011122233"
    ) -> MissedCallCallbackInput {
        MissedCallCallbackInput(
            workModeOn: workModeOn,
            autoAnswerOn: autoAnswerOn,
            reachedActive: reachedActive,
            ringingDuration: ringingDuration,
            delaySeconds: delaySeconds,
            phoneNumber: phoneNumber
        )
    }

    func testShortRingDoesNotEnqueue() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(ringingDuration: 2, delaySeconds: 3)), .skip)
    }

    func testLongRingWithNumberEnqueues() {
        XCTAssertEqual(
            MissedCallCallbackDecision.evaluate(input(ringingDuration: 5, delaySeconds: 3)),
            .enqueue(phoneNumber: "+821011122233")
        )
    }

    func testUnknownPhoneReportsNoNumber() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(phoneNumber: "unknown")), .reportNoNumber)
    }

    func testAutoAnswerOffSkips() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(autoAnswerOn: false)), .skip)
    }

    func testWorkModeOffSkips() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(workModeOn: false)), .skip)
    }

    func testReachedActiveSkips() {
        XCTAssertEqual(MissedCallCallbackDecision.evaluate(input(reachedActive: true)), .skip)
    }

    func testAnsweringGraceAloneDoesNotSkip() {
        XCTAssertEqual(
            MissedCallCallbackDecision.evaluate(input(reachedActive: false, ringingDuration: 5, delaySeconds: 3)),
            .enqueue(phoneNumber: "+821011122233")
        )
    }
}
