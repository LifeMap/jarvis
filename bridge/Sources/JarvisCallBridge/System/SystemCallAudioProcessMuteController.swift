import AudioToolbox
import CoreAudio
import Foundation

/// Mutes listed processes via a private Core Audio tap. Real-device evidence (2026-08-19):
/// `com.apple.avconferenced` is the Continuity writer on the user's speaker; a process-only
/// `CATapMuted` tap silences that voice without hogging the device or changing YouTube/Zoom
/// beyond Apple's own call ducking.
@MainActor
final class SystemCallAudioProcessMuteController: CallAudioProcessMuteControlling {
    private let logger: BridgeLogger
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var isMuting = false

    init(logger: BridgeLogger) {
        self.logger = logger
    }

    @discardableResult
    func startMuting(bundleIDs: [String]) -> Bool {
        if isMuting { return true }
        guard #available(macOS 14.2, *) else {
            logger.log("[CALL-AUDIO-MUTE] start result=failure reason=macos-too-old")
            return false
        }
        let allowed = CallAudioProcessMutePolicy.sanitized(bundleIDs)
        guard !allowed.isEmpty else {
            logger.log("[CALL-AUDIO-MUTE] start result=failure reason=no-allowed-bundles")
            return false
        }

        let processIDs = processObjectIDs(matching: allowed)
        let description: CATapDescription
        if processIDs.isEmpty {
            description = CATapDescription()
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        }
        if #available(macOS 26.0, *) {
            description.bundleIDs = allowed
            description.isProcessRestoreEnabled = true
        }
        description.name = "Jarvis Continuity Mute"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        logger.log("[CALL-AUDIO-MUTE] create-tap status=\(tapStatus) tapID=\(createdTap) bundles=\(allowed.joined(separator: ",")) processes=\(processIDs)")
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            return false
        }

        guard let clockUID = dummyClockDeviceUID() else {
            AudioHardwareDestroyProcessTap(createdTap)
            logger.log("[CALL-AUDIO-MUTE] start result=failure reason=no-dummy-clock")
            return false
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis Continuity Mute Agg",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: clockUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString],
            ],
        ]
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregate)
        logger.log("[CALL-AUDIO-MUTE] create-aggregate status=\(aggStatus) aggID=\(createdAggregate) clockUID=\(clockUID)")
        guard aggStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(createdTap)
            return false
        }

        tapID = createdTap
        aggregateID = createdAggregate
        isMuting = true
        logger.log("[CALL-AUDIO-MUTE] start result=success")
        return true
    }

    func stopMuting() {
        guard isMuting else { return }
        destroyTapAndAggregate()
        isMuting = false
        logger.log("[CALL-AUDIO-MUTE] stop result=success")
    }

    private func destroyTapAndAggregate() {
        guard #available(macOS 14.2, *) else { return }
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            logger.log("[CALL-AUDIO-MUTE] destroy-aggregate status=\(status) aggID=\(aggregateID)")
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            logger.log("[CALL-AUDIO-MUTE] destroy-tap status=\(status) tapID=\(tapID)")
            tapID = kAudioObjectUnknown
        }
    }

    private func processObjectIDs(matching bundleIDs: [String]) -> [AudioObjectID] {
        let wanted = Set(bundleIDs)
        return allProcessObjectIDs().filter { wanted.contains(bundleID(of: $0) ?? "") }
    }

    private func allProcessObjectIDs() -> [AudioObjectID] {
        objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    private func dummyClockDeviceUID() -> String? {
        if deviceExists(uid: "BuiltInSpeakerDevice") { return "BuiltInSpeakerDevice" }
        guard let id = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) else { return nil }
        let uid = cfString(id, kAudioDevicePropertyDeviceUID)
        if let uid, uid != JarvisAudioDeviceUIDs.capture, uid != JarvisAudioDeviceUIDs.inject, uid != JarvisAudioDeviceUIDs.tap {
            return uid
        }
        return nil
    }

    private func deviceExists(uid: String) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uidRef) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID)
        }
        return status == noErr && deviceID != kAudioObjectUnknown
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : nil
    }

    private func bundleID(of objectID: AudioObjectID) -> String? {
        cfString(objectID, kAudioProcessPropertyBundleID)
    }

    private func cfString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func objectIDs(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
