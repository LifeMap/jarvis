import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 3 Gate C — Safety Regression. Most of §19's 27 requested scenarios are already
/// covered by the existing suite (`BridgeStateMachineTests` for the Work Mode → audio invariant,
/// `IncomingCallObserverTests.testFullCallLifecycleNeverActivatesDriverOrMutatesRoute` for the
/// full ringing→active→ending lifecycle against audio spies, `AnswerTransitionGraceTests`/
/// `AutoAnswerGateBTests` for Work-Mode/Auto-Answer cancellation and stale-session protection).
/// This file adds only the two scenarios that genuinely had no existing coverage.
@MainActor
final class GateCSafetyRegressionTests: XCTestCase {
    /// §19 item 22: app restart baseline. There is no persistence layer anywhere in `Call/`/`App/`
    /// (confirmed by inspection — no `UserDefaults`/file-based state for call sessions), so a
    /// "relaunch" is simply a fresh `CallLifecycleTracker` construction. This documents that
    /// invariant directly: a freshly constructed tracker (exactly what `BridgeViewModel.init()`
    /// creates on every launch) always starts clean.
    func testFreshCallLifecycleTrackerStartsWithNoStaleSession() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        XCTAssertEqual(tracker.state, .idle)
        XCTAssertNil(tracker.currentSession)
    }

    /// §19 item 25: "종료" (the verified end-call control) must never become an `AnswerCandidate`
    /// or receive a press from Auto Answer — even when scanned in the same pass as the real
    /// "응답" control (a transitional/glitchy scan could plausibly contain both momentarily).
    func testEndCallControlNeverBecomesAnswerCandidateOrReceivesPress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.endCallButton(), TestSnapshots.muteButton(), TestSnapshots.highConfidenceAnswerButton()]
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.snapshot.elementDescription, IncomingAnswerControlMatcher.answerDescription)

        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(scanner.pressedSnapshotIDs, ["answer-1"], "only the real Answer control may ever be pressed — '종료' must never appear in the pressed list")
    }
}
