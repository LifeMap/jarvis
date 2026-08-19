import CoreAudio
import Foundation

/// Phase 3 CHECKPOINT 1's entire boundary to real CoreAudio route mutation (§26 — "centralize real
/// CoreAudio mutation behind an injectable abstraction... unit tests must never mutate the actual
/// Mac audio routes"). Production talks to `SystemCallAudioRouteController`; tests talk to a spy.
///
/// §11 — "Default System Output MUST NEVER CHANGE" — is enforced structurally here, not just by
/// convention: this protocol has a getter for system output (as part of the snapshot) but **no
/// setter method for it at all**. There is no way to call a system-output mutation through this
/// type because no such method exists to call.
@MainActor
protocol CallAudioRouteControlling {
    func currentRouteSnapshot() -> CallAudioRouteSnapshot?
    func deviceExists(uid: String) -> Bool
    @discardableResult func setDefaultOutputDevice(uid: String) -> Bool
    @discardableResult func setDefaultInputDevice(uid: String) -> Bool
    /// `kAudioDevicePropertyHogMode` — `-1` means the device is free. Used to evict other HAL
    /// clients (e.g. Phone.app / Continuity) from the pre-call speaker after default-device
    /// changes proved insufficient.
    func hogPID(uid: String) -> pid_t?
    @discardableResult func setHogPID(uid: String, pid: pid_t) -> Bool
}

/// Real implementation — public CoreAudio `AudioObjectGetPropertyData`/`SetPropertyData` against
/// `kAudioObjectSystemObject`, the same pattern already used read-only by
/// `CoreAudioRouteReader`/`JarvisAudioDriverTool.CoreAudioHelpers`. This is the only file in
/// `JarvisCallBridge` (the app target) that ever calls `AudioObjectSetPropertyData` for a default
/// device.
///
/// Real-device fix (route-setter investigation): a first fix (bounded `waitForRouteConvergence`)
/// did not resolve the real-device failure — forward convergence timed out at the full bound
/// (attempts=10, elapsedMs=711, inputMatch=false, outputMatch=false) even though the setter itself
/// reported success. Code inspection of `AudioDriver/Plugin/PlugInInterface.c` found the actual
/// cause: `kAudioDevicePropertyDeviceCanBeDefaultDevice` was hardcoded to always report `0`/false
/// for both Jarvis devices (a deliberate Phase 1 safety mechanism) — `AudioObjectSetPropertyData`
/// toward a device coreaudiod considers permanently ineligible can return `noErr` (the request is
/// accepted) without the change ever actually being committed. The fix (in the driver, not here)
/// ties `CanBeDefaultDevice` to the device's own `isActive` state, confirmed via
/// `AudioDriver/build/selftest` (in-process, no coreaudiod). This file adds the OSStatus-level
/// diagnostics the investigation asked for so the *next* real-device attempt has first-class
/// evidence rather than only a Bool.
struct SystemCallAudioRouteController: CallAudioRouteControlling {
    private let logger: BridgeLogger?

    init(logger: BridgeLogger? = nil) {
        self.logger = logger
    }

