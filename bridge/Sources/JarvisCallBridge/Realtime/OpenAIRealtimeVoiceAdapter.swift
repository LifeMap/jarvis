import Foundation

@MainActor
final class OpenAIRealtimeVoiceAdapter: RealtimeVoiceAdapting {
    static let defaultInstructions = """
    당신은 전화로 통화 중인 한국어 비서입니다.
    상대가 쓰는 언어로 맞춰, 짧게 자연스럽게 대답하세요.
    """

    private let apiKey: String
    private let model: String
    private let instructions: String
    private let transport: RealtimeWebSocketTransporting
    private var receiveTask: Task<Void, Never>?
    private var txQueue: [[Int16]] = []
    private(set) var isConnected = false

    init(
        apiKey: String,
        model: String,
        transport: RealtimeWebSocketTransporting,
        instructions: String = OpenAIRealtimeVoiceAdapter.defaultInstructions
    ) {
        self.apiKey = apiKey
        self.model = model
        self.instructions = instructions
        self.transport = transport
    }

    func connect() async -> Bool {
        await disconnect()
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else { return false }
        do {
            try await transport.connect(url: url, headers: ["Authorization": "Bearer \(apiKey)"])
            try await transport.send(text: sessionUpdateJSON())
            isConnected = true
            let transport = self.transport
            receiveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let text = try await transport.receive()
                        await self?.ingestServerMessage(text)
                    } catch {
                        break
                    }
                }
            }
            return true
        } catch {
            transport.close()
            isConnected = false
            return false
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        transport.close()
        isConnected = false
        txQueue = []
    }

    func sendRX(_ pcm16Mono24k: [Int16]) {
        guard isConnected, !pcm16Mono24k.isEmpty else { return }
        let payload = Self.base64PCM16(pcm16Mono24k)
        let json = #"{"type":"input_audio_buffer.append","audio":"\#(payload)"}"#
        let transport = self.transport
        Task { try? await transport.send(text: json) }
    }

    func pollTX() -> [Int16] {
        guard !txQueue.isEmpty else { return [] }
        return txQueue.removeFirst()
    }

    func ingestServerMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        switch type {
        case "response.output_audio.delta", "response.audio.delta", "session.output_audio.delta":
            guard let delta = object["delta"] as? String, let samples = Self.decodePCM16(base64: delta) else { return }
            txQueue.append(samples)
        default:
            break
        }
    }

    private func sessionUpdateJSON() -> String {
        let session: [String: Any] = [
            "type": "realtime",
            "instructions": instructions,
            "audio": [
                "input": ["format": ["type": "audio/pcm", "rate": 24000]],
                "output": ["format": ["type": "audio/pcm", "rate": 24000]],
            ],
        ]
        let body: [String: Any] = ["type": "session.update", "session": session]
        let data = try? JSONSerialization.data(withJSONObject: body, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    static func base64PCM16(_ samples: [Int16]) -> String {
        var little = samples.map { $0.littleEndian }
        return little.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    static func decodePCM16(base64: String) -> [Int16]? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Int16(littleEndian: pointer[$0]) }
        }
    }
}
