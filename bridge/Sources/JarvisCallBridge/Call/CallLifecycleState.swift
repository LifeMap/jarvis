import Foundation

/// Call lifecycle is deliberately modeled separately from `BridgeState` (PRD §5): `BridgeState`
/// answers "is Work Mode on / is the Bridge ready", `CallLifecycleState` answers "what is the
/// current phone call doing". Phase 2 has no AI, so `.answering`/`.active` here never imply an AI
/// is connected — they only describe what Accessibility evidence says about the native call.
enum CallLifecycleState: String, Equatable {
    case idle = "Idle"
    case ringing = "Ringing"
    case answering = "Answering"
    case active = "Active"
    case ending = "Ending"
    case ended = "Ended"
    /// Evidence is insufficient or contradictory. No automatic action is ever taken from this
    /// state — see AutoAnswerController, which refuses to press anything unless the caller-side
    /// state is unambiguously `.ringing`.
    case unknown = "Unknown"
}

/// A single ring-to-hangup occurrence, used to deduplicate repeated AX events/notifications about
/// the same physical call (PRD §14) and to guarantee at most one auto-answer attempt per call.
struct CallSession: Equatable, Identifiable {
    let id: String
    let startedAt: Date
    var displayCaller: String?

    init(id: String = UUID().uuidString, startedAt: Date = Date(), displayCaller: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.displayCaller = displayCaller
    }
}