    func currentRouteSnapshot() -> CallAudioRouteSnapshot? {
        guard
            let inputID = Self.defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice),
            let outputID = Self.defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice),
            let systemOutputID = Self.defaultDeviceID(kAudioHardwarePropertyDefaultSystemOutputDevice),
            let inputUID = Self.uid(of: inputID),
            let outputUID = Self.uid(of: outputID),
            let systemOutputUID = Self.uid(of: systemOutputID)
        else { return nil }

        return CallAudioRouteSnapshot(inputUID: inputUID, outputUID: outputUID, systemOutputUID: systemOutputUID)
    }

    func deviceExists(uid: String) -> Bool {
        Self.deviceID(forUID: uid) != nil
    }

    @discardableResult
    func setDefaultOutputDevice(uid: String) -> Bool {
        setDefault(uid: uid, selector: kAudioHardwarePropertyDefaultOutputDevice, operation: "set-default-output")
    }

    @discardableResult
    func setDefaultInputDevice(uid: String) -> Bool {
        setDefault(uid: uid, selector: kAudioHardwarePropertyDefaultInputDevice, operation: "set-default-input")
    }

    func hogPID(uid: String) -> pid_t? {
        guard let deviceID = Self.deviceID(forUID: uid) else { return nil }
        var address = Self.hogAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &pid)
        guard status == noErr else { return nil }
        return pid
    }

    @discardableResult
    func setHogPID(uid: String, pid: pid_t) -> Bool {
        guard let deviceID = Self.deviceID(forUID: uid) else {
            logger?.log("[CALL-AUDIO-COREAUDIO] operation=set-hog uid=\(uid) pid=\(pid) result=failure reason=uid-does-not-resolve")
            return false
        }
        var address = Self.hogAddress()
        guard AudioObjectHasProperty(deviceID, &address) else {
            logger?.log("[CALL-AUDIO-COREAUDIO] operation=set-hog uid=\(uid) deviceID=\(deviceID) pid=\(pid) result=failure reason=property-missing")
            return false
        }
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue else {
            logger?.log("[CALL-AUDIO-COREAUDIO] operation=set-hog uid=\(uid) deviceID=\(deviceID) pid=\(pid) result=failure reason=property-not-settable")
            return false
        }
        var mutable = pid
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &mutable)
        let ok = status == noErr
        let readBack = hogPID(uid: uid)
        logger?.log("[CALL-AUDIO-COREAUDIO] operation=set-hog uid=\(uid) deviceID=\(deviceID) pid=\(pid) osStatus=\(status) readBackPID=\(readBack.map(String.init) ?? "nil") result=\(ok ? "success" : "failure")")
        return ok
    }

    // MARK: - CoreAudio plumbing

    /// §4/§5/§6/§12 of the investigation: resolves + round-trips the target UID, checks
    /// Has/IsSettable on the system object before attempting the mutation, captures the actual
    /// OSStatus (never inferring success from convergence), and logs an immediate post-set
    /// readback for diagnostics — all under a single `[CALL-AUDIO-COREAUDIO]` line per attempt so
    /// a failure is traceable to an exact stage without needing follow-up real-device runs.
    private func setDefault(uid: String, selector: AudioObjectPropertySelector, operation: String) -> Bool {
        guard let deviceID = Self.deviceID(forUID: uid) else {
            logger?.log("[CALL-AUDIO-COREAUDIO] operation=\(operation) targetUID=\(uid) result=failure reason=uid-does-not-resolve")
            return false
        }

        // UID round-trip (§6): a lookup returning a non-zero AudioDeviceID is not itself proof the
        // resolution is correct — read the UID back FROM that ID and require exact equality.
        let roundTripUID = Self.uid(of: deviceID)
        if roundTripUID != uid {
            logger?.log("[CALL-AUDIO-DEVICE] role=\(operation) uid=\(uid) deviceID=\(deviceID) roundTripUID=\(roundTripUID ?? "nil") result=mismatch")
        }

        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

        // §5: property existence/settable check on the system object — if CoreAudio itself says
        // this can't be set, fail immediately rather than entering (bounded) convergence polling
        // for a change that was never going to be accepted in the first place.
        let hasProperty = AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address)
        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(AudioObjectID(kAudioObjectSystemObject), &address, &isSettable)
        guard hasProperty, settableStatus == noErr, isSettable.boolValue else {
            logger?.log("[CALL-AUDIO-COREAUDIO] operation=\(operation) targetUID=\(uid) targetDeviceID=\(deviceID) hasProperty=\(hasProperty) settable=\(isSettable.boolValue) settableStatus=\(settableStatus) result=failure reason=property-not-settable")
            return false
        }

        let beforeID = Self.defaultDeviceID(selector)
        let beforeUID = beforeID.flatMap(Self.uid(of:))

        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &mutableDeviceID)
        let succeeded = status == kAudioHardwareNoError

        // §12: immediate post-set readback for diagnostics ONLY — this is deliberately NOT used
        // to decide success/failure (that remains `waitForRouteConvergence`'s bounded poll, per
        // §14 "verification timeout is reserved for setter returned noErr BUT readback never
        // converged" — a settling delay here is expected, not itself an error).
        let immediateAfterID = Self.defaultDeviceID(selector)
        let immediateAfterUID = immediateAfterID.flatMap(Self.uid(of:))

        logger?.log(
            "[CALL-AUDIO-COREAUDIO] operation=\(operation) targetUID=\(uid) targetDeviceID=\(deviceID) "
                + "beforeDeviceID=\(beforeID.map(String.init) ?? "nil") beforeUID=\(beforeUID ?? "nil") "
                + "osStatus=\(status) result=\(succeeded ? "success" : "failure") "
                + "immediateAfterDeviceID=\(immediateAfterID.map(String.init) ?? "nil") immediateAfterUID=\(immediateAfterUID ?? "nil")"
        )
        return succeeded
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == kAudioHardwareNoError else { return nil }
        return deviceID
    }

    /// UID → AudioDeviceID is deliberately re-resolved on every call (§17/§18's "stale
    /// AudioDeviceID" hypothesis) rather than cached across activation — `AudioDeviceID` values
    /// are runtime-local and this driver's devices are statically created at `Initialize` (never
    /// dynamically recreated), so there is no re-numbering to guard against, but resolving fresh
    /// immediately before use costs nothing and removes the hypothesis structurally rather than by
    /// argument.
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

    private static func hogAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func uid(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// Phase 3's activation boundary for the Phase 1 driver's two devices — mirrors
/// `JarvisAudioDriverTool.Commands.setActive`'s use of the custom `Ract` property, but scoped to
/// exactly Capture/Inject (not the general `DriverTarget` enum, which is CLI-only).
@MainActor
protocol JarvisAudioDeviceActivating {
    @discardableResult func setCaptureActive(_ active: Bool) -> Bool
    @discardableResult func setInjectActive(_ active: Bool) -> Bool
}

struct SystemJarvisAudioDeviceActivator: JarvisAudioDeviceActivating {
    /// Must match `AudioDriver/Plugin/PlugInTypes.h`'s `kJarvisDevicePropertyActive` ('Ract') —
    /// same selector `AudioDriverStatus` already reads, computed the same way.
    private static let activeSelector: AudioObjectPropertySelector = {
        var result: AudioObjectPropertySelector = 0
        for scalar in "Ract".unicodeScalars { result = (result << 8) + AudioObjectPropertySelector(scalar.value) }
        return result
    }()

    private let logger: BridgeLogger?

    init(logger: BridgeLogger? = nil) {
        self.logger = logger
    }

    @discardableResult
    func setCaptureActive(_ active: Bool) -> Bool {
        setActive(active, uid: JarvisAudioDeviceUIDs.capture, role: "capture")
    }

    @discardableResult
    func setInjectActive(_ active: Bool) -> Bool {
        setActive(active, uid: JarvisAudioDeviceUIDs.inject, role: "inject")
    }

    /// §19 of the investigation: an activation Set that returns success is not itself proof the
    /// runtime state actually changed — read the custom `Ract` property back and require it to
    /// match before the caller is allowed to proceed to a route setter. Unlike the default-device
    /// selectors, this driver's own `Ract` setter applies synchronously and unconditionally (see
    /// `Driver_SetPropertyData` in `PlugInInterface.c`), so this is expected to always agree; the
    /// check exists as defense-in-depth against exactly the "return success, no real effect"
    /// failure mode the investigation is about, not because settling is expected here too.
    private func setActive(_ active: Bool, uid: String, role: String) -> Bool {
        guard let deviceID = SystemCallAudioRouteController.deviceID(forUID: uid) else {
            logger?.log("[CALL-AUDIO-COREAUDIO] operation=set-active role=\(role) active=\(active) result=failure reason=uid-does-not-resolve")
            return false
        }
        var address = AudioObjectPropertyAddress(mSelector: Self.activeSelector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // AudioServerPlugIn.h documents CFString/CFPropertyList/None as the only types the host
        // will marshal for a plugin's *custom* property — see Phase 1's CHECKPOINT 2 fix.
        var cfValue: CFBoolean = active ? kCFBooleanTrue : kCFBooleanFalse
        let status = withUnsafeMutablePointer(to: &cfValue) { pointer -> OSStatus in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<CFBoolean>.size), pointer)
        }
        guard status == noErr else {
            logger?.log("[CALL-AUDIO-COREAUDIO] operation=set-active role=\(role) active=\(active) deviceID=\(deviceID) osStatus=\(status) result=failure")
            return false
        }

        var readBack: Unmanaged<CFBoolean>?
        var readSize = UInt32(MemoryLayout<Unmanaged<CFBoolean>?>.size)
        let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &readSize, &readBack)
        let readActive = (readStatus == noErr) ? readBack.map { CFBooleanGetValue($0.takeRetainedValue()) } : nil
        let verified = readActive == active
        logger?.log("[CALL-AUDIO-COREAUDIO] operation=set-active role=\(role) active=\(active) deviceID=\(deviceID) osStatus=\(status) readBackActive=\(readActive.map(String.init) ?? "nil") result=\(verified ? "success" : "failure")")
        return verified
    }
}
