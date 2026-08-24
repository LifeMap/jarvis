@MainActor
final class NullRealtimeVoiceSessionController: RealtimeVoiceSessionControlling {
    func prepare(reason: String) async {}
    func connect(reason: String) async {}
    func disconnect(reason: String) async {}
    func stopRecording() async {}
    func finalizeIdleReport() async {}
}