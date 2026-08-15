import CoreAudio
import Foundation

/// Drives a specific AudioDeviceID directly via the low-level HAL Device I/O API
/// (`AudioDeviceCreateIOProcIDWithBlock`/`AudioDeviceStart`/`AudioDeviceStop`), independent of
/// whatever the system's default input/output device is — exactly how the future Bridge app
/// would talk to Jarvis Call Capture / Jarvis Call Inject (PRD §3.3: standard CoreAudio Device
/// I/O, no custom IPC). Optionally writes a deterministic sine tone into the device's Output
/// stream and/or captures whatever it reads back from the device's Input stream.
final class DeviceIOSession {
    let deviceID: AudioDeviceID
    private var ioProcID: AudioDeviceIOProcID?

    private let sampleRate: Double
    private let channelCount: Int

    private var writeFrequencyHz: Double?
    private var writePhase: Double = 0

    private let captureLock = NSLock()
    private var captureEnabled = false
    private var capturedFrames: [Float] = [] // interleaved

    init(deviceID: AudioDeviceID, sampleRate: Double = JarvisCallAudio.sampleRate, channelCount: Int = JarvisCallAudio.channelCount) {
        self.deviceID = deviceID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Starts IO. `writeFrequencyHz`, if set, feeds a sine tone into the Output stream at that
    /// frequency on channel 0 (and a fixed second tone on channel 1 when `stereoSecondTone` is
    /// set, used by the isolation test to make each device's signal trivially identifiable).
    func start(writeFrequencyHz: Double?, stereoSecondToneHz: Double? = nil, capture: Bool) throws {
        self.writeFrequencyHz = writeFrequencyHz
        self.writePhase = 0
        captureLock.lock()
        captureEnabled = capture
        capturedFrames.removeAll()
        captureLock.unlock()

        var procID: AudioDeviceIOProcID?
        let sampleRate = self.sampleRate
        let channelCount = self.channelCount
        let secondTone = stereoSecondToneHz

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }

            if let frequency = self.writeFrequencyHz {
                self.fill(outputData, frequency: frequency, secondChannelFrequency: secondTone, sampleRate: sampleRate, channelCount: channelCount)
            }

            if self.isCaptureEnabled {
                self.consume(inputData, channelCount: channelCount)
            }
        }
        guard status == noErr, let procID else {
            throw CoreAudioError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            throw CoreAudioError.osStatus("AudioDeviceStart", startStatus)
        }
    }

    func stop() {
        guard let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        ioProcID = nil
    }

    func snapshotCapturedFrames() -> [Float] {
        captureLock.lock()
        defer { captureLock.unlock() }
        return capturedFrames
    }

    private var isCaptureEnabled: Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        return captureEnabled
    }

    private func fill(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frequency: Double, secondChannelFrequency: Double?, sampleRate: Double, channelCount: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let frameCount = floatCount / channelCount
            for frame in 0..<frameCount {
                let phase = writePhase + Double(frame)
                let primary = Float(sin(2 * Double.pi * frequency * phase / sampleRate)) * 0.2
                for channel in 0..<channelCount {
                    if channel == 1, let secondChannelFrequency {
                        samples[frame * channelCount + channel] = Float(sin(2 * Double.pi * secondChannelFrequency * phase / sampleRate)) * 0.2
                    } else {
                        samples[frame * channelCount + channel] = primary
                    }
                }
            }
            writePhase += Double(frameCount)
        }
    }

    private func consume(_ bufferList: UnsafePointer<AudioBufferList>, channelCount: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let chunk = Array(UnsafeBufferPointer(start: samples, count: floatCount))
            captureLock.lock()
            capturedFrames.append(contentsOf: chunk)
            let maxSamples = sampleRateGuardedMaxSamples(channelCount: channelCount)
            if capturedFrames.count > maxSamples {
                capturedFrames.removeFirst(capturedFrames.count - maxSamples)
            }
            captureLock.unlock()
        }
    }

    private func sampleRateGuardedMaxSamples(channelCount: Int) -> Int {
        // Cap captured history to ~10 seconds so long-running commands (e.g. stress tests) can't
        // grow this array unbounded.
        Int(sampleRate) * channelCount * 10
    }
}
