import CoreAudio
import Combine
import Foundation

enum AudioDriverState: String {
    case notInstalled = "Not Installed"
    case installedInactive = "Installed / Inactive"
    case active = "Active"
    case error = "Error"
}

/// Read-only observer of the CB v2 Phase 1 JarvisCallAudio driver's presence/activation state,
/// polled at a low fixed interval — purely diagnostic. Critically, nothing in this file ever
/// activates the driver; `BridgeStateMachine` never holds a reference to this type at all, so
/// Work Mode literally cannot reach it (PRD §22, §23 — "ARMED ≠ Audio Driver Active").
@MainActor
final class AudioDriverStatus: ObservableObject {
    private static let captureUID = "com.jarvis.callbridge.audio.capture"
    private static let injectUID = "com.jarvis.callbridge.audio.inject"
    private static let activeSelector: AudioObjectPropertySelector = {
        var result: AudioObjectPropertySelector = 0
        for scalar in "Ract".unicodeScalars { result = (result << 8) + AudioObjectPropertySelector(scalar.value) }
        return result
    }()

    @Published private(set) var state: AudioDriverState = .notInstalled

    private var timer: Timer?
    private let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 5) {
        self.pollInterval = pollInterval
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard let captureID = Self.deviceID(forUID: Self.captureUID),
              let injectID = Self.deviceID(forUID: Self.injectUID) else {
            state = .notInstalled
            return
        }

        guard let captureActive = Self.getCustomBool(captureID, Self.activeSelector),
              let injectActive = Self.getCustomBool(injectID, Self.activeSelector) else {
            state = .error
            return
        }

        state = (captureActive || injectActive) ? .active : .installedInactive
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
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

    /// `kJarvisDevicePropertyActive` is a custom property, and AudioServerPlugIn.h documents
    /// CFString/CFPropertyList/None as the only marshalable types for custom (non-Apple-defined)
    /// properties — a raw UInt32 is silently rejected with kAudioHardwareUnknownPropertyError
    /// across the real coreaudiod IPC boundary, so this reads a CFBooleanRef instead.
    private static func getCustomBool(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFBoolean>?
        var size = UInt32(MemoryLayout<Unmanaged<CFBoolean>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return CFBooleanGetValue(value.takeRetainedValue())
    }
}
