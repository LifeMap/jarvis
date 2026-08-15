import ApplicationServices
import Foundation

/// Aggregates the app's responsibilities (state machine, Phone.app discovery, Accessibility
/// status, read-only audio route snapshot, call lifecycle/auto-answer, logging) for the UI.
@MainActor
final class BridgeViewModel: ObservableObject {
    let logger: BridgeLogger
    let stateMachine: BridgeStateMachine
    let phoneApp: PhoneAppDiscovery
    let accessibility: AccessibilityStatus
    let audioDriver: AudioDriverStatus

    let callTracker: CallLifecycleTracker
    let autoAnswer: AutoAnswerController
    let incomingCallObserver: IncomingCallObserver

    /// nil when `accessibilityScanner` is a test mock — only the real `SystemAccessibilityClient`
    /// implements the raw-discovery/event-diagnostics capabilities (CHECKPOINT 2 fix).
    let rawDiagnostics: AccessibilityRawDiagnosticsProviding?
    @Published private(set) var lastRawDiagnosticSnapshot: AXDiagnosticSnapshot?
    /// Diagnostic Fix #2: tracks actual Event Diagnostics session state so the Start/Stop buttons
    /// in `ContentView` reflect reality instead of always being enabled.
    @Published private(set) var isEventDiagnosticsRunning = false
    @Published private(set) var lastFocusedCallSnapshot: FocusedCallAXSnapshot?

    private let routeReader: AudioRouteReading
    @Published private(set) var routeSnapshot: AudioRouteSnapshot?

    init(
        routeReader: AudioRouteReading = CoreAudioRouteReader(),
        routeMutator: AudioRouteMutating? = nil,
        driverActivator: AudioDriverActivating? = nil,
        accessibilityScanner: AccessibilityScanning = SystemAccessibilityClient()
    ) {
        let logger = BridgeLogger()
        self.logger = logger
        self.stateMachine = BridgeStateMachine(routeMutator: routeMutator, driverActivator: driverActivator, logger: logger)
        self.phoneApp = PhoneAppDiscovery(logger: logger)
        self.accessibility = AccessibilityStatus(logger: logger)
        self.audioDriver = AudioDriverStatus()
        self.routeReader = routeReader
        self.rawDiagnostics = accessibilityScanner as? AccessibilityRawDiagnosticsProviding

        let tracker = CallLifecycleTracker(logger: logger)
        self.callTracker = tracker
        let autoAnswer = AutoAnswerController(scanner: accessibilityScanner, tracker: tracker, logger: logger)
        self.autoAnswer = autoAnswer

        let stateMachineRef = stateMachine
        self.incomingCallObserver = IncomingCallObserver(
            scanner: accessibilityScanner,
            tracker: tracker,
            autoAnswer: autoAnswer,
            logger: logger,
            workModeArmedProvider: { stateMachineRef.state == .armed }
        )
    }

    func start() {
        logger.log("[BRIDGE] app started")
        logger.log("[BRIDGE] state=disabled")
        phoneApp.start()
        accessibility.refresh()
        audioDriver.start()
        refreshRouteSnapshot()
        incomingCallObserver.start()
    }

    func setWorkMode(_ enabled: Bool) {
        stateMachine.setWorkMode(enabled)
        // Read-only observation snapshot for the diagnostic UI — never a write, and taken
        // regardless of Work Mode so the "before/after unchanged" invariant is easy to eyeball.
        refreshRouteSnapshot()
    }

