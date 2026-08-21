@MainActor
protocol RealtimeVoiceSessionControlling: AnyObject {
    func connect(reason: String) async
    func disconnect(reason: String) async
}
