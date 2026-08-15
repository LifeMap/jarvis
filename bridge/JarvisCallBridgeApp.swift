import SwiftUI

@main
struct JarvisCallBridgeApp: App {
    @StateObject private var model = FeasibilityModel()

    var body: some Scene {
        WindowGroup("Jarvis Call Bridge — Feasibility") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 700)
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: FeasibilityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jarvis Call Bridge — CB Phase 0 (Phone.app)")
                .font(.title2.bold())
            Text("Implemented does not mean verified. Only a real iPhone cellular call can produce a PASS result.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                row("Continuity Call (public API)", model.calls.state.rawValue)
                row("Call State (AX guess)", model.callGuess.state.rawValue)
                Divider()
                row("RX Source", model.rx.sourceName)
                row("RX Audio", model.rx.state.rawValue)
                row("RX Buffers", String(model.rx.bufferCount))
                row("RX RMS / Peak", rmsLabel(model.rx.currentRMSdB, model.rx.peakRMSdB))
                row("RX Diagnostic", model.rx.diagnosticState.rawValue)
                row("RX Diagnostic File", model.rx.diagnosticFilePath ?? "—")
                Divider()
                row("TX Local Smoke Test", model.tx.state.rawValue)
                row("TX Virtual Mic", model.vmicTX.state.rawValue)
                row("TX Virtual Mic RMS", model.vmicTX.currentRMSdB.isFinite ? String(format: "%.1f dB", model.vmicTX.currentRMSdB) : "-inf")
                row("TX Underruns", String(model.vmicTX.underrunCount))
                Divider()
                row("RX/TX Separation", "Unknown / Requires Real Call")
                row("Simultaneous Test", model.simultaneousTestRunning ? "Running" : "Stopped")
            }

            HStack {
                Button("Start Test") { Task { await model.start() } }
                    .disabled(model.running)
                Button("Stop Test") { Task { await model.stop() } }
                    .disabled(!model.running)
            }

            HStack {
                Button("Start RX Diagnostic Capture (8s WAV)") { model.rx.startDiagnosticCapture() }
                    .disabled(!model.running || model.rx.diagnosticState == .recording)
                Button("Stop RX Diagnostic Capture") { model.rx.stopDiagnosticCapture() }
                    .disabled(model.rx.diagnosticState != .recording)
                Text("CB Phase 0-2: dumps Phone.app RX only — not the production recording pipeline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Play 1s Diagnostic Tone (local speaker only)") { model.tx.playDiagnosticTone() }
                Text("NOT TX — local output only")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Start TX Test Tone (Virtual Mic)") { model.vmicTX.playTestTone() }
                    .disabled(!model.running)
                Button("Start TX Speech Sample (Virtual Mic)") { model.vmicTX.playSpeechSample() }
                    .disabled(!model.running)
                Button("Stop TX Virtual Mic") { model.vmicTX.stopPlayback() }
                    .disabled(!model.running)
            }

            HStack {
                Button("Start Simultaneous RX/TX Test") { model.startSimultaneousTest() }
                    .disabled(!model.running || model.simultaneousTestRunning)
                Button("Stop Simultaneous RX/TX Test") { model.stopSimultaneousTest() }
                    .disabled(!model.simultaneousTestRunning)
                Button("Dump Phone.app AX Tree") { model.callGuess.dumpAXTree() }
                    .disabled(!model.running)
            }

            Text("Logs")
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.logger.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
        }
        .padding(20)
    }

    private func rmsLabel(_ current: Double, _ peak: Double) -> String {
        let currentLabel = current.isFinite ? String(format: "%.1f dB", current) : "-inf"
        let peakLabel = peak.isFinite ? String(format: "%.1f dB", peak) : "-inf"
        return "\(currentLabel) / peak \(peakLabel)"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}
