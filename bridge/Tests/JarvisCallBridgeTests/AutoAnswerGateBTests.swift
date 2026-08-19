import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 3 — Gate B (Real Auto Answer) preparation. Closes the remaining gaps in unit
/// coverage for the already-implemented Auto Answer path: 3-second delay configuration, ambiguous
/// revalidation, the full manual-answer-cancels-pending-auto-answer integration, the full
/// caller-hangup-during-grace-cancels-pending-auto-answer integration, every known non-Answer
/// banner control (including "통신 오디오" and ordinary Phone.app UI), the
/// press-only-marks-answering/evidence-drives-active distinction, session-id persistence through
/// the full Auto Answer lifecycle, and old-session/newer-session isolation.
@MainActor
final class AutoAnswerGateBTests: XCTestCase {
    private func makeRingingTracker() -> CallLifecycleTracker {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        precondition(tracker.state == .ringing)
        return tracker
    }

    // §18 item 2
    func testThreeSecondDelayConfigurationSchedulesCorrectCountdown() {
        let scanner = MockAccessibilityScanning()
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 3

        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        controller.evaluate(candidates: candidates, workModeArmed: true)

        XCTAssertEqual(controller.countdownRemaining, 3)
        controller.cancel(reason: "test cleanup")
    }

    // §18 item 10
    func testMultipleCandidatesAtRevalidationCancelsPress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)

        // The banner somehow shows two simultaneous evidence-locked matches right before press.
        scanner.snapshotsToReturn = [
            TestSnapshots.highConfidenceAnswerButton(id: "answer-a", pid: 1001),
            TestSnapshots.highConfidenceAnswerButton(id: "answer-b", pid: 1002)
        ]

        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0, "ambiguous revalidation must never press")
    }

    // §18 item 16: full integration through `IncomingCallObserver`, not just the tracker in isolation.
    func testUserManuallyAnswersBeforeDelayResultsInZeroJarvisPresses() async {
        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.delaySeconds = 0.3
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        scanner.snapshotsToReturn = TestSnapshots.ringingCallBannerFixture()
        await observer.tick()
        XCTAssertEqual(tracker.state, .ringing)
        XCTAssertNotNil(autoAnswer.countdownRemaining)

        // User manually answers — the banner transforms to the real active signature before the
        // Auto Answer delay elapses.
        scanner.snapshotsToReturn = TestSnapshots.activeCallBannerFixture()
        await observer.tick()
        XCTAssertEqual(tracker.state, .active)

        await autoAnswer.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0, "Auto Answer must never press once the user has already manually answered")
    }

    // §18 item 17: caller hangs up before the delay elapses, via the real answerTransitionGrace
    // path (not evidence=.none injected directly).
    func testCallerHangsUpDuringGraceBeforeDelayResultsInZeroJarvisPresses() async {
        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 0.1, logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.delaySeconds = 0.3
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        scanner.snapshotsToReturn = TestSnapshots.ringingCallBannerFixture()
        await observer.tick()
        XCTAssertEqual(tracker.state, .ringing)

        scanner.snapshotsToReturn = [] // caller hangs up
        await observer.tick() // starts the tracker's own answerTransitionGrace
        XCTAssertEqual(tracker.state, .answering)

        try? await Task.sleep(nanoseconds: 200_000_000) // past the 0.1s grace
        await observer.tick()
        XCTAssertEqual(tracker.state, .idle)

        await autoAnswer.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    // §18 items 18-21: every known non-Answer banner control — including the "통신 오디오"
    // diagnostic hint — never receives press, even scanned alongside the real Answer control.
    func testAllKnownNonAnswerBannerElementsNeverReceivePress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = TestSnapshots.notificationCenterBannerWithoutAnswer() + [TestSnapshots.callPresenceHintElement(), TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(scanner.pressedSnapshotIDs, ["answer-1"])
    }

    // §18 item 22
    func testOrdinaryPhoneAppControlsNeverReceivePress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = TestSnapshots.noCallBaselineFixture() + [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(scanner.pressedSnapshotIDs, ["answer-1"])
    }

    // §18 item 23: a successful press only marks `.answering` — never `.active` directly.
    func testSuccessfulAutoAnswerPressDoesNotDirectlyForceActive() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(tracker.state, .answering, "press success must only mark 'answering' — Active still requires verified evidence")
    }

    // §18 items 24/25: after a successful press, real active evidence drives Answering → Active,
    // and the session id never changes across the whole flow.
    func testAnsweringTransitionsToActiveViaVerifiedEvidenceAfterPress() async {
        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.delaySeconds = 0.05
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        scanner.snapshotsToReturn = TestSnapshots.ringingCallBannerFixture()
        await observer.tick()
        let sessionID = tracker.currentSession?.id
        XCTAssertEqual(tracker.state, .ringing)

        await autoAnswer.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(tracker.state, .answering)
        XCTAssertEqual(tracker.currentSession?.id, sessionID)

        scanner.snapshotsToReturn = TestSnapshots.activeCallBannerFixture()
        await observer.tick()

        XCTAssertEqual(tracker.state, .active)
        XCTAssertEqual(tracker.currentSession?.id, sessionID, "same session id must persist from ringing through active")
    }

    // §18 item 27
    func testOldSessionsPendingWorkCannotAffectNewerSession() async {
        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        // First call: scheduled, then the caller hangs up before it fires.
        tracker.update(hasAnyCandidate: true, evidence: .none)
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton(id: "answer-first")]
        controller.evaluate(candidates: AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn), workModeArmed: true)
        tracker.reset() // caller hung up — tracker back to idle, session gone
        controller.evaluate(candidates: [], workModeArmed: true) // matches what the observer's next tick would do
        await controller.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 0)

        // A second, genuinely new call rings immediately after.
        tracker.update(hasAnyCandidate: true, evidence: .none)
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton(id: "answer-second")]
        controller.evaluate(candidates: AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn), workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 1, "only the new session's press must ever occur")
        XCTAssertEqual(scanner.pressedSnapshotIDs, ["answer-second"])
    }
}
