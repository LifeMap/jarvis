import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 3 Active Call Evidence Fix — integration-level tests threading the real observed
/// ringing/active banner fixtures through `AnswerCandidateResolver` + `CallStateEvidenceExtractor`
/// into `CallLifecycleTracker`, the same path `IncomingCallObserver.tick()` uses in production
/// after the §11 single-scan-cycle fix. `CallLifecycleTrackerTests` already covers the tracker's
/// generic debounce mechanics with synthetic evidence; this file closes the loop with the actual
/// real-device fixtures instead.
@MainActor
final class CallLifecycleActiveTransitionTests: XCTestCase {
    final class FakeClock {
        var now = Date()
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    /// §14: Ringing → Active when the banner children transform from 응답/거절 to 종료/소리 끔/키패드.
    func testRingingTransformsToActiveWhenBannerChildrenTransform() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let ringingSnapshots = TestSnapshots.ringingCallBannerFixture()
        tracker.update(hasAnyCandidate: !AnswerCandidateResolver.resolve(from: ringingSnapshots).isEmpty, evidence: CallStateEvidenceExtractor.extract(from: ringingSnapshots))
        XCTAssertEqual(tracker.state, .ringing)

        let activeSnapshots = TestSnapshots.activeCallBannerFixture()
        tracker.update(hasAnyCandidate: !AnswerCandidateResolver.resolve(from: activeSnapshots).isEmpty, evidence: CallStateEvidenceExtractor.extract(from: activeSnapshots))

        XCTAssertEqual(tracker.state, .active, "the real observed banner transformation must drive Ringing → Active, not Ringing → Idle")
    }

    /// §15: AnswerCandidate disappearance during the transformation must not force Idle when
    /// verified active evidence appeared in that same update() call — this is exactly the bug Gate
    /// A's real-device test hit ("ringing candidate disappeared without active evidence").
    func testAnswerCandidateDisappearanceDuringTransformationDoesNotForceIdle() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)

        let activeSnapshots = TestSnapshots.activeCallBannerFixture() // no 응답 anywhere in this fixture
        let hasAnyCandidate = !AnswerCandidateResolver.resolve(from: activeSnapshots).isEmpty
        XCTAssertFalse(hasAnyCandidate, "the answer candidate has genuinely disappeared in this fixture")

        tracker.update(hasAnyCandidate: hasAnyCandidate, evidence: CallStateEvidenceExtractor.extract(from: activeSnapshots))

        XCTAssertEqual(tracker.state, .active, "verified active evidence in the same update() call must win over candidate disappearance")
    }

    /// §16: Active remains Active across repeated polling ticks while the signature persists.
    func testActiveRemainsActiveAcrossRepeatedTicksWhileSignaturePersists() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let activeEvidence = CallStateEvidenceExtractor.extract(from: TestSnapshots.activeCallBannerFixture())
        tracker.update(hasAnyCandidate: false, evidence: activeEvidence)
        XCTAssertEqual(tracker.state, .active)

        for _ in 0..<5 {
            tracker.update(hasAnyCandidate: false, evidence: activeEvidence)
            XCTAssertEqual(tracker.state, .active)
        }
    }

    /// §18: active signature disappearing beyond the debounce window ends the call, using the
    /// real fixture-derived evidence rather than a synthetic `CallStateEvidence` literal.
    func testActiveSignatureDisappearingBeyondDebounceEndsCallWithRealFixtures() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(endDebounceInterval: 1.0, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let activeEvidence = CallStateEvidenceExtractor.extract(from: TestSnapshots.activeCallBannerFixture())
        tracker.update(hasAnyCandidate: false, evidence: activeEvidence)
        XCTAssertEqual(tracker.state, .active)

        tracker.update(hasAnyCandidate: false, evidence: .none) // remote caller hangs up — banner disappears
        XCTAssertEqual(tracker.state, .ending)

        clock.advance(1.5)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .idle)
    }

    /// §17: a momentary disappearance of the active signature within the debounce window must
    /// recover, not finalize as ended — same guarantee as §18 but for the "blip" case.
    func testActiveSignatureBriefDisappearanceWithinDebounceRecoversWithRealFixtures() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(endDebounceInterval: 1.0, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let activeEvidence = CallStateEvidenceExtractor.extract(from: TestSnapshots.activeCallBannerFixture())
        tracker.update(hasAnyCandidate: false, evidence: activeEvidence)
        XCTAssertEqual(tracker.state, .active)

        tracker.update(hasAnyCandidate: false, evidence: .none) // momentary AX refresh blip
        XCTAssertEqual(tracker.state, .ending)

        clock.advance(0.2)
        tracker.update(hasAnyCandidate: false, evidence: activeEvidence) // evidence returns
        XCTAssertEqual(tracker.state, .active, "must recover to active, not finalize as ended")
    }

    /// §19: the no-call baseline still never leaves Idle.
    func testNoCallFixtureNeverLeavesIdle() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let snapshots = TestSnapshots.noCallBaselineFixture()
        let hasAnyCandidate = !AnswerCandidateResolver.resolve(from: snapshots).isEmpty
        tracker.update(hasAnyCandidate: hasAnyCandidate, evidence: CallStateEvidenceExtractor.extract(from: snapshots))
        XCTAssertEqual(tracker.state, .idle)
    }

    /// §23: this entire manual-answer path (real fixtures driving Ringing → Active) never
    /// constructs or references `AutoAnswerController` at all.
    func testManualAnswerPathNeverRequiresAutoAnswerController() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let activeEvidence = CallStateEvidenceExtractor.extract(from: TestSnapshots.activeCallBannerFixture())
        tracker.update(hasAnyCandidate: false, evidence: activeEvidence)
        XCTAssertEqual(tracker.state, .active)
    }
}
