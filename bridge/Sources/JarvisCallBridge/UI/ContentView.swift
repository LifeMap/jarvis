import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BridgeViewModel

    var body: some View {
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
                    Text("Not installed — Phase 1").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Realtime").foregroundStyle(.secondary)
                    Text("Not implemented — Phase 4").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Grant Accessibility…") { model.accessibility.requestPermissionPrompt() }
                Button("Refresh Audio Route Snapshot") { model.refreshRouteSnapshot() }
            }

            Text(model.statusMessage)
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))

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
        .onAppear { model.start() }
    }
}
