@MainActor
final class NullRealtimeVoiceSessionController: RealtimeVoiceSessionControlling {
    func connect(reason: String) async {}
    func disconnect(reason: String) async {}
}