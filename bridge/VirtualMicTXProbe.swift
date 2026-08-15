import AVFoundation
import Combine
import Foundation
import JarvisVMicRing

enum TXVirtualMicState: String {
    case idle = "Idle"
    case driverNotInstalled = "Driver Not Installed"
    case attached = "Attached / Silent"
    case playingTone = "Playing Test Tone"
    case playingSpeech = "Playing Speech Sample"
    case failed = "Failed"
}

/// CB Phase 0-B TX candidate. Writes PCM into the shared-memory ring buffer defined in
/// JarvisVMicRing.h, which the "Jarvis Virtual Mic" HAL plug-in (bridge/HALPlugin/) reads from
/// its DoIOOperation callback inside coreaudiod. This is the only file that talks to the
/// driver — the pre-existing TXAudioProbe.swift tone stays as a clearly-labeled local-speaker
/// smoke test that is NOT a TX candidate.
///
/// Success is never claimed here: this file can prove "PCM was written into the ring buffer",
/// never "the far-end caller heard it" — that requires the real-device test in the report.
@MainActor
final class VirtualMicTXProbe: ObservableObject {
    @Published private(set) var state: TXVirtualMicState = .idle
    @Published private(set) var underrunCount: UInt64 = 0
    @Published private(set) var currentRMSdB: Double = -Double.infinity

    private let logger: ProbeLogger
    private var shmFD: Int32 = -1
    private var mappedPointer: UnsafeMutableRawPointer?
    private var mappedSize: Int = 0
    private var writerTask: Task<Void, Never>?

    init(logger: ProbeLogger) {
        self.logger = logger
    }

    private var ring: UnsafeMutablePointer<JarvisVMicRing>? {
        guard let mappedPointer else { return nil }
        return mappedPointer.assumingMemoryBound(to: JarvisVMicRing.self)
    }

    /// Attaches to shared memory the driver is expected to have already created. Does not
    /// create the segment itself (no O_CREAT) — creation is the driver's responsibility so
    /// the ring buffer's lifetime tracks coreaudiod, not this app.
    private func attach() -> Bool {
        guard mappedPointer == nil else { return true }

        let fd = JarvisVMicRingShmOpenExisting(JARVIS_VMIC_SHM_NAME)
        guard fd >= 0 else {
            state = .driverNotInstalled
            logger.write("[TX] shm_open(\(JARVIS_VMIC_SHM_NAME)) failed errno=\(errno) — driver not installed/loaded. Run bridge/HALPlugin/build-driver.sh then bridge/HALPlugin/install.sh yourself, then retry.")
            return false
        }

        let size = JarvisVMicRingByteSize()
        guard let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), pointer != MAP_FAILED else {
            logger.write("[TX] mmap failed errno=\(errno)")
            close(fd)
            state = .failed
            return false
        }

        shmFD = fd
        mappedPointer = pointer
        mappedSize = size

        let ringPointer = pointer.assumingMemoryBound(to: JarvisVMicRing.self)
        guard JarvisVMicRingHeaderValid(ringPointer) else {
            logger.write("[TX] shared memory header invalid (magic/version mismatch) — stale or foreign segment; not writing")
            detach()
            state = .failed
            return false
        }

        logger.write("[TX] attached to Jarvis Virtual Mic shared memory, capacityFrames=\(ringPointer.pointee.capacityFrames)")
        state = .attached
        return true
    }

    private func detach() {
        if let mappedPointer {
            munmap(mappedPointer, mappedSize)
        }
        if shmFD >= 0 {
            close(shmFD)
        }
        mappedPointer = nil
        shmFD = -1
        mappedSize = 0
    }

    func playTestTone() {
        play(samples: Self.generateTone(frequencyHz: 440, durationSeconds: 3, sampleRate: 48_000), label: .playingTone)
    }

    func playSpeechSample() {
        guard let url = Bundle.module.url(forResource: "tx-sample", withExtension: "wav") else {
            logger.write("[TX] tx-sample.wav not found in bundle resources")
            return
        }
        do {
            let samples = try Self.loadMonoFloatSamples(from: url)
            play(samples: samples, label: .playingSpeech)
        } catch {
            logger.write("[TX] failed to load tx-sample.wav: \(error.localizedDescription)")
            state = .failed
        }
    }

    private func play(samples: [Float], label: TXVirtualMicState) {
        stopPlayback()
        guard attach(), let ring else { return }

        state = label
        logger.write("[TX] writing \(samples.count) frames into virtual mic ring buffer (\(label.rawValue))")

        writerTask = Task { [weak self] in
            guard let self else { return }
            let chunkSize = 480 // 10ms @ 48kHz
            var offset = 0
            while offset < samples.count {
                if Task.isCancelled { break }
                let end = min(offset + chunkSize, samples.count)
                let chunk = Array(samples[offset..<end])
                self.writeChunk(chunk, into: ring)
                offset = end
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            self.finishedPlayback()
        }
    }

    private func writeChunk(_ chunk: [Float], into ring: UnsafeMutablePointer<JarvisVMicRing>) {
        chunk.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            JarvisVMicRingWrite(ring, base, UInt32(buffer.count))
        }
        JarvisVMicRingTouchHeartbeat(ring, UInt64(DispatchTime.now().uptimeNanoseconds))
        underrunCount = JarvisVMicRingGetUnderrunCount(ring)

        var sumSquares: Double = 0
        for sample in chunk { sumSquares += Double(sample) * Double(sample) }
        if !chunk.isEmpty {
            let rms = sqrt(sumSquares / Double(chunk.count))
            currentRMSdB = rms > 0 ? 20 * log10(rms) : -Double.infinity
        }
    }

    private func finishedPlayback() {
        guard state == .playingTone || state == .playingSpeech else { return }
        logger.write("[TX] playback finished")
        state = .attached
    }

    func stopPlayback() {
        writerTask?.cancel()
        writerTask = nil
    }

    func stop() {
        stopPlayback()
        detach()
        state = .idle
        logger.write("[TX] virtual mic probe stopped, resources released")
    }

    // MARK: - Signal generation / loading

    private static func generateTone(frequencyHz: Double, durationSeconds: Double, sampleRate: Double) -> [Float] {
        let frameCount = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0, count: frameCount)
        let fadeFrames = Int(0.01 * sampleRate)
        for frame in 0..<frameCount {
            let fade = Float(min(1, Double(frame) / Double(max(fadeFrames, 1))) * min(1, Double(frameCount - frame) / Double(max(fadeFrames, 1))))
            samples[frame] = Float(sin(2 * Double.pi * frequencyHz * Double(frame) / sampleRate)) * 0.2 * fade
        }
        return samples
    }

    private static func loadMonoFloatSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "VirtualMicTXProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not allocate PCM buffer"])
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "VirtualMicTXProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "no float channel data"])
        }
        let frameLength = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
