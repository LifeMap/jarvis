enum RealtimeVoiceUIState: Equatable {
    case idle
    case armed
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .armed: return "Armed"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed(let reason): return "Failed — \(reason)"
        }
    }
}
