import Combine
import Foundation

enum ObservedCallState: String {
    case unavailable = "Public API Not Available"
    case stopped = "Stopped"
}

/// Deliberately does not infer call state from FaceTime process/window activity.
/// CallKit's CXCallObserver is API_UNAVAILABLE(macos) in the public macOS SDK.
@MainActor
final class CallStateMonitor: ObservableObject {
    @Published private(set) var state: ObservedCallState = .stopped
    @Published private(set) var activeCallCount: String = "Unknown"

    private let logger: ProbeLogger

    init(logger: ProbeLogger) {
        self.logger = logger
    }

    func start() {
        state = .unavailable
        activeCallCount = "Unavailable"
        logger.write("[CALL] PUBLIC API / NOT AVAILABLE")
        logger.write("[CALL] CXCallObserver is explicitly unavailable on macOS; FaceTime process/window presence is not treated as call detection")
    }

    func stop() {
        state = .stopped
        activeCallCount = "Unknown"
        logger.write("[CALL] monitor stopped (no public macOS call-state resource was open)")
    }
}
