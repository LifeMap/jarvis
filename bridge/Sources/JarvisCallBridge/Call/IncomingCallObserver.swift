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
    /// Phase 3 CHECKPOINT 1: nil in any wiring that doesn't need audio takeover (e.g. a future
    /// test double) — when present, driven from this exact same poll cycle, right after
    /// `tracker.update(...)`, so audio-route decisions see the identical lifecycle state
    /// `IncomingCallObserver` itself just computed (no separate timer, no second race window).
    private let callAudioSession: CallAudioSessionController?
    private let logger: BridgeLogger
    private let pollInterval: TimeInterval
    private let workModeArmedProvider: () -> Bool

    private var timer: Timer?
    /// Reentrancy guard: `tick()` is `async` (route convergence polling inside
    /// `CallAudioSessionController` can take up to several hundred ms), so a slow tick could still
    /// be running when the next 750ms timer fires. Two overlapping ticks racing the same
    /// `CallLifecycleTracker`/`CallAudioSessionController` would defeat the "one scan cycle drives
    /// one decision" principle this file already depends on — this guard simply skips a timer fire
    /// that lands while the previous tick hasn't finished yet, rather than letting them interleave.
    private var isTicking = false
    /// `start()` schedules an immediate `Task { tick() }` in addition to the repeating timer.
    /// `stop()` bumps this so that already-queued Task cannot still mutate audio after the
    /// observer has been torn down (tests call `start()` then drive `handleLifecycleChange`
    /// themselves; a stale first tick would idle-preempt underneath them).
    private var startGeneration = 0

    init(
        scanner: AccessibilityScanning,
        tracker: CallLifecycleTracker,
        autoAnswer: AutoAnswerController,
        callAudioSession: CallAudioSessionController? = nil,
        logger: BridgeLogger,
        pollInterval: TimeInterval = 0.75,
        workModeArmedProvider: @escaping () -> Bool
    ) {
        self.scanner = scanner
        self.tracker = tracker
        self.autoAnswer = autoAnswer
        self.callAudioSession = callAudioSession
        self.logger = logger
        self.pollInterval = pollInterval
        self.workModeArmedProvider = workModeArmedProvider
    }

    func start() {
        stop()
        startGeneration += 1
        let generation = startGeneration
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.startGeneration == generation else { return }
                await self.tick()
            }
        }
        Task { @MainActor [weak self] in
            guard let self, self.startGeneration == generation else { return }
            await self.tick()
        }
    }

    func stop() {
        startGeneration += 1
        timer?.invalidate()
        timer = nil
    }

    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        guard workModeArmedProvider() else {
            if tracker.state != .idle {
                tracker.reset()
                autoAnswer.resetForNewCall()
            }
            candidates = []
            lastEvidence = .none
            // Phase 3 §16: Work Mode OFF / Bridge disabled is an immediate safety-restore
            // condition even if a call was mid-Active when it happened.
            await callAudioSession?.emergencyRestore(reason: "work-mode-off")
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

        // Phase 3 CHECKPOINT 1: audio route takeover/restore, driven by the exact lifecycle state
        // just computed above — never its own independent poll.
        await callAudioSession?.handleLifecycleChange(callState: tracker.state, session: tracker.currentSession, workModeArmed: workModeArmedProvider())
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
