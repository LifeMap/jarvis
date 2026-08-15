import Foundation

/// Schedules and performs the *only* AX click this app ever makes. Every guard here exists
/// because PRD §4's safety principle is absolute: "No confidence → No action. Ambiguous
/// candidate → No action. Multiple candidates → No action. State uncertain → No action."
@MainActor
final class AutoAnswerController: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var delaySeconds: Double = 3
    @Published private(set) var countdownRemaining: Double?
    @Published private(set) var lastAttemptResult: String?
    @Published private(set) var attemptCount: Int = 0

    private let scanner: AccessibilityScanning
    private let tracker: CallLifecycleTracker
    private let logger: BridgeLogger

    private var timerTask: Task<Void, Never>?
    private var attemptedSessionIDs: Set<String> = []
    private var scheduledSessionID: String?

    init(scanner: AccessibilityScanning, tracker: CallLifecycleTracker, logger: BridgeLogger) {
        self.scanner = scanner
        self.tracker = tracker
        self.logger = logger
    }

    /// Called once per observation cycle. Re-validates every condition from scratch each time —
    /// nothing is "trusted" from a previous cycle.
    func evaluate(candidates: [AnswerCandidate], workModeArmed: Bool) {
        guard tracker.state == .ringing, let session = tracker.currentSession else {
            // Covers both "caller hung up before delay" (§14) and "user manually answered before
            // delay" (§15) — both leave the tracker's state as something other than `.ringing`
            // (`.answering`/`.active` for a manual answer, `.idle` for a hangup) by the time this
            // runs, so a single guard safely cancels either way without distinguishing them.
            cancel(reason: "lifecycle-not-ringing")
            return
        }
        guard workModeArmed else {
            cancel(reason: "work-mode-off")
            return
        }
        guard isEnabled else {
            // Detection keeps running (CallLifecycleTracker is unaffected) — only the schedule/
            // press path is skipped when Auto Answer is off (PRD §17.C, CHECKPOINT 2/3).
            cancel(reason: "auto-answer-disabled")
            return
        }
        guard !attemptedSessionIDs.contains(session.id) else {
            return // already attempted for this call — no retry loop (PRD §14, §17). Silent: this
            // guard is hit on every remaining tick of an already-attempted session, and logging it
            // would just be per-tick noise (§13's explicit "avoid cancellation noise" guidance).
        }

        let highConfidence = candidates.filter { $0.confidence == .high }
        guard highConfidence.count == 1, let candidate = highConfidence.first, candidate.snapshot.enabled else {
            if scheduledSessionID == session.id {
                cancel(reason: highConfidence.count > 1 ? "candidate-ambiguous" : "candidate-missing")
            }
            return
        }

        if scheduledSessionID != session.id {
            schedule(session: session, candidate: candidate)
        }
    }

    private func schedule(session: CallSession, candidate: AnswerCandidate) {
        cancelTimerTask()
        scheduledSessionID = session.id
        let delay = max(0, delaySeconds)
        countdownRemaining = delay
        logger.log("[AUTOANSWER] candidate high owner=notificationcenter banner=\(IncomingAnswerControlMatcher.bannerIdentifier) control=answer")
        logger.log("[AUTOANSWER] scheduled delayMs=\(Int(delay * 1000)) session=\(session.id)")

        let stepInterval = max(0.01, min(0.25, delay / 10))

        timerTask = Task { [weak self] in
            guard let self else { return }
            var remaining = delay
            while remaining > 0 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(stepInterval * 1_000_000_000))
                remaining -= stepInterval
                await MainActor.run { self.countdownRemaining = max(0, remaining) }
            }
            if Task.isCancelled { return }
            await MainActor.run { self.attemptPress(session: session, candidate: candidate) }
        }
    }

    private func attemptPress(session: CallSession, candidate: AnswerCandidate) {
        // Final re-validation immediately before the one and only click.
        guard tracker.state == .ringing, tracker.currentSession?.id == session.id else {
            logger.log("[AUTOANSWER] cancelled reason=lifecycle-not-ringing session=\(session.id)")
            countdownRemaining = nil
            scheduledSessionID = nil
            return
        }

        // CHECKPOINT 3 §9: the delay can span several poll ticks, so the snapshot captured at
        // schedule-time may be stale by the time this fires. Re-scan and re-resolve live,
        // immediately before the click, and require the *same* element (by id) to still satisfy
        // the exact evidence-locked matcher. Anything else — disappeared, changed, no longer
        // uniquely high-confidence — cancels the press outright; it never falls back to pressing
        // a different button.
        logger.log("[AUTOANSWER] revalidation pass session=\(session.id)")
        let liveHighConfidence = AnswerCandidateResolver.resolve(from: scanner.scanCallRelevantElements())
            .filter { $0.confidence == .high }
        guard liveHighConfidence.count == 1, let liveCandidate = liveHighConfidence.first,
              liveCandidate.snapshot.id == candidate.snapshot.id else {
            logger.log("[AUTOANSWER] cancelled reason=revalidation-failed session=\(session.id)")
            countdownRemaining = nil
            scheduledSessionID = nil
            return
        }

        attemptedSessionIDs.insert(session.id)
        attemptCount += 1
        logger.log("[AUTOANSWER] press attempted session=\(session.id)")

        switch scanner.press(liveCandidate.snapshot) {
        case .success:
            logger.log("[AUTOANSWER] press result=success session=\(session.id)")
            lastAttemptResult = "Success"
            tracker.markAnswering()
        case .failed(let reason):
            logger.log("[AUTOANSWER] press result=failure reason=\(reason) session=\(session.id)")
            lastAttemptResult = "Failed: \(reason)"
            // No retry — native call UI is left exactly as-is (PRD §17).
        }

        countdownRemaining = nil
        scheduledSessionID = nil
    }

    func cancel(reason: String) {
        guard timerTask != nil else { return }
        cancelTimerTask()
        logger.log("[AUTOANSWER] cancelled reason=\(reason)")
        countdownRemaining = nil
        scheduledSessionID = nil
    }

    /// Clears per-call dedup state — call when returning to `.idle` so the next real call can be
    /// evaluated fresh.
    func resetForNewCall() {
        cancel(reason: "new-call")
    }

    /// Test-only hook: awaits the currently scheduled timer (if any) so tests can deterministically
    /// wait for a scheduled press to either fire or be cancelled, instead of sleeping arbitrarily.
    func waitForScheduledAttempt() async {
        await timerTask?.value
    }

    private func cancelTimerTask() {
        timerTask?.cancel()
        timerTask = nil
    }
}
