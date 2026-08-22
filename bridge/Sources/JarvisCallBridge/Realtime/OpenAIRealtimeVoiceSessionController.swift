import Foundation

@MainActor
final class OpenAIRealtimeVoiceSessionController: ObservableObject, RealtimeVoiceSessionControlling {
    static let txWatermarkFrames = 9600

    @Published private(set) var uiState: RealtimeVoiceUIState = .idle
    var isEnabled = false {
        didSet { if !isConnectedNow { applyIdleOrArmed() } }
    }

    private let pcm: RealtimePCMBuffering
    private let loadEnv: () -> RealtimeEnvValues
    private let makeAdapter: (RealtimeEnvValues) -> RealtimeVoiceAdapting
    private let documentsDirectory: URL
    private let now: () -> Date
    private var adapter: RealtimeVoiceAdapting?
    private var pumpTask: Task<Void, Never>?
    private var rxWAV: RealtimeDebugWAVWriter?
    private var txWAV: RealtimeDebugWAVWriter?
    private var isConnectedNow = false

    init(
        pcm: RealtimePCMBuffering,
        loadEnv: @escaping () -> RealtimeEnvValues = {
            RealtimeEnvFile.resolve(appBundleURL: Bundle.main.bundleURL)
        },
        makeAdapter: @escaping (RealtimeEnvValues) -> RealtimeVoiceAdapting = { env in
            OpenAIRealtimeVoiceAdapter(
                apiKey: env.apiKey ?? "",
                model: env.model ?? RealtimeEnvFile.defaultModel,
                transport: URLSessionRealtimeWebSocketTransport()
            )
        },
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        now: @escaping () -> Date = Date.init
    ) {
        self.pcm = pcm
        self.loadEnv = loadEnv
        self.makeAdapter = makeAdapter
        self.documentsDirectory = documentsDirectory
        self.now = now
    }

    func connect(reason: String) async {
        guard isEnabled else { return }
        guard pcm.isRunning else {
            uiState = .armed
            return
        }
        if isConnectedNow { return }
        let env = loadEnv()
        guard let key = env.apiKey, !key.isEmpty else {
            uiState = .failed("missing API key")
            return
        }
        uiState = .connecting
        let adapter = makeAdapter(RealtimeEnvValues(apiKey: key, model: env.model ?? RealtimeEnvFile.defaultModel))
        self.adapter = adapter
        let ok = await adapter.connect()
        guard ok else {
            uiState = .failed("network")
            self.adapter = nil
            return
        }
        isConnectedNow = true
        openWAVs()
        uiState = .connected
        startPump()
    }

    func disconnect(reason: String) async {
        pumpTask?.cancel()
        pumpTask = nil
        await adapter?.disconnect()
        adapter = nil
        isConnectedNow = false
        pcm.clearRX()
        closeWAVs()
        applyIdleOrArmed()
    }

    func pumpOnce() {
        guard isConnectedNow, let adapter else { return }
        let rx = pcm.readRXFrames(maxFrames: 4800)
        if !rx.isEmpty {
            let pcm16 = RealtimeAudioConverter.toProviderRX(interleavedStereo48k: rx)
            if !pcm16.isEmpty {
                adapter.sendRX(pcm16)
                rxWAV?.append(pcm16: pcm16)
            }
        }
        let tx = adapter.pollTX()
        if !tx.isEmpty {
            txWAV?.append(pcm16: tx)
            let stereo = RealtimeAudioConverter.toHALTX(mono24kPCM16: tx)
            let room = max(0, Self.txWatermarkFrames - pcm.queuedTXFrames())
            let frames = stereo.count / 2
            let take = min(frames, room)
            if take > 0 {
                _ = pcm.writeTXFrames(Array(stereo.prefix(take * 2)))
            }
        }
    }

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pumpOnce()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func applyIdleOrArmed() {
        uiState = isEnabled ? .armed : .idle
    }

    private func openWAVs() {
        let stamp = Self.fileStamp(now())
        rxWAV = RealtimeDebugWAVWriter(url: documentsDirectory.appendingPathComponent("jarvis-call-bridge-rx-\(stamp).wav"))
        txWAV = RealtimeDebugWAVWriter(url: documentsDirectory.appendingPathComponent("jarvis-call-bridge-tx-\(stamp).wav"))
        try? rxWAV?.open()
        try? txWAV?.open()
    }

    private func closeWAVs() {
        try? rxWAV?.close()
        try? txWAV?.close()
        rxWAV = nil
        txWAV = nil
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
