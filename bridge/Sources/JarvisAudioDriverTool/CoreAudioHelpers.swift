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

    /// For custom properties only (`JarvisCallAudio.propertyActive` / `.propertyClearBuffers`).
    /// AudioServerPlugIn.h documents CFString/CFPropertyList/None as the only types the host will
    /// marshal for a plugin's *custom* (non-Apple-defined) properties — a raw UInt32 gets
    /// silently rejected with kAudioHardwareUnknownPropertyError across the real coreaudiod IPC
    /// boundary even though it can appear to work against an in-process test double. The driver
    /// answers these two with `CFBooleanRef` (a valid CFPropertyList leaf type).
    static func getBoolProperty(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFBoolean>?
        var size = UInt32(MemoryLayout<Unmanaged<CFBoolean>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw CoreAudioError.osStatus("GetPropertyData(\(selector))", status) }
        return CFBooleanGetValue(value.takeRetainedValue())
    }

    static func setBoolProperty(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: Bool) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        let status = withUnsafeMutablePointer(to: &cfValue) { pointer -> OSStatus in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<CFBoolean>.size), pointer)
        }
        guard status == noErr else { throw CoreAudioError.osStatus("SetPropertyData(\(selector))", status) }
    }

    /// Write-only trigger (`propertyClearBuffers`) — the value is ignored by the driver, any Set
    /// resets that device's loopback buffer.
    static func triggerProperty(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws {
        try setBoolProperty(deviceID, selector, true)
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
