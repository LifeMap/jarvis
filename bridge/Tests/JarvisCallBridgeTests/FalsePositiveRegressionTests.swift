import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 2 — False Positive Elimination. A real-device no-call baseline (Work Mode ON, Auto
/// Answer OFF, no actual call) produced `Candidates=341` and `answer=true end=true
/// activeControls=true duration=true` from ordinary Phone.app/Notification Center UI. These tests
/// exercise the fix at the pure-data layer (`AnswerCandidateResolver`/`CallStateEvidenceExtractor`)
/// with fixtures shaped exactly like that baseline — no real Accessibility framework call needed.
final class FalsePositiveRegressionTests: XCTestCase {
    // MARK: - AnswerCandidateResolver

    /// §5: "Phone.app Edit / Filter / Keypad / Search controls alone produce no AnswerCandidate."
    func testOrdinaryPhoneAppDialerControlsProduceNoCandidates() {
        let candidates = AnswerCandidateResolver.resolve(from: TestSnapshots.noCallBaselineFixture())
        XCTAssertTrue(candidates.isEmpty, "Edit/Filter/Keypad/Search/Close/Zoom/Minimize must never become AnswerCandidate objects")
    }

    /// §12: "통신 오디오" alone is never an AnswerCandidate.
    func testCallPresenceHintElementAloneIsNeverACandidate() {
        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.callPresenceHintElement()])
        XCTAssertTrue(candidates.isEmpty, "the transient '통신 오디오' element is a diagnostic clue only, never sufficient for candidacy by itself")
    }

    // MARK: - CallStateEvidenceExtractor

    /// §6: window Close/Minimize/Zoom buttons do not produce call-state evidence.
    /// §7: generic Phone.app controls (Edit/Filter/Keypad/Search) do not produce call-state evidence.
    /// §9: full no-call baseline fixture produces every evidence category false.
    func testNoCallBaselineProducesNoEvidenceOfAnyKind() {
        let evidence = CallStateEvidenceExtractor.extract(from: TestSnapshots.noCallBaselineFixture())
        XCTAssertFalse(evidence.answerButtonPresent)
        XCTAssertFalse(evidence.endCallButtonPresent)
        XCTAssertFalse(evidence.activeCallControlsPresent)
        XCTAssertFalse(evidence.callDurationUIPresent)
    }

    /// §7/§8: application "Quit"/window "Close" style commands (bare "종료") must never create
    /// end-call evidence — only removed can be re-added once genuine call-specific evidence (e.g.
    /// "통화 종료") is captured.
    func testBareGenericQuitCloseWordNeverCreatesEndCallEvidence() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "quit", title: "앱 종료")
        let evidence = CallStateEvidenceExtractor.extract(from: [snapshot])
        XCTAssertFalse(evidence.endCallButtonPresent, "bare '종료' (quit/exit/close) is too generic to be end-call evidence")
    }

    /// CHECKPOINT 3 Active Call Evidence Fix superseded the global-keyword approach entirely: a
    /// bare Phone.app-owned "통화 종료" title, with no `FACETIME_NOTIFICATION` banner ancestry,
    /// must now produce NO end-call evidence at all — only the real, evidence-locked banner
    /// signature does (see `testVerifiedActiveBannerSignatureCreatesEndAndActiveControlsEvidence`
    /// in `FaceTimeNotificationCallStateClassifierTests`).
    func testEndCallPhraseWithoutBannerContextNeverCreatesEvidence() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "end-call", title: "통화 종료")
        let evidence = CallStateEvidenceExtractor.extract(from: [snapshot])
        XCTAssertFalse(evidence.endCallButtonPresent, "end-call semantics only apply inside the real FACETIME_NOTIFICATION banner, never from a global keyword match")
    }

    /// §8: "arbitrary numeric text does not create duration evidence" — a colon appearing
    /// anywhere in unrelated text (e.g. a clock-style label) must not count.
    func testArbitraryColonContainingTextDoesNotCreateDurationEvidence() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "clock-label", title: "오후 3:45 회의")
        let evidence = CallStateEvidenceExtractor.extract(from: [snapshot])
        XCTAssertFalse(evidence.callDurationUIPresent, "a colon inside unrelated text must not be treated as a running call duration")
    }

    /// A clean MM:SS duration string must still work — proves the fix narrowed the check rather
    /// than disabling duration evidence entirely.
    func testCleanMMSSDurationStringStillCreatesEvidence() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "duration", title: "01:23")
        let evidence = CallStateEvidenceExtractor.extract(from: [snapshot])
        XCTAssertTrue(evidence.callDurationUIPresent)
    }

    /// §7/§8: "키패드" (keypad) is Phone.app's always-present dialer control, confirmed present in
    /// the no-call baseline — must not create active-call-controls evidence.
    func testKeypadAloneNeverCreatesActiveControlsEvidence() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "keypad", title: "키패드")
        let evidence = CallStateEvidenceExtractor.extract(from: [snapshot])
        XCTAssertFalse(evidence.activeCallControlsPresent)
    }

    /// §10: "통신 오디오" must never by itself prove Ringing vs. Active — i.e. must never alone
    /// produce any evidence category.
    func testCallPresenceHintElementAloneProducesNoEvidence() {
        let evidence = CallStateEvidenceExtractor.extract(from: [TestSnapshots.callPresenceHintElement()])
        XCTAssertFalse(evidence.answerButtonPresent)
        XCTAssertFalse(evidence.endCallButtonPresent)
        XCTAssertFalse(evidence.activeCallControlsPresent)
        XCTAssertFalse(evidence.callDurationUIPresent)
    }

    /// A disabled element's text must never contribute to keyword-based evidence, even if it
    /// would otherwise match — a stale/disabled leftover in the tree shouldn't count.
    func testDisabledElementNeverContributesKeywordEvidence() {
        let snapshot = AXElementSnapshot(
            id: "disabled-end", pid: 1, bundleIdentifier: "com.apple.mobilephone",
            role: "AXButton", subrole: nil, axIdentifier: nil,
            title: "통화 종료", elementDescription: nil, enabled: false,
            actions: ["AXPress"], firstObservedAt: Date()
        )
        let evidence = CallStateEvidenceExtractor.extract(from: [snapshot])
        XCTAssertFalse(evidence.endCallButtonPresent)
    }

    // MARK: - §11: persistent ordinary UI cannot keep (or start) the lifecycle in Ringing

    /// §9/§11: feeding `IncomingCallObserver` the no-call baseline repeatedly (simulating many
    /// poll ticks against persistent ordinary Phone.app UI) must never transition into Ringing —
    /// this is the exact real-device symptom (state stuck at Ringing, candidates stuck at 341).
    @MainActor
    func testPersistentNoCallBaselineNeverReachesRinging() {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = TestSnapshots.noCallBaselineFixture()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        for _ in 0..<10 {
            observer.tick()
        }

        XCTAssertEqual(tracker.state, .idle, "persistent ordinary Phone.app UI across repeated ticks must never be mistaken for ringing")
        XCTAssertTrue(observer.candidates.isEmpty)
    }
}
