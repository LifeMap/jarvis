import Foundation

/// Full CB v2 lifecycle per docs/Jarvis_Call_Bridge_Client_PRD.md §8. Only `.disabled` and
/// `.armed` are reachable at runtime in CB v2 Phase 0 — the remaining cases are declared now so
/// later phases have a stable enum to build against, but nothing in this Phase ever requests a
/// transition into them (see `BridgeStateMachine.allowedTransitions`).
enum BridgeState: String, Equatable {
    case disabled = "Disabled"
    case armed = "Armed"
    case ringing = "Ringing"
    case preparing = "Preparing"
    case answering = "Answering"
    case activeAI = "Active (AI)"
    case activeHumanMac = "Active (Human, Mac)"
    case handoffToIPhone = "Handoff to iPhone"
    case restoring = "Restoring"
    case error = "Error"
}
