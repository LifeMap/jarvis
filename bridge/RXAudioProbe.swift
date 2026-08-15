import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RXProbeState: String {
    case idle = "Not Available"
    case starting = "Starting"
    case active = "Active / Buffers Received"
    case noBuffers = "Running / No Buffers Yet"
    case unavailable = "Phone.app Not Available"
    case failed = "Failed"
}

enum RXSource: String {
    case none = "Not selected"
    case phoneApp = "Phone.app"
    case faceTimeFallback = "FaceTime (fallback/comparison — not primary target)"
}

enum RXDiagnosticState: String {
    case idle = "Idle"
    case recording = "Recording"
    case completed = "Completed"
    case failed = "Failed"
}

/// Phone.app is the primary CB Phase 0-A RX target per PRD v1.1 §7.4. FaceTime is kept only
/// as an explicitly-labeled fallback/comparison candidate, never selected by default.
@MainActor
final class RXAudioProbe: NSObject, ObservableObject {
    @Published private(set) var state: RXProbeState = .idle
    @Published private(set) var bufferCount = 0
    @Published private(set) var sourceName = "Not selected"
    @Published private(set) var sourceKind: RXSource = .none
    @Published private(set) var currentRMSdB: Double = -Double.infinity
    @Published private(set) var peakRMSdB: Double = -Double.infinity

    // CB Phase 0-2 diagnostic capture: a short, bounded WAV dump of the raw Phone.app RX
    // buffer so a human can listen back and confirm actual caller speech is present. This is
    // deliberately NOT the production rx.m4a/tx.m4a/merged.m4a recording pipeline — see
    // docs/Jarvis_Call_Bridge_Client_PRD.md §21 which is out of scope for Phase 0.
    @Published private(set) var diagnosticState: RXDiagnosticState = .idle
    @Published private(set) var diagnosticFilePath: String?
    @Published private(set) var diagnosticFramesWritten = 0

    private let logger: ProbeLogger
    private let output = StreamOutput()
    private var stream: SCStream?

    init(logger: ProbeLogger) {
        self.logger = logger
        super.init()
        output.onAudio = { [weak self] metrics in
            Task { @MainActor in self?.received(metrics) }
        }
        output.onDiagnosticEvent = { [weak self] event in
            Task { @MainActor in self?.handleDiagnosticEvent(event) }
        }
    }

    func start() async {
        await stop()
        state = .starting
        bufferCount = 0
        currentRMSdB = -Double.infinity
        peakRMSdB = -Double.infinity
        logger.write("[RX] requesting shareable applications (Screen Recording/System Audio permission may be shown)")

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            var target: SCRunningApplication?
            var kind: RXSource = .none

            if let phoneApp = content.applications.first(where: { $0.bundleIdentifier == "com.apple.mobilephone" }) {
                target = phoneApp
                kind = .phoneApp
                logger.write("[PHONE] Phone.app found pid=\(phoneApp.processID) bundle=\(phoneApp.bundleIdentifier)")
            } else if let faceTime = content.applications.first(where: {
                $0.bundleIdentifier == "com.apple.FaceTime" || $0.applicationName.localizedCaseInsensitiveContains("FaceTime")
            }) {
                target = faceTime
                kind = .faceTimeFallback
                logger.write("[RX] Phone.app not found; falling back to FaceTime for comparison only (not the Phase 0 primary target)")
            }

            guard let target else {
                state = .unavailable
                logger.write("[RX] Phone.app process not found; open a Continuity call in Phone.app and retry")
                return
            }
            guard let display = content.displays.first else {
                throw ProbeError.noDisplay
            }

            sourceName = "\(target.applicationName) (pid=\(target.processID))"
            sourceKind = kind
            let filter = SCContentFilter(display: display, including: [target], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 1
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            self.stream = stream
            state = .noBuffers
            logger.write("[RX] stream opened source=\(sourceName) kind=\(kind.rawValue); this is process-output capture, not yet proven as caller-only RX")
        } catch {
            state = .failed
            logger.write("[RX] start failed error=\(error.localizedDescription)")
        }
    }

