import Foundation

@MainActor
final class OpenAIRealtimeVoiceSessionController: ObservableObject, RealtimeVoiceSessionControlling {
    static let txWatermarkFrames = 43200

    @Published private(set) var uiState: RealtimeVoiceUIState = .idle
    var reportDirection: CallReportDirection {
        get { reportDirectionBox.value }
        set { reportDirectionBox.value = newValue }
    }
    var isEnabled = false {
        didSet { if !isConnectedNow { applyIdleOrArmed() } }
    }

    private let pcm: RealtimePCMBuffering
    private let loadEnv: () -> RealtimeEnvValues
    private let mintCredentials: JarvisRealtimeCredentialMinting
    private let callReporter: JarvisCallReporting
    private let resolveCaller: () -> CallCaller
    private let encoder: CallAudioEncoding
    private let loadInstructions: (CallReportDirection) -> (style: RealtimeSpeechStyle, extra: String, text: String)
    private let reportDirectionBox = DirectionBox()
    private let makeAdapter: (RealtimeEnvValues) -> RealtimeVoiceAdapting
    private let documentsDirectory: URL
    private let now: () -> Date
    private var handshakeTask: Task<Bool, Never>?
    private var reportTask: Task<Void, Never>?
    private var adapter: RealtimeVoiceAdapting?
    private var pumpTask: Task<Void, Never>?
    private var rxWAV: RealtimeDebugWAVWriter?
    private var txWAV: RealtimeDebugWAVWriter?
    private var mixWAV: RealtimeDebugWAVWriter?
    private var isConnectedNow = false
    private var callId: String?
    private var rxPCM: [Int16] = []
    private var txPCM: [Int16] = []
    private var txPending: [Int16] = []
    private var txHALPending: [Float] = []
    private var txHALConverter = RealtimeHALTXConverter()
    private var recordingStopped = false
    private var pendingTranscript: [CallTranscriptTurn] = []
    private var pendingReport: PendingCallReport?
    private let log: (String) -> Void

    private struct PendingCallReport {
        let id: String
        let origin: String
        let token: String
        let rx: [Int16]
        let tx: [Int16]
        let transcript: [CallTranscriptTurn]
    }

    init(
        pcm: RealtimePCMBuffering,
        loadEnv: @escaping () -> RealtimeEnvValues = {
            RealtimeEnvFile.resolve(appBundleURL: Bundle.main.bundleURL)
        },
        mintCredentials: JarvisRealtimeCredentialMinting = JarvisAPIClient(),
        callReporter: JarvisCallReporting = JarvisAPIClient(),
        resolveCaller: @escaping () -> CallCaller = { CallCaller.unknown },
        encoder: CallAudioEncoding = AACM4AEncoder(),
        loadInstructions: @escaping (CallReportDirection) -> (style: RealtimeSpeechStyle, extra: String, text: String) = { direction in
            let store = UserDefaultsRealtimeCallInstructionStore()
            let extra = direction == .outgoing ? store.outgoingGreeting : store.incomingGreeting
            return (store.speechStyle, extra, store.composedInstructions(direction: direction))
        },
        makeAdapter: ((RealtimeEnvValues) -> RealtimeVoiceAdapting)? = nil,
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.pcm = pcm
        self.loadEnv = loadEnv
        self.mintCredentials = mintCredentials
        self.callReporter = callReporter
        self.resolveCaller = resolveCaller
        self.encoder = encoder
        self.loadInstructions = loadInstructions
        let directionBox = reportDirectionBox
        self.makeAdapter = makeAdapter ?? { env in
            let store = UserDefaultsRealtimeCallInstructionStore()
            return OpenAIRealtimeVoiceAdapter(
                apiKey: env.apiKey ?? "",
                model: env.model ?? RealtimeEnvFile.defaultModel,
                transport: URLSessionRealtimeWebSocketTransport(),
                instructions: store.composedInstructions(direction: directionBox.value),
                followUpInstructions: RealtimeCallInstructions.composeAfterOpening(style: store.speechStyle)
            )
        }
        self.documentsDirectory = documentsDirectory
        self.now = now
        self.log = log
    }

    func prepare(reason: String) async {
        guard isEnabled else { return }
        _ = await ensureHandshake()
    }

