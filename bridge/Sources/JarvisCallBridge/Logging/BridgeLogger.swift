import Foundation

/// Structured, timestamped log for CB v2. Never logs secrets/credentials/raw PCM (PRD §30) —
/// Phase 0 never touches audio at all, so that constraint is trivially satisfied here.
@MainActor
final class BridgeLogger: ObservableObject {
    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        print(line)
    }
}
