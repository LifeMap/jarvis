import Foundation

@MainActor
final class OpenAIRealtimeVoiceAdapter: RealtimeVoiceAdapting {
    nonisolated static let defaultInstructions = """
    당신은 전화로 통화 중인 한국어 비서입니다.
    첫 인사 이후에는 상대가 쓰는 언어로 맞춰, 짧게 자연스럽게 대답하세요.
    """

    private let apiKey: String
    private let model: String
    private let instructions: String
    private let followUpInstructions: String?
    private let transport: RealtimeWebSocketTransporting
    private var receiveTask: Task<Void, Never>?
    private var txQueue: [[Int16]] = []
    private var suppressTX = false
    private var didSendFollowUp = false
    private(set) var collectedTranscript: [CallTranscriptTurn] = []
    private(set) var isConnected = false
    var onRemoteSpeechStarted: (() -> Void)?
    var transcript: [CallTranscriptTurn] { collectedTranscript }

    init(
        apiKey: String,
        model: String,
        transport: RealtimeWebSocketTransporting,
        instructions: String = OpenAIRealtimeVoiceAdapter.defaultInstructions,
        followUpInstructions: String? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.instructions = instructions
        self.followUpInstructions = followUpInstructions
        self.transport = transport
    }

    func connect() async -> Bool {
        await disconnect()
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else { return false }
        do {
            try await transport.connect(url: url, headers: ["Authorization": "Bearer \(apiKey)"])
            try await transport.send(text: sessionUpdateJSON())
            try await transport.send(text: #"{"type":"response.create"}"#)
            collectedTranscript = []
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
        suppressTX = false
        didSendFollowUp = false
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
            guard !suppressTX else { return }
            guard let delta = object["delta"] as? String, let samples = Self.decodePCM16(base64: delta) else { return }
            txQueue.append(samples)
        case "input_audio_buffer.speech_started", "speech_started":
            txQueue = []
            suppressTX = true
            onRemoteSpeechStarted?()
        case "input_audio_buffer.speech_stopped", "speech_stopped":
            suppressTX = false
        case "conversation.item.input_audio_transcription.completed":
            if let text = transcriptionText(object) {
                collectedTranscript.append(CallTranscriptTurn(role: "caller", text: text))
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            if let text = transcriptionText(object) {
                collectedTranscript.append(CallTranscriptTurn(role: "jarvis", text: text))
            }
            sendFollowUpInstructionsIfNeeded()
        default:
            break
        }
    }

    private func sendFollowUpInstructionsIfNeeded() {
        guard !didSendFollowUp, let followUpInstructions, !followUpInstructions.isEmpty, isConnected else { return }
        didSendFollowUp = true
        let json = sessionUpdateJSON(instructions: followUpInstructions)
        let transport = self.transport
        Task { try? await transport.send(text: json) }
    }

    private func sessionUpdateJSON(instructions: String? = nil) -> String {
        let session: [String: Any] = [
            "type": "realtime",
            "instructions": instructions ?? self.instructions,
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "transcription": ["model": "whisper-1"],
                    "turn_detection": [
                        "type": "server_vad",
                        "create_response": true,
                        "interrupt_response": true,
                    ],
                ],
                "output": ["format": ["type": "audio/pcm", "rate": 24000]],
            ],
        ]
        let body: [String: Any] = ["type": "session.update", "session": session]
        let data = try? JSONSerialization.data(withJSONObject: body, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private func transcriptionText(_ object: [String: Any]) -> String? {
        if let text = object["transcript"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
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
