@MainActor
protocol RealtimeVoiceSessionControlling: AnyObject {
    func prepare(reason: String) async
    func connect(reason: String) async
    func disconnect(reason: String) async
    func stopRecording() async
    func finalizeIdleReport() async
}