    func connect(reason: String) async {
        guard isEnabled else { return }
        guard pcm.isRunning else {
            uiState = .armed
            return
        }
        if isConnectedNow {
            if recordingStopped {
                recordingStopped = false
                openWAVs()
                startPump()
            }
            return
        }
        guard await ensureHandshake() else { return }
        guard let adapter else { return }
        adapter.onRemoteSpeechStarted = { [weak self] in
            self?.handleRemoteSpeechStarted()
        }
        isConnectedNow = true
        recordingStopped = false
        openWAVs()
        uiState = .connected
        startPump()
        let env = loadEnv()
        if let token = env.jarvisAPIToken, !token.isEmpty, let origin = env.jarvisAPIOrigin, !origin.isEmpty {
            reportTask = Task { await self.startCallReport(origin: origin, token: token) }
        }
    }

    func disconnect(reason: String) async {
        handshakeTask?.cancel()
        handshakeTask = nil
        await reportTask?.value
        reportTask = nil
        await stopRecording()
        pendingTranscript = adapter?.transcript ?? []
        snapshotPendingReport()
        await adapter?.disconnect()
        adapter = nil
        isConnectedNow = false
        pcm.clearRX()
        applyIdleOrArmed()
    }

    private func ensureHandshake() async -> Bool {
        if let handshakeTask { return await handshakeTask.value }
        if adapter != nil { return true }
        let task = Task { await self.performHandshake() }
        handshakeTask = task
        let ok = await task.value
        if !ok { handshakeTask = nil }
        return ok
    }

    private func performHandshake() async -> Bool {
        let env = loadEnv()
        guard let token = env.jarvisAPIToken, !token.isEmpty,
              let origin = env.jarvisAPIOrigin, !origin.isEmpty
        else {
            uiState = .failed("jarvis auth")
            return false
        }
        uiState = .connecting
        let model = env.model ?? RealtimeEnvFile.defaultModel
        let secret: JarvisRealtimeClientSecret
        do {
            secret = try await mintCredentials.mintRealtimeClientSecret(origin: origin, token: token, model: model)
        } catch let error as JarvisAPIClientError where error == .jarvisAuth {
            uiState = .failed("jarvis auth")
            return false
        } catch {
            uiState = .failed("network")
            return false
        }
        let instructions = loadInstructions(reportDirection)
        log(RealtimeCallInstructions.connectLog(style: instructions.style, extra: instructions.extra))
        let adapter = makeAdapter(RealtimeEnvValues(apiKey: secret.value, model: secret.model))
        let ok = await adapter.connect()
        guard ok else {
            uiState = .failed("network")
            return false
        }
        self.adapter = adapter
        return true
    }

    func stopRecording() async {
        guard !recordingStopped else { return }
        recordingStopped = true
        pumpTask?.cancel()
        pumpTask = nil
        closeWAVs()
        txPending = []
        txHALPending = []
        txHALConverter.reset()
    }

    func finalizeIdleReport() async {
        await finishCallReport()
    }

