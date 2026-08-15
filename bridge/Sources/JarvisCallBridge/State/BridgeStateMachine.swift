import Foundation

/// CB v2 Phase 0's central invariant: Work Mode toggling only ever moves between `.disabled` and
/// `.armed`, and never touches audio routing. `routeMutator` exists purely so tests can prove
/// that invariant with a spy — production wiring never provides one that does anything, and
/// nothing in this Phase calls it regardless (see docs/Jarvis_Call_Bridge_Client_PRD.md §7, §9).
@MainActor
final class BridgeStateMachine: ObservableObject {
    @Published private(set) var state: BridgeState = .disabled
    @Published private(set) var workModeEnabled = false

    /// The only transitions CB v2 Phase 0 permits. Every other `BridgeState` case exists for
    /// later phases and is intentionally unreachable here.
    private static let allowedTransitions: [BridgeState: Set<BridgeState>] = [
        .disabled: [.armed],
        .armed: [.disabled]
    ]

    private let routeMutator: AudioRouteMutating?
    private let logger: BridgeLogger

    init(routeMutator: AudioRouteMutating? = nil, logger: BridgeLogger) {
        self.routeMutator = routeMutator
        self.logger = logger
    }

    func setWorkMode(_ enabled: Bool) {
        workModeEnabled = enabled
        let target: BridgeState = enabled ? .armed : .disabled
        logger.log("[BRIDGE] workMode=\(enabled)")
        _ = requestTransition(to: target)
        // Deliberately does not call routeMutator here or anywhere else in Phase 0 — Work Mode
        // ARMED must never create, read-modify, or change any audio route (PRD §9, §12).
    }

    /// Returns false and leaves `state` unchanged if the transition isn't one of the Phase-0
    /// allowed pair. Exists so later phases can extend `allowedTransitions` without weakening
    /// this guard, and so Phase 0 has something concrete to unit-test against accidental
    /// premature transitions into RINGING/ACTIVE_AI/etc.
    @discardableResult
    func requestTransition(to newState: BridgeState) -> Bool {
        guard Self.allowedTransitions[state]?.contains(newState) == true else {
            logger.log("[BRIDGE] rejected invalid transition from \(state.rawValue) to \(newState.rawValue)")
            return false
        }
        state = newState
        logger.log("[BRIDGE] state=\(state.rawValue.lowercased())")
        return true
    }
}
