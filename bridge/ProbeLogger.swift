import Combine
import Foundation

@MainActor
final class ProbeLogger: ObservableObject {
    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        print(line)
    }
}
