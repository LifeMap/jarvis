import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 3 Production/Focused AX Parity Diagnostic. Real-device evidence showed the Focused
/// Call AX Snapshot reliably found the live `FACETIME_NOTIFICATION` banner (windows=5, nodes=88,
/// stable across two captures 12s apart) while production's `scanCallRelevantElements()` found
/// nothing at the same moment — even though both ultimately call the identical
/// `AXRawDiscovery.walk` on the identical window element. The actual divergence was upstream, in
/// process discovery: `scanProcess` used `NSRunningApplication.runningApplications(withBundleIdentifier:)`
/// while the focused path (which worked) used `NSWorkspace.shared.runningApplications` — now
/// unified. These tests exercise the *shared* low-level pipeline (walk → production-style filter →
/// snapshot conversion → classify) end to end using fake AX trees shaped like the real hierarchy,
/// proving ancestry/depth/filtering parity without needing real AX access.
final class ProductionFocusedScanParityTests: XCTestCase {
    /// Mirrors `SystemAccessibilityClient.snapshot(from:pid:bundleIdentifier:)`'s field mapping —
    /// duplicated here only because that method is private to its file; it's a trivial 1:1 field
    /// copy, not a second implementation of any scanning/filtering/ancestry logic.
    private func snapshot(from raw: AXRawDiscoveryElement, pid: pid_t, bundleIdentifier: String) -> AXElementSnapshot {
        AXElementSnapshot(
            id: raw.axIdentifier ?? "\(pid)|\(raw.role ?? "?")|\(raw.title ?? "")|\(raw.elementDescription ?? "")",
            pid: pid, bundleIdentifier: bundleIdentifier, role: raw.role, subrole: raw.subrole,
            axIdentifier: raw.axIdentifier, title: raw.title, elementDescription: raw.elementDescription,
            enabled: raw.enabled, actions: raw.actions, firstObservedAt: Date(), ancestorChain: raw.ancestorChain
        )
    }

    /// Runs the exact same pipeline `SystemAccessibilityClient.scanWindows` uses in production:
    /// bounded window walk (`maxDepth: 8`, matching `SystemAccessibilityClient.maxScanDepth`),
    /// then the production filter (`actions.contains(AXPress) || role == "AXButton"`), then
    /// snapshot conversion.
    private func productionStyleScan(_ windowRoot: AXRawNode, pid: pid_t = 1001, bundleIdentifier: String = IncomingAnswerControlMatcher.ownerBundleIdentifier) -> [AXElementSnapshot] {
        let outcome = AXRawDiscovery.walk(windowRoot, pid: pid, processName: "NotificationCenter", bundleIdentifier: bundleIdentifier, maxDepth: 8, maxNodesForProcess: 600)
        return outcome.elements
            .filter { $0.actions.contains("AXPress") || $0.role == "AXButton" }
            .map { snapshot(from: $0, pid: pid, bundleIdentifier: bundleIdentifier) }
    }

    private func makeRealHierarchy(bannerChildren: [FakeAXNode]) -> FakeAXNode {
        let banner = FakeAXNode(role: "AXGroup", children: bannerChildren)
        banner.subrole = "AXNotificationCenterBanner"
        banner.axIdentifier = IncomingAnswerControlMatcher.bannerIdentifier

        let window = FakeAXNode(role: "AXWindow", title: "Notification Center", children: [banner])
        window.subrole = IncomingAnswerControlMatcher.windowSubrole
        return window
    }

    private func makeButton(description: String, enabled: Bool = true, role: String = "AXButton") -> FakeAXNode {
        let node = FakeAXNode(role: role, enabled: enabled, actions: ["AXPress"])
        node.elementDescription = description
        return node
    }

    private func makeGenericElement(description: String) -> FakeAXNode {
        let node = FakeAXNode(role: "AXGenericElement")
        node.elementDescription = description
        return node
    }

    // MARK: - §11 items 1-3: ancestry parity through the shared pipeline

    func testProductionStylePipelinePreservesFullAncestryChainForRinging() {
        let window = makeRealHierarchy(bannerChildren: [makeButton(description: "응답"), makeButton(description: "거절")])
        let snapshots = productionStyleScan(window)
        guard let answer = snapshots.first(where: { $0.elementDescription == "응답" }) else {
            return XCTFail("응답 must survive the production filter")
        }
        XCTAssertTrue(answer.ancestorChain.contains { $0.role == "AXWindow" && $0.subrole == "AXSystemDialog" })
        XCTAssertTrue(answer.ancestorChain.contains { $0.role == "AXGroup" && $0.subrole == "AXNotificationCenterBanner" && $0.axIdentifier == "FACETIME_NOTIFICATION" })
    }

