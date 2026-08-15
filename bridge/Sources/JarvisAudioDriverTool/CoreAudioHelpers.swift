import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case deviceNotFound(String)

    var description: String {
        switch self {
        case .osStatus(let call, let status):
            return "\(call) failed, OSStatus=\(status)"
        case .deviceNotFound(let uid):
            return "device with UID '\(uid)' not found — is the driver installed? (Scripts/install-driver.sh)"
        }
    }
}

enum CoreAudioHelpers {
    /// Resolves an AudioDeviceID directly from a device UID via the system object's
    /// TranslateUIDToDevice property — works regardless of whether the device is currently
    /// hidden, since IsHidden only affects user-facing device pickers, not HAL-level resolution.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uidRef) { uidPointer -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func getUInt32(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError.osStatus("GetPropertyData(\(selector))", status) }
        return value
    }

    static func setUInt32(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var mutableValue = value
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mutableValue)
        guard status == noErr else { throw CoreAudioError.osStatus("SetPropertyData(\(selector))", status) }
    }

    static func getCFString(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { throw CoreAudioError.osStatus("GetPropertyData(\(selector))", status) }
        return name.takeRetainedValue() as String
    }

    static func getFormat(_ streamID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CoreAudioError.osStatus("GetPropertyData(VirtualFormat)", status) }
        return format
    }

    static func getStreams(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams)
        guard status == noErr else { throw CoreAudioError.osStatus("GetPropertyData(Streams)", status) }
        return streams
    }

    struct RouteSnapshot: Equatable, CustomStringConvertible {
        let inputName: String
        let outputName: String
        let systemOutputName: String

        var description: String { "Input=\(inputName) Output=\(outputName) SystemOutput=\(systemOutputName)" }
    }

    static func currentRoute() -> RouteSnapshot {
        func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
            return status == noErr ? deviceID : nil
        }
        func name(_ deviceID: AudioDeviceID?) -> String {
            guard let deviceID, let name = try? getCFString(deviceID, kAudioObjectPropertyName) else { return "Unknown" }
            return name
        }
        return RouteSnapshot(
            inputName: name(defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)),
            outputName: name(defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)),
            systemOutputName: name(defaultDeviceID(kAudioHardwarePropertyDefaultSystemOutputDevice))
        )
    }
}
