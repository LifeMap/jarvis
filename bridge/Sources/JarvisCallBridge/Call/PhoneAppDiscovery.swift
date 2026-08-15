import AppKit
import Combine
import Foundation

enum PhoneAppRunState: String {
    case notFound = "Not Found"
    case notRunning = "Not Running"
    case running = "Running"
}

/// Read-only, passive discovery of Phone.app. Never launches, focuses, or otherwise touches
/// Phone.app — this Phase's whole point is to prove Jarvis can observe without interfering
/// (PRD §8). Polls at a low, fixed interval; no busy-polling.
@MainActor
final class PhoneAppDiscovery: ObservableObject {
    nonisolated static let bundleIdentifier = "com.apple.mobilephone"

    @Published private(set) var isAvailable = false
    @Published private(set) var runState: PhoneAppRunState = .notFound

    private let logger: BridgeLogger
    private var timer: Timer?
    private let pollInterval: TimeInterval

    init(logger: BridgeLogger, pollInterval: TimeInterval = 5) {
        self.logger = logger
        self.pollInterval = pollInterval
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let available = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty

        if available != isAvailable {
            logger.log("[PHONE] available=\(available)")
        }
        let newRunState: PhoneAppRunState = !available ? .notFound : (running ? .running : .notRunning)
        if newRunState != runState {
            logger.log("[PHONE] running=\(running)")
        }
        isAvailable = available
        runState = newRunState
    }
}
