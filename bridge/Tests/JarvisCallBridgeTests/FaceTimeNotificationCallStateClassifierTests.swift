import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 3 Active Call Evidence Fix. Real-device evidence: a genuinely active call banner
/// replaces 응답/거절 with 종료/소리 끔/키패드 — all still inside the same evidence-locked
/// `FACETIME_NOTIFICATION` banner. These tests exercise `FaceTimeNotificationCallStateClassifier`
/// with the real observed fixtures and the structural boundary conditions that keep this from
/// regressing back into CHECKPOINT 2's global-keyword false-positive problem.
final class FaceTimeNotificationCallStateClassifierTests: XCTestCase {
    // MARK: - §1/§2: exact real hierarchies

    func testExactRealRingingHierarchyClassifiesRinging() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: TestSnapshots.ringingCallBannerFixture()), .ringing)
    }

    func testExactRealActiveHierarchyClassifiesActive() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: TestSnapshots.activeCallBannerFixture()), .active)
    }

    // MARK: - §3/§4: structural requirements are load-bearing, not the labels alone

    func testActiveRequiresFacetimeNotificationBannerAncestor() {
        let endCallOutsideBanner = AXElementSnapshot(
            id: "end-outside", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil, title: nil, elementDescription: "종료",
            enabled: true, actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: []
        )
        let muteOutsideBanner = AXElementSnapshot(
            id: "mute-outside", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil, title: nil, elementDescription: "소리 끔",
            enabled: true, actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: []
        )
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [endCallOutsideBanner, muteOutsideBanner]), .none)
    }

    func testActiveRequiresNotificationCenterOwner() {
        let endCallWrongProcess = AXElementSnapshot(
            id: "end-wrong-process", pid: 9009, bundleIdentifier: "com.example.other",
            role: "AXButton", subrole: nil, axIdentifier: nil, title: nil, elementDescription: "종료",
            enabled: true, actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        let muteWrongProcess = AXElementSnapshot(
            id: "mute-wrong-process", pid: 9009, bundleIdentifier: "com.example.other",
            role: "AXButton", subrole: nil, axIdentifier: nil, title: nil, elementDescription: "소리 끔",
            enabled: true, actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [endCallWrongProcess, muteWrongProcess]), .none)
    }

    // MARK: - §5/§6/§7: generic labels outside the banner are never evidence (no regression to global keywords)

    func testGenericEndCallLabelOutsideBannerIsNotActiveEvidence() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "generic-end", description: "종료")
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [snapshot]), .none)
    }

    func testGenericKeypadInNormalPhoneAppIsNotActiveEvidence() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: TestSnapshots.noCallBaselineFixture()), .none)
    }

    func testGenericMuteLabelOutsideBannerIsNotActiveEvidence() {
        let snapshot = TestSnapshots.ordinaryPhoneAppControl(id: "generic-mute", description: "소리 끔")
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [snapshot]), .none)
    }

    // MARK: - §8/§9: verified end-call + either in-call control classifies Active

    func testVerifiedEndCallPlusMuteClassifiesActive() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [TestSnapshots.endCallButton(), TestSnapshots.muteButton()]), .active)
    }

    func testVerifiedEndCallPlusKeypadClassifiesActive() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [TestSnapshots.endCallButton(), TestSnapshots.keypadButtonInBanner()]), .active)
    }

    // MARK: - §10: 종료 alone is insufficient — two independent signals required

    func testEndCallAloneWithoutInCallControlIsNotActive() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [TestSnapshots.endCallButton()]), .none)
    }

    // MARK: - §11: 더 보기 never distinguishes Ringing vs Active

    func testMoreButtonAloneNeverClassifiesRingingOrActive() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [TestSnapshots.moreButton()]), .none)
    }

    func testMoreButtonPresentInBothRingingAndActiveDoesNotChangeClassification() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: TestSnapshots.ringingCallBannerFixture()), .ringing)
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: TestSnapshots.activeCallBannerFixture()), .active)
    }

    // MARK: - §12: "FaceTime 영상 통화" disabled control is diagnostic-only, never required

    func testActiveClassificationDoesNotRequireFaceTimeVideoCallControl() {
        let withoutVideoControl = [TestSnapshots.endCallButton(), TestSnapshots.muteButton(), TestSnapshots.keypadButtonInBanner(), TestSnapshots.moreButton()]
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: withoutVideoControl), .active)
    }

    // MARK: - §13: ringing signature requires both 응답 and 거절

    func testRingingRequiresBothAnswerAndReject() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [TestSnapshots.highConfidenceAnswerButton()]), .none, "응답 alone, without 거절, is not the verified ringing signature")
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: [TestSnapshots.highConfidenceAnswerButton(), TestSnapshots.rejectButton()]), .ringing)
    }

    // MARK: - §20: no-call baseline still classifies none

    func testNoCallBaselineClassifiesNone() {
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: TestSnapshots.noCallBaselineFixture()), .none)
    }

    // MARK: - §21: "종료" presence means an available end-call control, never "already ended"

    func testEndCallControlPresenceMeansAvailableControlNotAlreadyEnded() {
        let evidence = CallStateEvidenceExtractor.extract(from: TestSnapshots.activeCallBannerFixture())
        XCTAssertTrue(evidence.endCallButtonPresent, "the end-call control being present/enabled is active-call evidence, not end-of-call evidence")
        XCTAssertTrue(evidence.activeCallControlsPresent)
    }

    // MARK: - §22: classification is structurally read-only

    func testClassificationNeverPerformsAnyAction() {
        // If this compiles, `classify` only ever reads `AXElementSnapshot` fields — that type has
        // no press/mutation capability at all.
        _ = FaceTimeNotificationCallStateClassifier.classify(from: TestSnapshots.activeCallBannerFixture())
    }
}
