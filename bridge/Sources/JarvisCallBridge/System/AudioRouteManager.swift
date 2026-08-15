import CoreAudio
import Foundation

struct AudioRouteSnapshot: Equatable {
    let defaultInputDeviceID: AudioDeviceID
    let defaultOutputDeviceID: AudioDeviceID
    let defaultSystemOutputDeviceID: AudioDeviceID
    let defaultInputName: String
    let defaultOutputName: String
    let defaultSystemOutputName: String
}

protocol AudioRouteReading {
    func currentSnapshot() -> AudioRouteSnapshot?
}

/// Placeholder for CB v2 Phase 1+ (Dual HAL Loopback routing). No production code anywhere in
/// Phase 0 holds a non-nil, real implementation of this protocol, and `BridgeStateMachine` never
/// calls it — `BridgeStateMachineTests` asserts that with a spy. Phase 0's `AudioRouteManager`
/// must stay strictly read-only (PRD §11, §12).
protocol AudioRouteMutating {
    func setDefaultInputDevice(_ deviceID: AudioDeviceID)
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID)
    func setDefaultSystemOutputDevice(_ deviceID: AudioDeviceID)
}

/// Reads (never writes) the system's default input/output/system-output devices via public
/// CoreAudio `AudioObjectGetPropertyData` calls against `kAudioObjectSystemObject`.
struct CoreAudioRouteReader: AudioRouteReading {
    func currentSnapshot() -> AudioRouteSnapshot? {
        guard
            let input = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice),
            let output = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice),
            let systemOutput = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        else { return nil }

        return AudioRouteSnapshot(
            defaultInputDeviceID: input,
            defaultOutputDeviceID: output,
            defaultSystemOutputDeviceID: systemOutput,
            defaultInputName: Self.deviceName(input),
            defaultOutputName: Self.deviceName(output),
            defaultSystemOutputName: Self.deviceName(systemOutput)
        )
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == kAudioHardwareNoError else { return nil }
        return deviceID
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == kAudioHardwareNoError, let name else { return "Unknown" }
        return name.takeRetainedValue() as String
    }
}
