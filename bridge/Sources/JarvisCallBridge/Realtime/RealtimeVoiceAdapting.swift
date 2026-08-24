@MainActor
protocol RealtimeVoiceAdapting: AnyObject {
    var onRemoteSpeechStarted: (() -> Void)? { get set }
    var transcript: [CallTranscriptTurn] { get }
    func connect() async -> Bool
    func disconnect() async
    func sendRX(_ pcm16Mono24k: [Int16])
    func pollTX() -> [Int16]
}
