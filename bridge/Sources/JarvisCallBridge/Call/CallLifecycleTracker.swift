import Foundation

/// Turns periodic AX observations into `CallLifecycleState` transitions. Deliberately takes plain
/// data (`[AnswerCandidate]`, `CallStateEvidence`) rather than talking to Accessibility itself, so
/// it's fully unit-testable (PRD §29).
///
/// Recognizes both auto-answered and manually-answered calls the same way — ringing→active is
/// evidence-based, not tied to whether *we* pressed anything (PRD §18: "자동으로 받았든 사용자가
/// 직접 받았든 CallLifecycleTracker는 active call을 인식해야 한다").
@MainActor
final class CallLifecycleTracker: ObservableObject {
    @Published private(set) var state: CallLifecycleState = .idle
    @Published private(set) var currentSession: CallSession?

    /// PRD §20: a momentary AX tree refresh must not be mistaken for the call actually ending.
    let endDebounceInterval: TimeInterval
    private var pendingEndSince: Date?

    /// CHECKPOINT 3 Ringing → Active Transition Grace Fix: real-device evidence measured an
    /// approximately 1.508s gap after a manual/auto answer during which macOS's native
    /// `FACETIME_NOTIFICATION` banner has already dropped the ringing controls (응답/거절) but has
    /// not yet shown the active-call controls (종료/소리 끔/키패드) — neither `hasAnyCandidate` nor
    /// `isActiveEvidence` is true during that window. The previous implementation treated that gap
    /// as "caller hung up" and closed the session before Active ever appeared. This is a distinct
    /// timer from `endDebounceInterval` on purpose (§12): it governs the ringing→active UI
    /// transition, never active-call termination, which keeps its own separate debounce below.
    /// 2.5s gives roughly 1s of margin over the measured ~1.5s real transition.
    let answerTransitionGrace: TimeInterval
    private var pendingAnswerTransitionSince: Date?

    private let logger: BridgeLogger
    private let now: () -> Date

    init(endDebounceInterval: TimeInterval = 1.0, answerTransitionGrace: TimeInterval = 2.5, logger: BridgeLogger, now: @escaping () -> Date = Date.init) {
        self.endDebounceInterval = endDebounceInterval
        self.answerTransitionGrace = answerTransitionGrace
        self.logger = logger
        self.now = now
    }

    /// Called once per observation cycle (event or poll) with the current best-known evidence.
    /// `hasAnyCandidate` reflects whether `AnswerCandidateResolver` found *any* answer-button-like
    /// element, regardless of confidence — ringing detection itself has a lower bar than the
    /// confidence gate AutoAnswerController applies before pressing anything.
    func update(hasAnyCandidate: Bool, evidence: CallStateEvidence, displayCaller: String? = nil) {
        switch state {
        case .idle, .ended:
            if hasAnyCandidate {
                let session = CallSession(displayCaller: displayCaller)
                currentSession = session
                transition(to: .ringing)
                logger.log("[CALL] candidate discovered, session=\(session.id)")
            }

        case .ringing, .answering:
            if isActiveEvidence(evidence) {
                // Active wins immediately — never wait out the rest of the grace window once
                // verified active evidence actually appears (§9).
                let wasTransitioning = pendingAnswerTransitionSince != nil
                pendingAnswerTransitionSince = nil
                pendingEndSince = nil
                transition(to: .active)
                if wasTransitioning {
                    logger.log("[CALL] active evidence acquired during answer transition session=\(currentSession?.id ?? "?")")
                }
            } else if hasAnyCandidate {
                // Ringing signature present (still, or returned) — cancel any pending transition
                // and leave state as-is. Deliberately does NOT force `.answering` back to
                // `.ringing`: a stale candidate briefly reappearing right after a real press must
                // not visually demote the state (AutoAnswerController's own dedup already prevents
                // any duplicate press regardless of this label).
                if pendingAnswerTransitionSince != nil {
                    pendingAnswerTransitionSince = nil
                    logger.log("[CALL] ringing signature returned during answer transition session=\(currentSession?.id ?? "?")")
                }
            } else if let since = pendingAnswerTransitionSince {
                if now().timeIntervalSince(since) >= answerTransitionGrace {
                    logger.log("[CALL] answer transition grace expired without active evidence session=\(currentSession?.id ?? "?")")
                    finishSession(to: .idle)
                }
                // else: still within the grace window — remain pending, no per-tick log spam.
            } else {
                // Neither ringing nor active evidence, and no grace in progress yet — this is
                // either the start of a real answer transition or the start of a caller hangup;
                // both look identical at this instant, so start the bounded grace rather than
                // guessing (§7).
                pendingAnswerTransitionSince = now()
                transition(to: .answering)
                logger.log("[CALL] answer transition grace started session=\(currentSession?.id ?? "?") graceMs=\(Int(answerTransitionGrace * 1000))")
            }

        case .active:
            if isActiveEvidence(evidence) {
                pendingEndSince = nil
            } else {
                if pendingEndSince == nil {
                    pendingEndSince = now()
                    transition(to: .ending)
                    logger.log("[CALL] active evidence disappeared, debouncing before declaring ended")
                } else if now().timeIntervalSince(pendingEndSince!) >= endDebounceInterval {
                    finishSession(to: .idle)
                }
            }

        case .ending:
            if isActiveEvidence(evidence) {
                // False alarm — evidence came back within the debounce window.
                pendingEndSince = nil
                transition(to: .active)
                logger.log("[CALL] active evidence returned during debounce — call is still active")
            } else if let since = pendingEndSince, now().timeIntervalSince(since) >= endDebounceInterval {
                finishSession(to: .idle)
            }

        case .unknown:
            break
        }
    }

    /// Called by AutoAnswerController immediately after a successful AXPress, so the UI reflects
    /// "we just pressed" even before the next evidence poll confirms `.active`.
    func markAnswering() {
        guard state == .ringing else { return }
        transition(to: .answering)
    }

    func markUnknown(reason: String) {
        logger.log("[CALL] lifecycle=unknown reason=\(reason)")
        pendingEndSince = nil
        pendingAnswerTransitionSince = nil
        transition(to: .unknown)
    }

    func reset() {
        pendingEndSince = nil
        pendingAnswerTransitionSince = nil
        currentSession = nil
        transition(to: .idle)
    }

    /// PRD §19: button disappearance alone never proves an active call — require at least one
    /// positive "this looks like an active call" signal in addition to the answer button being
    /// gone. `evidence` bundles that combination.
    private func isActiveEvidence(_ evidence: CallStateEvidence) -> Bool {
        !evidence.answerButtonPresent &&
        (evidence.endCallButtonPresent || evidence.activeCallControlsPresent || evidence.callDurationUIPresent)
    }

    private func finishSession(to newState: CallLifecycleState) {
        pendingEndSince = nil
        pendingAnswerTransitionSince = nil
        currentSession = nil
        transition(to: newState)
    }

    private func transition(to newState: CallLifecycleState) {
        guard state != newState else { return }
        state = newState
        logger.log("[CALL] lifecycle=\(newState.rawValue.lowercased())")
    }
}
