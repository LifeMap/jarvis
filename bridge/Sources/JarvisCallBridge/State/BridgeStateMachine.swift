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
    private let driverActivator: AudioDriverActivating?
    private let logger: BridgeLogger

    init(routeMutator: AudioRouteMutating? = nil, driverActivator: AudioDriverActivating? = nil, logger: BridgeLogger) {
        self.routeMutator = routeMutator
        self.driverActivator = driverActivator
        self.logger = logger
    }

    func setWorkMode(_ enabled: Bool) {
        workModeEnabled = enabled
        let target: BridgeState = enabled ? .armed : .disabled
        logger.log("[BRIDGE] workMode=\(enabled)")
        _ = requestTransition(to: target)
        // Deliberately does not call routeMutator or driverActivator here or anywhere else in
        // Phase 0/1 — ARMED must never create/change any audio route, and ARMED != Audio Driver
        // Active (PRD §9, §12, §23). When Capture/Inject do need to activate for a real call
        // (Phase 2/3), that decision goes through a dedicated call-lifecycle transition, not
        // Work Mode.
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
