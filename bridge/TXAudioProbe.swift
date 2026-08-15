import AVFoundation
import Combine
import Foundation

enum TXProbeState: String {
    case idle = "Not Available"
    case localOutput = "Local Output Only"
    case failed = "Failed"
}

@MainActor
final class TXAudioProbe: ObservableObject {
    @Published private(set) var state: TXProbeState = .idle

    private let logger: ProbeLogger
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init(logger: ProbeLogger) {
        self.logger = logger
        engine.attach(player)
    }

    func playDiagnosticTone() {
        stop()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames

        for frame in 0..<Int(frames) {
            let fade = min(1, Double(frame) / 480) * min(1, Double(Int(frames) - frame) / 480)
            samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate) * 0.12 * fade)
        }

        do {
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor in self?.stop() }
            }
            player.play()
            state = .localOutput
            logger.write("[TX] 440 Hz diagnostic tone started on default output")
            logger.write("[TX] NOT VERIFIED: speaker/default-output playback is not Continuity call injection")
        } catch {
            state = .failed
            logger.write("[TX] tone failed error=\(error.localizedDescription)")
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        if state != .idle { logger.write("[TX] diagnostic tone stopped") }
        state = .idle
    }
}
