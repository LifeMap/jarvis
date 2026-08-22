import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: BridgeViewModel
    // Nested ObservableObjects need their own @ObservedObject in this view — SwiftUI does not
    // propagate change notifications through a plain `let` property on `model` for you.
    @ObservedObject var callTracker: CallLifecycleTracker
    @ObservedObject var autoAnswer: AutoAnswerController
    @ObservedObject var incomingCallObserver: IncomingCallObserver
    @ObservedObject var callAudioSession: CallAudioSessionController
    @ObservedObject var pcmController: SystemCallAudioPCMController
    @ObservedObject var realtimeSession: OpenAIRealtimeVoiceSessionController
    @State private var focusedSnapshotLabel = "baseline"
    private static let focusedSnapshotLabels = ["baseline", "ringing", "active", "ended"]

    init(model: BridgeViewModel) {
        self.model = model
        self.callTracker = model.callTracker
        self.autoAnswer = model.autoAnswer
        self.incomingCallObserver = model.incomingCallObserver
        self.callAudioSession = model.callAudioSession
        self.pcmController = model.pcmController
        self.realtimeSession = model.realtimeSessionController
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Jarvis Call Bridge")
                    .font(.title2.bold())

                HStack {
                    Text("Work Mode")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.stateMachine.workModeEnabled },
                        set: { model.setWorkMode($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                    GridRow {
                        Text("Bridge State").foregroundStyle(.secondary)
                        Text(model.stateMachine.state.rawValue).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Phone.app").foregroundStyle(.secondary)
                        Text(model.phoneApp.isAvailable ? "Available" : "Not Found")
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("").foregroundStyle(.secondary)
                        Text(model.phoneApp.runState.rawValue).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Accessibility").foregroundStyle(.secondary)
                        Text(model.accessibility.isGranted ? "Granted" : "Required")
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Audio Route — Input").foregroundStyle(.secondary)
                        Text(model.routeSnapshot?.defaultInputName ?? "Unknown").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Audio Route — Output").foregroundStyle(.secondary)
                        Text(model.routeSnapshot?.defaultOutputName ?? "Unknown").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Audio Route — System Output").foregroundStyle(.secondary)
                        Text(model.routeSnapshot?.defaultSystemOutputName ?? "Unknown").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Call Audio Driver").foregroundStyle(.secondary)
                        Text(model.audioDriver.state.rawValue).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Realtime").foregroundStyle(.secondary)
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { model.realtimeEnabled },
                                set: { model.setRealtimeEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            Text(realtimeSession.uiState.label)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                HStack {
                    Button("Grant Accessibility…") { model.accessibility.requestPermissionPrompt() }
                    Button("Refresh Audio Route Snapshot") { model.refreshRouteSnapshot() }
                }

                Divider()

                Text("Call").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                    GridRow {
                        Text("State").foregroundStyle(.secondary)
                        Text(callTracker.state.rawValue).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Caller").foregroundStyle(.secondary)
                        Text(callTracker.currentSession?.displayCaller ?? "—").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Candidates").foregroundStyle(.secondary)
                        Text("\(incomingCallObserver.candidates.count) found").font(.system(.body, design: .monospaced))
                    }
                }

                Divider()

                Text("Call Audio (Phase 3)").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                    GridRow {
                        Text("Call Audio State").foregroundStyle(.secondary)
                        Text(callAudioSession.state.rawValue).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Route Owner").foregroundStyle(.secondary)
                        Text(callAudioSession.routeOwnerSessionID.map { String($0.prefix(8)) } ?? "—").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Original Route Snapshot").foregroundStyle(.secondary)
                        Text(callAudioSession.routeOwnerSessionID != nil ? "Available" : "None").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Recovery Record").foregroundStyle(.secondary)
                        Text(callAudioSession.hasPersistedRecoveryRecord ? "Present" : "None").font(.system(.body, design: .monospaced))
                    }
                }

                Divider()

                Text("Call PCM (Phase 3 CHECKPOINT 2)").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                    GridRow {
                        Text("PCM I/O State").foregroundStyle(.secondary)
                        Text(pcmController.state.rawValue).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("PCM Format").foregroundStyle(.secondary)
                        Text(pcmController.format?.description ?? "—").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("RX Frames").foregroundStyle(.secondary)
                        Text("\(pcmController.metrics.rxFrames)").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("RX Callbacks").foregroundStyle(.secondary)
                        Text("\(pcmController.metrics.rxCallbacks)").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("RX RMS / Peak").foregroundStyle(.secondary)
                        Text(String(format: "%.1f dBFS / %.1f dBFS", pcmController.metrics.rxRMSDBFS, pcmController.metrics.rxPeakDBFS)).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("RX Activity").foregroundStyle(.secondary)
                        Text(pcmController.metrics.rxActive ? "Active" : "Silence").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("TX Frames").foregroundStyle(.secondary)
                        Text("\(pcmController.metrics.txFrames)").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("TX Callbacks").foregroundStyle(.secondary)
                        Text("\(pcmController.metrics.txCallbacks)").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("TX Underruns").foregroundStyle(.secondary)
                        Text("\(pcmController.metrics.txUnderrunCount)").font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Test Tone").foregroundStyle(.secondary)
                        Text(pcmController.testToneState.rawValue).font(.system(.body, design: .monospaced))
                    }
                }

                HStack {
                    // §16/§17 — only enabled while an actual routed call already has PCM running;
                    // structurally cannot open Capture/Inject, activate the driver, or change
                    // routes itself — it only queues the fixed diagnostic tone into an
                    // already-running TX path.
                    Button("Send 1 kHz Test Tone") { pcmController.sendTestTone() }
                        .disabled(!(callAudioSession.state == .routed && pcmController.state == .running))
                }

                HStack {
                    Text("Auto Answer").foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { autoAnswer.isEnabled },
                        set: { autoAnswer.isEnabled = $0 }
                    )).labelsHidden().toggleStyle(.switch)
                    Spacer()
                    Text("Delay").foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { autoAnswer.delaySeconds },
                        set: { autoAnswer.delaySeconds = $0 }
                    )) {
                        Text("Immediate").tag(0.0)
                        Text("1 sec").tag(1.0)
                        Text("3 sec").tag(3.0)
                        Text("5 sec").tag(5.0)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                if let remaining = autoAnswer.countdownRemaining {
                    Text(String(format: "Auto answer in: %.1f sec", remaining))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let result = autoAnswer.lastAttemptResult {
                    Text("Last attempt: \(result) (attempts: \(autoAnswer.attemptCount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Dump Incoming AX Snapshot (filtered, read-only)") { incomingCallObserver.dumpDiagnosticSnapshot() }
                    Button("Dump Raw AX Discovery Snapshot (unfiltered, read-only)") { model.dumpRawAXDiscovery() }
                }
                HStack {
                    Button("Copy Raw AX Snapshot") { copyRawAXSnapshot() }
                        .disabled(model.lastRawDiagnosticSnapshot == nil)
                    Button("Save Raw AX Snapshot…") { saveRawAXSnapshot() }
                        .disabled(model.lastRawDiagnosticSnapshot == nil)
                    Text("Full per-window/per-element detail — not shown in Logs below (too large for the log buffer).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Start AX Event Diagnostics (45s, read-only)") { model.startEventDiagnostics() }
                        .disabled(model.lastRawDiagnosticSnapshot == nil || model.isEventDiagnosticsRunning)
                    Button("Stop AX Event Diagnostics") { model.stopEventDiagnostics() }
                        .disabled(!model.isEventDiagnosticsRunning)
                    Text("Run the raw dump first — event diagnostics watches whatever it found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Focused Call AX Snapshot").font(.headline)
                Text("Fast, narrow (Phone.app / Notification Center / FaceTime notification helpers only) — for capturing a transient ringing UI before it disappears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Label").foregroundStyle(.secondary)
                    Picker("", selection: $focusedSnapshotLabel) {
                        ForEach(Self.focusedSnapshotLabels, id: \.self) { label in
                            Text(label).tag(label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button("Capture Focused Call AX Snapshot") { model.captureFocusedCallAXSnapshot(label: focusedSnapshotLabel) }
                }
                HStack {
                    Button("Copy Focused Call AX Snapshot") { copyFocusedCallAXSnapshot() }
                        .disabled(model.lastFocusedCallSnapshot == nil)
                    Button("Save Focused Call AX Snapshot…") { saveFocusedCallAXSnapshot() }
                        .disabled(model.lastFocusedCallSnapshot == nil)
                }

                Text(model.statusMessage)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))

                HStack {
                    Text("Logs")
                        .font(.headline)
                    Spacer()
                    Button("Copy All Logs") { copyAllLogs() }
                    Button("Save Logs…") { saveLogs() }
                }
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.logger.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            }
            .padding(20)
        }
        .onAppear {
            // First HAL query after a driver reinstall can block for a long time. Don't do
            // it inside the appear transaction or the window never commits.
            DispatchQueue.main.async {
                model.start()
            }
        }
    }

    /// CHECKPOINT 2 diagnostic UX: copies the entire current in-memory log buffer (not just what's
    /// currently scrolled into view) as one newline-joined plain-text string.
    private func copyAllLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.logger.exportText(), forType: .string)
    }

    private func saveLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LogExport.defaultFileName()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.logger.exportText().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Diagnostic Fix #2: exports the dedicated `AXDiagnosticSnapshot`, not the normal log
    /// buffer — kept as its own pasteboard/file action so raw AX detail and normal logs are never
    /// mixed up.
    private func copyRawAXSnapshot() {
        guard let snapshot = model.lastRawDiagnosticSnapshot else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.renderText(), forType: .string)
    }

    private func saveRawAXSnapshot() {
        guard let snapshot = model.lastRawDiagnosticSnapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AXSnapshotExport.defaultFileName()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? snapshot.renderText().write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyFocusedCallAXSnapshot() {
        guard let snapshot = model.lastFocusedCallSnapshot else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.renderText(), forType: .string)
    }

    private func saveFocusedCallAXSnapshot() {
        guard let snapshot = model.lastFocusedCallSnapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AXSnapshotExport.focusedCallFileName()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? snapshot.renderText().write(to: url, atomically: true, encoding: .utf8)
    }
}
