@MainActor
protocol RealtimeVoiceAdapting: AnyObject {
    func connect() async -> Bool
    func disconnect() async
    func sendRX(_ pcm16Mono24k: [Int16])
    func pollTX() -> [Int16]
}
