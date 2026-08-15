import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 3 §9/§10/§18: the delay between scheduling and pressing can span several poll
/// ticks, so `AutoAnswerController` must re-scan and re-resolve the live AX hierarchy immediately
/// before the click, requiring the *same* element (by id) to still satisfy the exact
/// evidence-locked matcher. These tests exercise that revalidation path directly via
/// `MockAccessibilityScanning.snapshotsToReturn`, mutated between scheduling and the press.
@MainActor
final class AutoAnswerRevalidationTests: XCTestCase {
    private func makeRingingTracker() -> CallLifecycleTracker {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        precondition(tracker.state == .ringing)
        return tracker
    }

    /// §22 item 17: candidate disappears during the delay → no press.
    func testCandidateDisappearsDuringDelayCancelsPress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)

        scanner.snapshotsToReturn = [] // the live element vanishes before the timer fires

        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0, "live revalidation must find nothing and cancel, never press a stale snapshot")
    }

    /// §22 item 18: candidate changes identity during the delay → no press, and never falls back
    /// to pressing a *different* (even if independently qualifying) element.
    func testCandidateChangesIdentityDuringDelayCancelsPress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton(id: "answer-original")]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)

        // The banner re-renders with a new element identity for a same-looking button.
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton(id: "answer-recreated")]

        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0, "must never fall back to pressing a different element than the one originally scheduled")
    }

    /// §22 item 19: Accessibility trust lost during the delay → no press. `MockAccessibilityScanning`
    /// doesn't model `AXIsProcessTrusted()` directly, but its observable effect is identical to the
    /// live rescan finding nothing — the real `SystemAccessibilityClient` returns an empty scan
    /// whenever trust is lost, so this exercises the same "live rescan finds nothing" path.
    func testAccessibilityTrustLostDuringDelayCancelsPress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)

        scanner.snapshotsToReturn = [] // simulates AXIsProcessTrusted() becoming false mid-delay

        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    /// §22 item 21: Auto Answer toggled OFF during the delay → no press (distinct from turning it
    /// off *before* ever scheduling, which `testAutoAnswerDisabledNeverPresses` already covers).
    func testAutoAnswerDisabledDuringDelayCancelsWithoutPress() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.3

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)
        XCTAssertNotNil(controller.countdownRemaining)

        controller.isEnabled = false
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    /// §19/§20/§22 items 26-28: Reject/Reply/More siblings present in the *same* scan as the real
    /// Answer button must never receive the press — only the evidence-locked Answer control does.
    func testSiblingBannerControlsNeverReceivePressEvenWhenPresentTogether() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = TestSnapshots.notificationCenterBannerWithoutAnswer() + [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = makeRingingTracker()
        let controller = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        controller.delaySeconds = 0.05

        let candidates = AnswerCandidateResolver.resolve(from: scanner.snapshotsToReturn)
        controller.evaluate(candidates: candidates, workModeArmed: true)
        await controller.waitForScheduledAttempt()

        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(scanner.pressedSnapshotIDs, ["answer-1"], "only the Answer control's id may ever appear in the pressed list")
    }
}
