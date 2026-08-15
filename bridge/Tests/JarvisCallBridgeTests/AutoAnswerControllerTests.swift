import XCTest
@testable import JarvisCallBridge

@MainActor
final class AutoAnswerControllerTests: XCTestCase {
    private func makeRingingTracker() -> CallLifecycleTracker {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        precondition(tracker.state == .ringing)
        return tracker
    }

    func testAutoAnswerDisabledNeverPresses() async {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.isEnabled = false
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    func testHighConfidenceCandidateSchedulesTimer() {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 5 // long enough that this test's synchronous check can't race the fire

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)

        XCTAssertNotNil(controller.countdownRemaining)
        XCTAssertEqual(scanner.pressCallCount, 0)
        controller.cancel(reason: "test cleanup")
    }

    func testCallEndBeforeTimerFiresCancelsWithoutPress() async {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.3

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)
        XCTAssertNotNil(controller.countdownRemaining)

        // Caller hangs up before the timer fires.
        tracker.update(hasAnyCandidate: false, evidence: .none)
        controller.evaluate(candidates: [], workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    func testWorkModeOffBeforeTimerFiresCancelsWithoutPress() async {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.3

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)

        controller.evaluate(candidates: candidates, workModeArmed: false)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    /// Tests `AutoAnswerController`'s own gate (must be exactly one `.high` candidate) directly,
    /// independent of how the resolver happens to produce a medium-confidence candidate.
    func testMediumConfidenceCandidateNeverScheduled() {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())

        let mediumCandidate = AnswerCandidate(snapshot: TestSnapshots.highConfidenceAnswerButton(), confidence: .medium, evidence: [])
        controller.evaluate(candidates: [mediumCandidate], workModeArmed: true)

        XCTAssertNil(controller.countdownRemaining)
        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    func testLowConfidenceCandidateNeverScheduled() {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.lowConfidenceButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)

        XCTAssertNil(controller.countdownRemaining)
        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    func testMultipleAmbiguousCandidatesNeverScheduled() {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())

        let candidates = AnswerCandidateResolver.resolve(from: [
            TestSnapshots.highConfidenceAnswerButton(id: "a", pid: 1),
            TestSnapshots.highConfidenceAnswerButton(id: "b", pid: 2)
        ])
        controller.evaluate(candidates: candidates, workModeArmed: true)

        XCTAssertNil(controller.countdownRemaining)
        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    func testHighConfidenceSingleCandidatePressesExactlyOnce() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()] // CHECKPOINT 3: live revalidation re-scans immediately before press
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(controller.attemptCount, 1)
    }

    /// PRD §14: repeated poll ticks re-detecting the same ringing call must never schedule more
    /// than one press for that call, before or after the first attempt.
    func testDuplicateEventsForSameCallNeverPressMoreThanOnce() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()] // CHECKPOINT 3: live revalidation re-scans immediately before press
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)
        controller.evaluate(candidates: candidates, workModeArmed: true) // duplicate tick before timer fires
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 1)

        // Call is still (nominally) ringing on the next poll tick — must not press again.
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 1)
    }

    /// PRD §17: a failed press must never be retried.
    func testPressFailureDoesNotRetry() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()] // CHECKPOINT 3: live revalidation re-scans immediately before press
        scanner.pressResult = .failed("AX error")
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(controller.lastAttemptResult, "Failed: AX error")

        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 1, "no retry after failure")
    }

    /// PRD §21: `.unknown` call state must never be pressed into.
    func testUnknownStateNeverPresses() async {
        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.markUnknown(reason: "test")
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0)
    }
}
