import XCTest
@testable import JarvisCallBridge

@MainActor
final class IncomingCallObserverTests: XCTestCase {
    func testWorkModeOffKeepsObserverInactiveEvenWithCandidatesPresent() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { false })

        await observer.tick()

        XCTAssertEqual(tracker.state, .idle)
        XCTAssertTrue(observer.candidates.isEmpty)
        XCTAssertEqual(scanner.pressCallCount, 0)
    }

    func testArmedWithIncomingCandidateReachesRinging() async {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.isEnabled = false // isolate detection from auto-answer for this test
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        await observer.tick()

        XCTAssertEqual(tracker.state, .ringing)
        XCTAssertEqual(observer.candidates.count, 1)
        XCTAssertEqual(observer.candidates.first?.confidence, .high)
    }

    /// PRD §22–24: the entire Phase 2 call lifecycle — ringing, auto-answer press, active, end —
    /// must never activate the Phase 1 audio driver or mutate the audio route. `callTracker`/
    /// `autoAnswer`/`incomingCallObserver` don't even hold a reference to the route/driver spies
    /// (only `BridgeStateMachine`, reachable solely via Work Mode, does) — this test exercises a
    /// full realistic lifecycle end to end and asserts the spies attached to the *separately
    /// constructed* state machine never fire, matching how `BridgeViewModel` actually wires things.
    func testFullCallLifecycleNeverActivatesDriverOrMutatesRoute() async {
        let routeSpy = AudioRouteMutationSpy()
        let driverSpy = AudioDriverActivationSpy()
        let stateMachine = BridgeStateMachine(routeMutator: routeSpy, driverActivator: driverSpy, logger: BridgeLogger())
        stateMachine.setWorkMode(true)
        XCTAssertEqual(stateMachine.state, .armed)

        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.delaySeconds = 0.05
        let observer = IncomingCallObserver(
            scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(),
            workModeArmedProvider: { stateMachine.state == .armed }
        )

        // Ringing.
        scanner.snapshotsToReturn = [TestSnapshots.highConfidenceAnswerButton()]
        await observer.tick()
        XCTAssertEqual(tracker.state, .ringing)
        XCTAssertEqual(routeSpy.callCount, 0)
        XCTAssertEqual(driverSpy.activateCallCount, 0)

        // Auto-answer fires.
        await autoAnswer.waitForScheduledAttempt()
        XCTAssertEqual(scanner.pressCallCount, 1)
        XCTAssertEqual(routeSpy.callCount, 0)
        XCTAssertEqual(driverSpy.activateCallCount, 0)

        // Active — CHECKPOINT 3: evidence is now derived from the same scanned snapshots as
        // candidates (never a separately-mocked `evidenceToReturn`), so this uses the real
        // observed active-call banner shape (응답/거절 replaced by 종료/소리 끔/키패드).
        scanner.snapshotsToReturn = TestSnapshots.activeCallBannerFixture()
        await observer.tick()
        XCTAssertEqual(tracker.state, .active)
        XCTAssertEqual(routeSpy.callCount, 0)
        XCTAssertEqual(driverSpy.activateCallCount, 0)
        XCTAssertEqual(driverSpy.deactivateCallCount, 0)

        // End.
        scanner.snapshotsToReturn = []
        await observer.tick()
        XCTAssertEqual(tracker.state, .ending)

        XCTAssertEqual(routeSpy.callCount, 0, "audio route must never be mutated across the whole call lifecycle")
        XCTAssertEqual(driverSpy.activateCallCount, 0, "audio driver must never be activated by call lifecycle events")
        XCTAssertEqual(driverSpy.deactivateCallCount, 0)
    }
}
