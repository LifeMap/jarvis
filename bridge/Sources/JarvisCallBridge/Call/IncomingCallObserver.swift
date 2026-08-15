import Foundation

/// Ties scanning + candidate resolution + lifecycle tracking + auto-answer together on a bounded,
/// low-frequency poll loop. PRD §9 ranks event-driven `AXObserver` above polling, but the real
/// incoming-call notification structure is unknown until CHECKPOINT 2 runs against a live call —
/// starting with bounded polling (not busy-polling) is the honest, safe choice for this Phase, and
/// is called out explicitly in the Phase 2 report rather than claimed as event-driven.
@MainActor
final class IncomingCallObserver: ObservableObject {
    @Published private(set) var candidates: [AnswerCandidate] = []
    @Published private(set) var lastEvidence: CallStateEvidence = .none

    private let scanner: AccessibilityScanning
    private let tracker: CallLifecycleTracker
    private let autoAnswer: AutoAnswerController
    private let logger: BridgeLogger
    private let pollInterval: TimeInterval
    private let workModeArmedProvider: () -> Bool

    private var timer: Timer?

    init(
        scanner: AccessibilityScanning,
        tracker: CallLifecycleTracker,
        autoAnswer: AutoAnswerController,
        logger: BridgeLogger,
        pollInterval: TimeInterval = 0.75,
        workModeArmedProvider: @escaping () -> Bool
    ) {
        self.scanner = scanner
        self.tracker = tracker
        self.autoAnswer = autoAnswer
        self.logger = logger
        self.pollInterval = pollInterval
        self.workModeArmedProvider = workModeArmedProvider
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard workModeArmedProvider() else {
            if tracker.state != .idle {
                tracker.reset()
                autoAnswer.resetForNewCall()
            }
            candidates = []
            lastEvidence = .none
            return
        }

        // CHECKPOINT 3 §11: candidates and evidence must come from the *same* scan cycle — calling
        // `scanner.currentCallStateEvidence()` separately would re-scan the live AX tree a second
        // time, risking a race where the answer candidate disappears (banner transformed to the
        // active-call controls) between the two scans, and the tracker sees "no candidate" with
        // stale/empty evidence and incorrectly treats a just-answered call as ended.
        let snapshots = scanner.scanCallRelevantElements()
        let resolved = AnswerCandidateResolver.resolve(from: snapshots)
        candidates = resolved

        let evidence = CallStateEvidenceExtractor.extract(from: snapshots)
        lastEvidence = evidence

        // CHECKPOINT 3 Production/Focused AX Parity Diagnostic (§4): concise, privacy-safe
        // semantic logging — only logged when a real FACETIME_NOTIFICATION banner is actually
        // found, and only ever the known structural control labels, never caller names/phone
        // numbers/raw notification text.
        let classification = FaceTimeNotificationCallStateClassifier.classifyWithDiagnostics(from: snapshots)
        if classification.bannerFound {
            logger.log("[CALL-SCAN] banner=true owner=\(IncomingAnswerControlMatcher.ownerBundleIdentifier) windowSubrole=\(IncomingAnswerControlMatcher.windowSubrole) controls=\(classification.controlsDetected.joined(separator: ",")) ringing=\(classification.ringingSignatureMatched) active=\(classification.activeSignatureMatched)")
        }

        let wasIdle = tracker.state == .idle || tracker.state == .ended
        tracker.update(hasAnyCandidate: !resolved.isEmpty, evidence: evidence)
        if !wasIdle && (tracker.state == .idle) {
            autoAnswer.resetForNewCall()
        }

        autoAnswer.evaluate(candidates: resolved, workModeArmed: workModeArmedProvider())
    }

    /// Read-only diagnostic (PRD §10, §26): dumps every scanned element's attributes to the log.
    /// Never clicks, never changes focus, only runs when explicitly invoked.
    func dumpDiagnosticSnapshot() {
        let snapshots = scanner.scanCallRelevantElements()
        logger.log("[AX-DUMP] \(snapshots.count) call-relevant element(s) found")
        for snapshot in snapshots {
            logger.log("[AX-DUMP] pid=\(snapshot.pid) bundle=\(snapshot.bundleIdentifier ?? "?") role=\(snapshot.role ?? "?") subrole=\(snapshot.subrole ?? "-") identifier=\(snapshot.axIdentifier ?? "-") title=\"\(snapshot.title ?? "")\" description=\"\(snapshot.elementDescription ?? "")\" enabled=\(snapshot.enabled) actions=\(snapshot.actions)")
        }
        let evidence = scanner.currentCallStateEvidence()
        logger.log("[AX-DUMP] evidence answer=\(evidence.answerButtonPresent) end=\(evidence.endCallButtonPresent) activeControls=\(evidence.activeCallControlsPresent) duration=\(evidence.callDurationUIPresent)")
    }
}
