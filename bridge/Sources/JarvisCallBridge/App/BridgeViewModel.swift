import Foundation

/// Aggregates the Phase-0 responsibilities (state machine, Phone.app discovery, Accessibility
/// status, read-only audio route snapshot, logging) for the UI. Holds no audio/capture state —
/// there isn't any in this Phase.
@MainActor
final class BridgeViewModel: ObservableObject {
    let logger: BridgeLogger
    let stateMachine: BridgeStateMachine
    let phoneApp: PhoneAppDiscovery
    let accessibility: AccessibilityStatus

    private let routeReader: AudioRouteReading
    @Published private(set) var routeSnapshot: AudioRouteSnapshot?

    init(
        routeReader: AudioRouteReading = CoreAudioRouteReader(),
        routeMutator: AudioRouteMutating? = nil
    ) {
        let logger = BridgeLogger()
        self.logger = logger
        self.stateMachine = BridgeStateMachine(routeMutator: routeMutator, logger: logger)
        self.phoneApp = PhoneAppDiscovery(logger: logger)
        self.accessibility = AccessibilityStatus(logger: logger)
        self.routeReader = routeReader
    }

    func start() {
        logger.log("[BRIDGE] app started")
        logger.log("[BRIDGE] state=disabled")
        phoneApp.start()
        accessibility.refresh()
        refreshRouteSnapshot()
    }

    func setWorkMode(_ enabled: Bool) {
        stateMachine.setWorkMode(enabled)
        // Read-only observation snapshot for the diagnostic UI — never a write, and taken
        // regardless of Work Mode so the "before/after unchanged" invariant is easy to eyeball.
        refreshRouteSnapshot()
    }

    func refreshRouteSnapshot() {
        let snapshot = routeReader.currentSnapshot()
        if let snapshot {
            logger.log("[AUDIO] snapshot input=\(snapshot.defaultInputName) output=\(snapshot.defaultOutputName) systemOutput=\(snapshot.defaultSystemOutputName)")
        }
        routeSnapshot = snapshot
    }

    var statusMessage: String {
        switch stateMachine.state {
        case .disabled:
            return "Bridge is idle."
        case .armed:
            return "Work Mode armed. Native calls are not modified."
        default:
            return stateMachine.state.rawValue
        }
    }
}
