@MainActor
final class MockRealtimeVoiceAdapter: RealtimeVoiceAdapting {
    var failConnect = false
    private(set) var isConnected = false
    private(set) var sentRX: [[Int16]] = []
    private var txQueue: [[Int16]] = []

    func connect() async -> Bool {
        if failConnect { return false }
        isConnected = true
        return true
    }

    func disconnect() async {
        isConnected = false
        sentRX = []
        txQueue = []
    }

    func sendRX(_ pcm16Mono24k: [Int16]) {
        guard isConnected else { return }
        sentRX.append(pcm16Mono24k)
    }

    func enqueueTX(_ pcm16Mono24k: [Int16]) {
        txQueue.append(pcm16Mono24k)
    }

    func pollTX() -> [Int16] {
        guard isConnected, !txQueue.isEmpty else { return [] }
        return txQueue.removeFirst()
    }
}