    func testProductionActiveHierarchyIncludesFacetimeNotificationAncestor() {
        let window = makeRealHierarchy(bannerChildren: [makeButton(description: "종료"), makeButton(description: "소리 끔")])
        let snapshots = productionStyleScan(window)
        guard let endCall = snapshots.first(where: { $0.elementDescription == "종료" }) else {
            return XCTFail("종료 must survive the production filter")
        }
        XCTAssertTrue(endCall.ancestorChain.contains { $0.axIdentifier == IncomingAnswerControlMatcher.bannerIdentifier })
    }

    func testProductionActiveHierarchyPreservesSystemDialogWindowMetadata() {
        let window = makeRealHierarchy(bannerChildren: [makeButton(description: "종료"), makeButton(description: "소리 끔")])
        let snapshots = productionStyleScan(window)
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(snapshots.allSatisfy { $0.ancestorChain.contains { $0.subrole == IncomingAnswerControlMatcher.windowSubrole } })
    }

    // MARK: - §11 item 4: depth sufficiency at the real observed nesting depth

    /// Mirrors the approximate real nesting depth (banner ~depth 4, buttons ~depth 7) with extra
    /// wrapper groups, proving `maxDepth=8` (both scan paths already use this) is sufficient.
    func testProductionScanReachesButtonsAtRealObservedDepth() {
        let endCall = makeButton(description: "종료")
        let wrapped = FakeAXNode(role: "AXGroup", children: [FakeAXNode(role: "AXGroup", children: [endCall])])
        let banner = FakeAXNode(role: "AXGroup", children: [wrapped])
        banner.subrole = "AXNotificationCenterBanner"
        banner.axIdentifier = IncomingAnswerControlMatcher.bannerIdentifier
        let wrappedBanner = FakeAXNode(role: "AXGroup", children: [banner])
        let window = FakeAXNode(role: "AXWindow", children: [wrappedBanner])
        window.subrole = IncomingAnswerControlMatcher.windowSubrole

        let snapshots = productionStyleScan(window)
        XCTAssertTrue(snapshots.contains { $0.elementDescription == "종료" }, "maxDepth=8 must reach buttons nested several groups below the banner, matching the real observed depth")
    }

    // MARK: - §11 items 5-6: end-to-end classification of the real hierarchies