    func stop() async {
        cancelDiagnosticCapture()
        guard let stream else { return }
        do { try await stream.stopCapture() } catch {
            logger.write("[RX] stop error=\(error.localizedDescription)")
        }
        self.stream = nil
        state = .idle
        logger.write("[RX] stream closed buffers=\(bufferCount)")
    }

    private func received(_ metrics: AudioMetrics) {
        bufferCount += 1
        state = .active
        currentRMSdB = metrics.rmsDb
        if metrics.rmsDb > peakRMSdB { peakRMSdB = metrics.rmsDb }

        if bufferCount == 1 || bufferCount.isMultiple(of: 100) {
            logger.write(
                String(format: "[RX] buffer count=%d sampleRate=%.0f channels=%u frames=%d callbackAudioMs=%.2f pts=%.3f rms=%.1fdB peak=%.1fdB",
                       bufferCount, metrics.sampleRate, metrics.channels, metrics.frames, metrics.durationMs, metrics.presentationSeconds, metrics.rmsDb, peakRMSdB)
            )
        }
    }

    // MARK: - CB Phase 0-2 diagnostic capture

    /// Starts a short, bounded capture of the raw Phone.app RX stream to a WAV file so a human
    /// can listen back afterward and confirm the actual caller's speech is present — buffer
    /// count and RMS movement alone are not treated as RX success (PRD §11).
    func startDiagnosticCapture(durationSeconds: Double = 8) {
        guard state == .active || state == .noBuffers else {
            logger.write("[RX] diagnostic capture requires an active RX stream — press Start Test first")
            return
        }
        guard diagnosticState != .recording else { return }

        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisCallBridge/diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            logger.write("[RX] diagnostic capture failed to create directory: \(error.localizedDescription)")
            diagnosticState = .failed
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = baseDir.appendingPathComponent("rx-checkpoint2-\(stamp).wav")

        diagnosticState = .recording
        diagnosticFilePath = url.path
        diagnosticFramesWritten = 0
        logger.write("[RX] diagnostic capture started duration=\(Int(durationSeconds))s file=\(url.path)")
        output.startDiagnosticCapture(url: url, durationSeconds: durationSeconds)
    }

    func stopDiagnosticCapture() {
        guard diagnosticState == .recording else { return }
        output.stopDiagnosticCaptureNow()
    }

    private func cancelDiagnosticCapture() {
        guard diagnosticState == .recording else { return }
        output.stopDiagnosticCaptureNow()
    }

    private func handleDiagnosticEvent(_ event: DiagnosticEvent) {
        switch event {
        case .finished(let url, let frames):
            diagnosticFramesWritten = frames
            diagnosticState = frames > 0 ? .completed : .failed
            logger.write("[RX] diagnostic capture completed file=\(url?.path ?? diagnosticFilePath ?? "?") frames=\(frames)")
        case .failed(let message):
            diagnosticState = .failed
            logger.write("[RX] diagnostic capture failed: \(message)")
        }
    }
}

private enum ProbeError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "No display available for ScreenCaptureKit filter" }
}

private struct AudioMetrics: Sendable {
    let sampleRate: Double
    let channels: UInt32
    let frames: Int
    let durationMs: Double
    let presentationSeconds: Double
    let rmsDb: Double
}

private enum DiagnosticEvent: Sendable {
    case finished(url: URL?, frames: Int)
    case failed(String)
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.jarvis.callbridge.rx-audio", qos: .userInteractive)
    var onAudio: (@Sendable (AudioMetrics) -> Void)?
    var onDiagnosticEvent: (@Sendable (DiagnosticEvent) -> Void)?

    // Only ever touched on `queue` — the same serial queue ScreenCaptureKit calls back on.
    private var diagnosticURL: URL?
    private var diagnosticFile: AVAudioFile?
    private var diagnosticFormat: AVAudioFormat?
    private var diagnosticDeadline: Date?
    private var diagnosticFramesWritten = 0

