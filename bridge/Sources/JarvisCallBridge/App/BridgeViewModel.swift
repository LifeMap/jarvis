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
    /// Phase 3 CHECKPOINT 1 — audio route takeover/restore for a verified Active call.
    let callAudioSession: CallAudioSessionController
    /// Phase 3 CHECKPOINT 2 — Bridge's own CoreAudio Direct I/O. Exposed here as the *concrete*
    /// `SystemCallAudioPCMController` type (not the `CallAudioPCMControlling` protocol
    /// `callAudioSession` coordinates internally) specifically so `ContentView` can bind to it
    /// with `@ObservedObject` — SwiftUI can't observe a protocol existential directly. In
    /// production this is the exact same instance `callAudioSession` drives; when a test injects
    /// its own `callAudioSession` (built with a PCM spy), this is a separate, inert, never-started
    /// placeholder purely so the type is always safe to construct — tests never render SwiftUI, so
    /// they never observe it.
    let pcmController: SystemCallAudioPCMController
    let realtimeSessionController: OpenAIRealtimeVoiceSessionController
    @Published private(set) var realtimeEnabled = false

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
        accessibilityScanner: AccessibilityScanning = SystemAccessibilityClient(),
        callAudioSession: CallAudioSessionController? = nil
    ) {
        let logger = BridgeLogger()
        self.logger = logger
        self.stateMachine = BridgeStateMachine(routeMutator: routeMutator, driverActivator: driverActivator, logger: logger)
        self.phoneApp = PhoneAppDiscovery(logger: logger)
        self.accessibility = AccessibilityStatus(logger: logger)
        self.audioDriver = AudioDriverStatus()
        self.routeReader = routeReader
        self.rawDiagnostics = accessibilityScanner as? AccessibilityRawDiagnosticsProviding
        if let callAudioSession {
            self.callAudioSession = callAudioSession
            let pcm = SystemCallAudioPCMController(logger: logger) // see doc comment — inert in this (test-injected) path
            self.pcmController = pcm
            self.realtimeSessionController = OpenAIRealtimeVoiceSessionController(pcm: pcm)
        } else {
            let pcm = SystemCallAudioPCMController(logger: logger)
            self.pcmController = pcm
            let realtime = OpenAIRealtimeVoiceSessionController(pcm: pcm)
            self.realtimeSessionController = realtime
            self.callAudioSession = CallAudioSessionController(
                pcmController: pcm,
                realtimeSession: realtime,
                processMute: SystemCallAudioProcessMuteController(logger: logger),
                logger: logger
            )
        }

        let tracker = CallLifecycleTracker(logger: logger)
        self.callTracker = tracker
        let autoAnswer = AutoAnswerController(scanner: accessibilityScanner, tracker: tracker, logger: logger)
        self.autoAnswer = autoAnswer

        let stateMachineRef = stateMachine
        self.incomingCallObserver = IncomingCallObserver(
            scanner: accessibilityScanner,
            tracker: tracker,
            autoAnswer: autoAnswer,
            callAudioSession: self.callAudioSession,
            logger: logger,
            workModeArmedProvider: { stateMachineRef.state == .armed }
        )

        // UI synchronization fix: `CallAudioSessionController` owns route *transaction* logic and
        // knows nothing about SwiftUI/`BridgeViewModel` — it only calls this plain closure at the
        // end of every boundary that may have mutated the real CoreAudio route (takeover, restore,
        // rollback, ownership loss, startup recovery). The closure re-reads the actual current
        // route via `routeReader` — it never fabricates a displayed value from `CallAudioSessionState`
        // (e.g. never "state == .routed therefore show the Jarvis device names").
        //
        // Same boundary also drives every real `kJarvisDevicePropertyActive` mutation
        // (`deviceActivator.setCaptureActive`/`setInjectActive` inside takeover/rollback/restore/
        // ownership-loss/startup-recovery all fire before `onRouteMutated`) — but `AudioDriverStatus`
        // previously only refreshed on its own independent 5-second timer, so "Call Audio Driver"
        // could keep showing a stale "Active" for up to 5s after a real, already-logged
        // deactivation. `audioDriver.refresh()` re-reads the actual driver property (never derives
        // from `CallAudioSessionState`), exactly the same philosophy as the route snapshot refresh
        // right above it — a refresh failure here is diagnostic-only and never rolls back or
        // otherwise affects the real audio transaction that triggered it.
        self.callAudioSession.onRouteMutated = { [weak self] reason in
            self?.refreshRouteSnapshot(reason: reason)
            self?.audioDriver.refresh()
        }
    }

    func start() {
        logger.log("[BRIDGE] app started")
        logger.log("[BRIDGE] state=disabled")
        // Phase 3 §21: crash/relaunch audio recovery happens before Work Mode auto-arms, and
        // before the poll loop starts — never mutates Default System Output. If a stale recovery
        // record existed, `onRouteMutated` (wired above) already refreshed the snapshot once; this
        // call still runs unconditionally so the normal (no stale record) launch path — the common
        // case — also starts with a real, non-stale route display.
        callAudioSession.performStartupRecovery()
        phoneApp.start()
        accessibility.refresh()
        audioDriver.start()
        refreshRouteSnapshot(reason: "startup")
        // Phase 3 §3: product default is Work Mode ON at launch. `setWorkMode` itself still never
        // mutates audio — route takeover/process mute wait for a real ringing/active call so a video
        // meeting on the user's speaker keeps working. Auto Answer already defaults to `true`.
        setWorkMode(true)
        incomingCallObserver.start()
    }

    func setRealtimeEnabled(_ enabled: Bool) {
        realtimeEnabled = enabled
        realtimeSessionController.isEnabled = enabled
        Task { [weak self] in
            guard let self else { return }
            if enabled, self.pcmController.isRunning {
                await self.realtimeSessionController.connect(reason: "toggle-on")
            } else if !enabled {
                await self.realtimeSessionController.disconnect(reason: "toggle-off")
            }
        }
    }

    func setWorkMode(_ enabled: Bool) {
        stateMachine.setWorkMode(enabled)
        // Read-only observation snapshot for the diagnostic UI — never a write, and taken
        // regardless of Work Mode so the "before/after unchanged" invariant is easy to eyeball.
        refreshRouteSnapshot(reason: "work-mode-toggle")
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

    /// Single source of truth for the "Audio Route — Input/Output/System Output" UI rows: always a
    /// fresh read of the real CoreAudio default route via `routeReader`, never a value derived
    /// from `callAudioSession.state` or a hardcoded Jarvis device name. Called at app launch, on
    /// the manual "Refresh Audio Route Snapshot" button (`reason` defaults to `"manual"`), and
    /// automatically via `callAudioSession.onRouteMutated` after every route transaction boundary
    /// (takeover/restore/rollback/ownership-loss/startup-recovery) — see that closure's wiring in
    /// `init`. A refresh failure (nil snapshot) is a presentation-layer diagnostic only; it never
    /// feeds back into `callAudioSession`'s own success/failure classification of the route
    /// transaction that triggered it.
    func refreshRouteSnapshot(reason: String = "manual") {
        let snapshot = routeReader.currentSnapshot()
        if let snapshot {
            logger.log("[AUDIO] snapshot refreshed input=\(snapshot.defaultInputName) output=\(snapshot.defaultOutputName) systemOutput=\(snapshot.defaultSystemOutputName) reason=\(reason)")
        } else {
            logger.log("[AUDIO] route snapshot refresh failed reason=\(reason)")
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
                return "Call active. \(callAudioSession.state == .routed ? "Jarvis has taken over call audio routing." : "Jarvis is not participating in the audio.")"
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