    func testProductionPipelineClassifiesRealActiveHierarchyAsActive() {
        let window = makeRealHierarchy(bannerChildren: [
            makeGenericElement(description: "전화"),
            makeButton(description: "키패드"),
            makeButton(description: "FaceTime 영상 통화", enabled: false),
            makeButton(description: "소리 끔"),
            makeButton(description: "더 보기", role: "AXPopUpButton"),
            makeButton(description: "종료")
        ])
        let snapshots = productionStyleScan(window)
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: snapshots), .active)
    }

    func testProductionPipelineClassifiesRealRingingHierarchyAsRinging() {
        let window = makeRealHierarchy(bannerChildren: [
            makeGenericElement(description: "전화"),
            makeButton(description: "답장"),
            makeButton(description: "더 보기", role: "AXPopUpButton"),
            makeButton(description: "거절"),
            makeButton(description: "응답")
        ])
        let snapshots = productionStyleScan(window)
        XCTAssertEqual(FaceTimeNotificationCallStateClassifier.classify(from: snapshots), .ringing)
    }

    // MARK: - §11 item 7: same immutable scan snapshot feeds candidate + evidence

    private final class CountingScanner: AccessibilityScanning {
        var snapshotsToReturn: [AXElementSnapshot] = []
        private(set) var scanCallCount = 0
        func scanCallRelevantElements() -> [AXElementSnapshot] { scanCallCount += 1; return snapshotsToReturn }
        func currentCallStateEvidence() -> CallStateEvidence { XCTFail("tick() must derive evidence from the same scan as candidates, not call currentCallStateEvidence() separately"); return .none }
        func press(_ snapshot: AXElementSnapshot) -> AccessibilityPressResult { .success }
    }

    @MainActor
    func testObserverTickScansExactlyOncePerCycle() {
        let scanner = CountingScanner()
        scanner.snapshotsToReturn = TestSnapshots.ringingCallBannerFixture()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.isEnabled = false
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        observer.tick()

        XCTAssertEqual(scanner.scanCallCount, 1, "candidates and evidence must come from a single scan per tick")
        XCTAssertEqual(tracker.state, .ringing)
    }

    // MARK: - §11 item 8: candidate disappearance + active signature in the same cycle → Active, never Idle

    @MainActor
    func testObserverTickTransitionsRingingToActiveInSingleTick() {
        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.isEnabled = false
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        scanner.snapshotsToReturn = TestSnapshots.ringingCallBannerFixture()
        observer.tick()
        XCTAssertEqual(tracker.state, .ringing)

        scanner.snapshotsToReturn = TestSnapshots.activeCallBannerFixture()
        observer.tick()
        XCTAssertEqual(tracker.state, .active, "a single tick must transition Ringing → Active directly, never dip through Idle")
    }

    // MARK: - §11 item 9: active signature persists across repeated ticks

    @MainActor
    func testObserverTickKeepsActiveAcrossRepeatedTicks() {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = TestSnapshots.activeCallBannerFixture()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none) // pre-seed ringing so the first tick can reach active
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        autoAnswer.isEnabled = false
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        for _ in 0..<5 {
            observer.tick()
            XCTAssertEqual(tracker.state, .active)
        }
    }

    // MARK: - §11 items 10-11: no-call baseline / normal Phone.app UI still produce nothing

    @MainActor
    func testObserverTickNoCallBaselineStaysIdleWithNoEvidence() {
        let scanner = MockAccessibilityScanning()
        scanner.snapshotsToReturn = TestSnapshots.noCallBaselineFixture()
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { true })

        observer.tick()

        XCTAssertEqual(tracker.state, .idle)
        XCTAssertTrue(observer.candidates.isEmpty)
        XCTAssertFalse(observer.lastEvidence.answerButtonPresent)
        XCTAssertFalse(observer.lastEvidence.endCallButtonPresent)
        XCTAssertFalse(observer.lastEvidence.activeCallControlsPresent)
    }

    // MARK: - §11 item 12: diagnostic semantic logging never exposes caller data

    func testClassificationDiagnosticsNeverIncludeArbitraryCallerText() {
        let callerNameLookalike = AXElementSnapshot(
            id: "caller-name", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil, title: nil, elementDescription: "홍길동",
            enabled: true, actions: ["AXPress"], firstObservedAt: Date(), ancestorChain: TestSnapshots.facetimeNotificationAncestorChain
        )
        let diagnostics = FaceTimeNotificationCallStateClassifier.classifyWithDiagnostics(from: [callerNameLookalike, TestSnapshots.highConfidenceAnswerButton(), TestSnapshots.rejectButton()])

        XCTAssertFalse(diagnostics.controlsDetected.contains("홍길동"), "[CALL-SCAN] logging must never surface arbitrary element text, even if it happens to be AXButton/AXPress-capable inside the banner")
        XCTAssertEqual(Set(diagnostics.controlsDetected), Set(["응답", "거절"]))
    }

    /// §5: the diagnostic funnel breakdown reflects exactly where a partial match stopped.
    func testClassificationDiagnosticsFunnelReflectsPartialMatches() {
        let wrongWindowSubrole = AXElementSnapshot(
            id: "wrong-window", pid: 1001, bundleIdentifier: IncomingAnswerControlMatcher.ownerBundleIdentifier,
            role: "AXButton", subrole: nil, axIdentifier: nil, title: nil, elementDescription: "응답",
            enabled: true, actions: ["AXPress"], firstObservedAt: Date(),
            ancestorChain: [AXAncestorDescriptor(role: "AXWindow", subrole: "AXStandardWindow", axIdentifier: nil)]
        )
        let diagnostics = FaceTimeNotificationCallStateClassifier.classifyWithDiagnostics(from: [wrongWindowSubrole])
        XCTAssertTrue(diagnostics.ownerMatched)
        XCTAssertFalse(diagnostics.systemDialogMatched)
        XCTAssertFalse(diagnostics.bannerFound)
        XCTAssertEqual(diagnostics.state, .none)
    }

    func testClassificationDiagnosticsFunnelReflectsFullMatch() {
        let diagnostics = FaceTimeNotificationCallStateClassifier.classifyWithDiagnostics(from: TestSnapshots.activeCallBannerFixture())
        XCTAssertTrue(diagnostics.bannerFound)
        XCTAssertTrue(diagnostics.ownerMatched)
        XCTAssertTrue(diagnostics.systemDialogMatched)
        XCTAssertTrue(diagnostics.notificationBannerMatched)
        XCTAssertTrue(diagnostics.identifierMatched)
        XCTAssertTrue(diagnostics.activeSignatureMatched)
        XCTAssertFalse(diagnostics.ringingSignatureMatched)
        XCTAssertEqual(diagnostics.state, .active)
    }
}