    func startDiagnosticCapture(url: URL, durationSeconds: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.diagnosticURL = url
            self.diagnosticFile = nil
            self.diagnosticFormat = nil
            self.diagnosticFramesWritten = 0
            self.diagnosticDeadline = Date().addingTimeInterval(durationSeconds)
        }
    }

    func stopDiagnosticCaptureNow() {
        queue.async { [weak self] in
            self?.finishDiagnostic()
        }
    }

    private func finishDiagnostic() {
        guard diagnosticDeadline != nil else { return }
        let url = diagnosticURL
        let frames = diagnosticFramesWritten
        diagnosticFile = nil
        diagnosticFormat = nil
        diagnosticDeadline = nil
        onDiagnosticEvent?(.finished(url: url, frames: frames))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        let description = sampleBuffer.formatDescription?.audioStreamBasicDescription
        let sampleRate = description?.mSampleRate ?? 0
        let frames = sampleBuffer.numSamples

        onAudio?(AudioMetrics(
            sampleRate: sampleRate,
            channels: description?.mChannelsPerFrame ?? 0,
            frames: frames,
            durationMs: sampleRate > 0 ? Double(frames) / sampleRate * 1_000 : 0,
            presentationSeconds: sampleBuffer.presentationTimeStamp.seconds,
            rmsDb: Self.rmsDb(of: sampleBuffer)
        ))

        if diagnosticDeadline != nil {
            writeDiagnosticBuffer(sampleBuffer)
            if let deadline = diagnosticDeadline, Date() >= deadline {
                finishDiagnostic()
            }
        }
    }

    /// Writes exactly what ScreenCaptureKit delivered for Phone.app — only this stream, never
    /// microphone input, never other system audio — into the diagnostic WAV file. Uses
    /// CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer + AVAudioPCMBuffer(pcmFormat:
    /// bufferListNoCopy:) rather than a hand-rolled byte copy, so this stays correct regardless
    /// of whether the buffer is interleaved or planar.
    private func writeDiagnosticBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = sampleBuffer.formatDescription else { return }

        if diagnosticFile == nil {
            guard let url = diagnosticURL else {
                onDiagnosticEvent?(.failed("no diagnostic output URL set"))
                diagnosticDeadline = nil
                return
            }
            let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            do {
                diagnosticFile = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                diagnosticFormat = format
            } catch {
                onDiagnosticEvent?(.failed("could not create diagnostic file: \(error.localizedDescription)"))
                diagnosticDeadline = nil
                return
            }
        }

        guard let format = diagnosticFormat, let file = diagnosticFile else { return }

        let channelCount = max(Int(format.channelCount), 1)
        let listPointer = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(listPointer.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPointer.unsafeMutablePointer) else {
            return
        }

        do {
            try file.write(from: pcmBuffer)
            diagnosticFramesWritten += Int(pcmBuffer.frameLength)
        } catch {
            onDiagnosticEvent?(.failed("write failed: \(error.localizedDescription)"))
            diagnosticDeadline = nil
        }
    }

    /// Computes RMS level in dBFS across all channels/frames in the buffer. Lets a human tester
    /// during the real-device test confirm amplitude actually moves when the caller speaks,
    /// rather than only observing that buffers are arriving at all (buffer arrival alone is
    /// not treated as RX success — see PRD §11).
    private static func rmsDb(of sampleBuffer: CMSampleBuffer) -> Double {
        guard let blockBuffer = sampleBuffer.dataBuffer else { return -Double.infinity }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return -Double.infinity }

        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return -Double.infinity }
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return -Double.infinity }
        let sampleCount = totalLength / MemoryLayout<Float>.size

        var sumSquares: Double = 0
        dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPointer in
            for i in 0..<sampleCount {
                let sample = Double(floatPointer[i])
                sumSquares += sample * sample
            }
        }
        guard sampleCount > 0 else { return -Double.infinity }
        let meanSquare = sumSquares / Double(sampleCount)
        let rms = sqrt(meanSquare)
        guard rms > 0 else { return -Double.infinity }
        return 20 * log10(rms)
    }
}