    func pumpOnce() {
        guard isConnectedNow, !recordingStopped, let adapter else { return }
        var rxTick: [Int16] = []
        let rx = pcm.readRXFrames(maxFrames: 4800)
        if !rx.isEmpty {
            let pcm16 = RealtimeAudioConverter.toProviderRX(interleavedStereo48k: rx)
            if !pcm16.isEmpty {
                adapter.sendRX(pcm16)
                rxTick = pcm16
            }
        }
        drainAdapterTX(adapter)
        flushHALTX()
        guard !rxTick.isEmpty else { return }
        let txTick = CallAudioMixer.consumeTX(&txPending, count: rxTick.count)
        rxWAV?.append(pcm16: rxTick)
        txWAV?.append(pcm16: txTick)
        mixWAV?.append(pcm16: CallAudioMixer.mix(rx: rxTick, tx: txTick))
        rxPCM.append(contentsOf: rxTick)
        txPCM.append(contentsOf: txTick)
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

    private func drainAdapterTX(_ adapter: RealtimeVoiceAdapting) {
        while true {
            let tx = adapter.pollTX()
            if tx.isEmpty { break }
            txPending.append(contentsOf: tx)
            txHALPending.append(contentsOf: txHALConverter.convert(tx))
        }
    }

    private func flushHALTX() {
        let room = max(0, Self.txWatermarkFrames - pcm.queuedTXFrames())
        let frames = txHALPending.count / 2
        let take = min(frames, room)
        guard take > 0 else { return }
        let written = pcm.writeTXFrames(Array(txHALPending.prefix(take * 2)))
        if written > 0 {
            txHALPending.removeFirst(min(written, take) * 2)
        }
    }

    private func handleRemoteSpeechStarted() {
        guard isConnectedNow else { return }
        txPending = []
        txHALPending = []
        txHALConverter.reset()
        pcm.clearTX()
        log("[CALL] speech_started")
    }

    private func startCallReport(origin: String, token: String) async {
        let caller = resolveCaller()
        do {
            callId = try await callReporter.createCall(
                origin: origin,
                token: token,
                caller: caller,
                startedAt: now(),
                direction: reportDirection
            )
            log("[CALL-REPORT] create result=ok phone=\(caller.phoneNumber == "unknown" ? "missing" : "found")")
        } catch {
            callId = nil
            log("[CALL-REPORT] create result=failed")
        }
    }

    private func snapshotPendingReport() {
        let env = loadEnv()
        guard let id = callId,
              let token = env.jarvisAPIToken, !token.isEmpty,
              let origin = env.jarvisAPIOrigin, !origin.isEmpty
        else {
            log("[CALL-REPORT] snapshot result=skipped")
            resetCallReportBuffers()
            return
        }
        pendingReport = PendingCallReport(
            id: id,
            origin: origin,
            token: token,
            rx: rxPCM,
            tx: txPCM,
            transcript: pendingTranscript
        )
        resetCallReportBuffers()
    }

    private func finishCallReport() async {
        guard let report = pendingReport else { return }
        pendingReport = nil
        let mixed = CallAudioMixer.mix(rx: report.rx, tx: report.tx)
        var uploadFailed = true
        if mixed.isEmpty {
            log("[CALL-REPORT] encode result=empty")
        } else if let data = try? encoder.encodeM4A(pcm16: mixed, channels: 1) {
            log("[CALL-REPORT] encode result=ok frames=\(mixed.count) bytes=\(data.count)")
            do {
                try await callReporter.uploadCallAudio(origin: report.origin, token: report.token, id: report.id, data: data)
                uploadFailed = false
                log("[CALL-REPORT] upload result=ok")
            } catch {
                log("[CALL-REPORT] upload result=failed")
            }
        } else {
            log("[CALL-REPORT] encode result=failed")
        }
        do {
            try await callReporter.completeCall(
                origin: report.origin,
                token: report.token,
                id: report.id,
                endedAt: now(),
                transcript: report.transcript,
                uploadFailed: uploadFailed,
                summary: nil
            )
            log("[CALL-REPORT] complete result=ok uploadFailed=\(uploadFailed)")
        } catch {
            log("[CALL-REPORT] complete result=failed")
        }
    }

    private func resetCallReportBuffers() {
        callId = nil
        rxPCM = []
        txPCM = []
        txPending = []
        txHALPending = []
        txHALConverter.reset()
        pendingTranscript = []
    }

    private func applyIdleOrArmed() {
        uiState = isEnabled ? .armed : .idle
    }

    private func openWAVs() {
        let stamp = Self.fileStamp(now())
        rxWAV = RealtimeDebugWAVWriter(url: documentsDirectory.appendingPathComponent("jarvis-call-bridge-rx-\(stamp).wav"))
        txWAV = RealtimeDebugWAVWriter(url: documentsDirectory.appendingPathComponent("jarvis-call-bridge-tx-\(stamp).wav"))
        mixWAV = RealtimeDebugWAVWriter(url: documentsDirectory.appendingPathComponent("jarvis-call-bridge-mix-\(stamp).wav"))
        try? rxWAV?.open()
        try? txWAV?.open()
        try? mixWAV?.open()
    }

    private func closeWAVs() {
        try? rxWAV?.close()
        try? txWAV?.close()
        try? mixWAV?.close()
        rxWAV = nil
        txWAV = nil
        mixWAV = nil
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private final class DirectionBox {
    var value: CallReportDirection = .incoming
}