    /// "Dump Raw AX Discovery Snapshot" — unfiltered, bounded, window-scoped, read-only. Unlike
    /// `IncomingCallObserver.dumpDiagnosticSnapshot()` (which shows only what the current
    /// resolver considers call-related), this walks every window on every windowed process, with
    /// no call-semantic keyword filtering at all (CHECKPOINT 2 fix — the filtered dump found 0
    /// elements against a real call, so this exists to find out why). Diagnostic Fix #2: the full
    /// per-window/per-element detail goes only into `lastRawDiagnosticSnapshot`, never into
    /// `BridgeLogger` — a raw pass can produce far more lines than the logger's 500-line retention
    /// can hold, and routing it through the logger silently evicted earlier log history during the
    /// 2nd real-device retest. Only a short summary line is logged; use "Copy/Save Raw AX
    /// Snapshot" for the full detail.
    func dumpRawAXDiscovery() {
        guard let rawDiagnostics else {
            logger.log("[AX-RAW] unavailable — not using the real Accessibility client")
            return
        }
        logger.log("[AX-AUTH] trusted=\(AXIsProcessTrusted())")
        logger.log("[AX-RAW] snapshot started")

        let snapshot = rawDiagnostics.performRawDiscovery(maxDepthPerWindow: 8, maxNodesPerWindow: 500, maxTotalNodes: 5000)
        lastRawDiagnosticSnapshot = snapshot
        guard snapshot.trusted else {
            logger.log("[AX-RAW] not trusted — no scan performed")
            return
        }

        logger.log("[AX-RAW] \(snapshot.summaryLine)")
        logger.log("[AX-RAW] snapshot ready — use Copy/Save Raw AX Snapshot for full detail")
    }

    /// "Capture Focused Call AX Snapshot" — CHECKPOINT 2's fast, narrowly-scoped diagnostic
    /// (target <1-2s), distinct from the slow full raw dump above. `label` is diagnostic metadata
    /// only (baseline/ringing/active/ended); it never influences scanning. Logs only a summary
    /// line — the full detail lives in `lastFocusedCallSnapshot`, exported via Copy/Save Focused
    /// Call AX Snapshot.
    func captureFocusedCallAXSnapshot(label: String?) {
        guard let rawDiagnostics else {
            logger.log("[AX-CALL-FOCUSED] unavailable — not using the real Accessibility client")
            return
        }
        let snapshot = rawDiagnostics.captureFocusedCallAXSnapshot(label: label, maxDepthPerWindow: 8, maxNodesPerWindow: 300)
        lastFocusedCallSnapshot = snapshot
        guard snapshot.trusted else {
            logger.log("[AX-CALL-FOCUSED] not trusted — no scan performed")
            return
        }
        logger.log("[AX-CALL-FOCUSED] \(snapshot.summaryLine)")
    }

    /// "Start AX Event Diagnostics" — secondary to the raw dump above. Bounded duration,
    /// read-only, targets whichever windowed processes the last raw discovery found.
    func startEventDiagnostics(durationSeconds: TimeInterval = 45) {
        guard let rawDiagnostics else {
            logger.log("[AX-EVENT] unavailable — not using the real Accessibility client")
            return
        }
        guard let processes = lastRawDiagnosticSnapshot?.processInventory.filter({ $0.windowCount > 0 }), !processes.isEmpty else {
            logger.log("[AX-EVENT] run Dump Raw AX Discovery Snapshot first — no target processes known yet")
            return
        }
        isEventDiagnosticsRunning = true
        rawDiagnostics.startEventDiagnostics(processes: processes, durationSeconds: durationSeconds, onEvent: { [weak self] message in
            Task { @MainActor in self?.logger.log(message) }
        }, onStopped: { [weak self] in
            Task { @MainActor in self?.isEventDiagnosticsRunning = false }
        })
    }

    func stopEventDiagnostics() {
        rawDiagnostics?.stopEventDiagnostics()
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
            switch callTracker.state {
            case .idle, .ended:
                return "Work Mode armed. Native calls are not modified."
            case .ringing:
                return "Incoming call detected."
            case .answering:
                return "Auto-answer pressed — confirming call is active."
            case .active:
                return "Call active. Jarvis is not participating in the audio."
            case .ending:
                return "Call appears to be ending…"
            case .unknown:
                return "Call state uncertain — no automatic action will be taken."
            }
        default:
            return stateMachine.state.rawValue
        }
    }
}
