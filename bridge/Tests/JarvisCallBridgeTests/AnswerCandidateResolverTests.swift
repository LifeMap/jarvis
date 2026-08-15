import XCTest
@testable import JarvisCallBridge

final class AnswerCandidateResolverTests: XCTestCase {
    // MARK: - CHECKPOINT 3: evidence-locked matching (real-device shape)

    func testSingleStrongCandidateScoresHigh() {
        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.highConfidenceAnswerButton()])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.confidence, .high)
    }

    /// CHECKPOINT 3 §8: there is no more "medium via weak generic signals" — medium only ever
    /// arises from ambiguity (multiple simultaneous evidence-locked matches).
    func testAmbiguousMultipleMatchesDowngradeToMedium() {
        let candidates = AnswerCandidateResolver.resolve(from: [
            TestSnapshots.highConfidenceAnswerButton(id: "a", pid: 1001),
            TestSnapshots.highConfidenceAnswerButton(id: "b", pid: 1002)
        ])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.confidence == .medium })
    }

    /// CHECKPOINT 2 false-positive fix: a real no-call baseline scanned 341 ordinary Phone.app/
    /// Notification Center elements (Edit/Filter/Keypad/Search/window chrome) that were all
    /// enabled+pressable+AXButton, none of which are actually call-related. Generic bonuses alone
    /// (enabled + owning process + role) must never be enough to qualify as a candidate.
    func testGenericButtonWithNoCallSpecificSignalIsNeverACandidate() {
        let candidates = AnswerCandidateResolver.resolve(from: [TestSnapshots.lowConfidenceButton()])
        XCTAssertTrue(candidates.isEmpty, "no evidence-locked structural match ⇒ not a candidate at all, not even low confidence")
    }

    /// CHECKPOINT 3: a disabled element can never match the evidence-locked matcher at all
    /// (`enabled` is a hard requirement), so it isn't merely downgraded — it's excluded entirely.
    func testDisabledElementIsNeverACandidate() {
        let snapshot = AXElementSnapshot(
            id: "disabled-1", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil,
            title: nil, elementDescription: IncomingAnswerControlMatcher.answerDescription, enabled: false,
            actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [snapshot]).isEmpty)
    }

    func testElementsWithoutPressActionAreIgnored() {
        let snapshot = AXElementSnapshot(
            id: "no-press", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil,
            title: nil, elementDescription: IncomingAnswerControlMatcher.answerDescription, enabled: true,
            actions: [], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [snapshot]).isEmpty)
    }

    // MARK: - CHECKPOINT 3 §22 items 3-9: every structural requirement is individually load-bearing

    func testCandidateRequiresOwnerBundleNotificationCenter() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [TestSnapshots.answerButtonUnderUnrelatedProcess()]).isEmpty)
    }

    func testCandidateRequiresFacetimeNotificationBannerAncestor() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [TestSnapshots.answerButtonOutsideBanner()]).isEmpty)
    }

    func testCandidateRequiresSystemDialogWindowAncestor() {
        let snapshot = AXElementSnapshot(
            id: "no-window-context", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil,
            title: nil, elementDescription: IncomingAnswerControlMatcher.answerDescription, enabled: true,
            actions: ["AXPress"], firstObservedAt: Date(),
            ancestorChain: [AXAncestorDescriptor(role: IncomingAnswerControlMatcher.bannerRole, subrole: IncomingAnswerControlMatcher.bannerSubrole, axIdentifier: IncomingAnswerControlMatcher.bannerIdentifier)]
        )
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [snapshot]).isEmpty, "banner ancestor alone, without the AXSystemDialog window ancestor, must not qualify")
    }

    func testCandidateRequiresTargetRoleAXButton() {
        let snapshot = AXElementSnapshot(
            id: "wrong-role", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXStaticText", subrole: nil, axIdentifier: nil,
            title: nil, elementDescription: IncomingAnswerControlMatcher.answerDescription, enabled: true,
            actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [snapshot]).isEmpty)
    }

    func testCandidateRequiresExactAnswerDescription() {
        let snapshot = AXElementSnapshot(
            id: "wrong-description", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil,
            title: nil, elementDescription: "응답하기", enabled: true,
            actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [snapshot]).isEmpty, "description must match exactly — no fuzzy/substring matching")
    }

    func testCandidateRequiresAXPressSupport() {
        let snapshot = AXElementSnapshot(
            id: "no-press-action", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil,
            title: nil, elementDescription: IncomingAnswerControlMatcher.answerDescription, enabled: true,
            actions: [], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [snapshot]).isEmpty)
    }

    // MARK: - CHECKPOINT 3 §6/§19/§20/§22 items 10-13: sibling banner controls are never candidates

    func testRejectButtonIsNeverAnswerCandidate() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [TestSnapshots.rejectButton()]).isEmpty)
    }

    func testReplyButtonIsNeverAnswerCandidate() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [TestSnapshots.replyButton()]).isEmpty)
    }

    func testMoreButtonIsNeverAnswerCandidate() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [TestSnapshots.moreButton()]).isEmpty)
    }

    func testCallPresenceHintElementIsNeverAnswerCandidate() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: [TestSnapshots.callPresenceHintElement()]).isEmpty)
    }

    /// The full real banner (Reject/Reply/More, no Answer) must yield zero candidates — proves
    /// siblings never accidentally qualify even when scanned together as they'd really appear.
    func testFullBannerWithoutAnswerYieldsNoCandidates() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: TestSnapshots.notificationCenterBannerWithoutAnswer()).isEmpty)
    }

    /// The real Answer button alongside its real siblings must yield exactly the Answer candidate
    /// — siblings present in the same scan must not create ambiguity or otherwise interfere.
    func testAnswerButtonAmongRealSiblingsYieldsExactlyOneHighCandidate() {
        let elements = TestSnapshots.notificationCenterBannerWithoutAnswer() + [TestSnapshots.highConfidenceAnswerButton()]
        let candidates = AnswerCandidateResolver.resolve(from: elements)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.confidence, .high)
        XCTAssertEqual(candidates.first?.snapshot.elementDescription, IncomingAnswerControlMatcher.answerDescription)
    }

    // MARK: - CHECKPOINT 2 no-call baseline must still hold (§21/§22 items 29-30)

    func testNoCallBaselineStillYieldsNoCandidates() {
        XCTAssertTrue(AnswerCandidateResolver.resolve(from: TestSnapshots.noCallBaselineFixture()).isEmpty)
    }
}
