import AVFoundation
import Foundation

struct AACM4AEncoder: CallAudioEncoding {
    func encodeM4A(pcm16: [Int16], channels: Int) throws -> Data {
        guard !pcm16.isEmpty, channels == 1 || channels == 2 else { throw JarvisAPIClientError.network }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-call-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 2 ? 96_000 : 64_000,
        ]
        try writeAAC(pcm16: pcm16, channels: channels, url: url, settings: settings)
        return try Data(contentsOf: url)
    }

    private func writeAAC(pcm16: [Int16], channels: Int, url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frameTotal = pcm16.count / channels
        let packetFrames = 1024
        var offset = 0
        while offset < frameTotal {
            let count = min(packetFrames, frameTotal - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw JarvisAPIClientError.network
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channelsData = buffer.floatChannelData {
                for frame in 0..<count {
                    let sampleIndex = (offset + frame) * channels
                    channelsData[0][frame] = Float(pcm16[sampleIndex]) / Float(Int16.max)
                    if channels == 2 {
                        channelsData[1][frame] = Float(pcm16[sampleIndex + 1]) / Float(Int16.max)
                    }
                }
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}
