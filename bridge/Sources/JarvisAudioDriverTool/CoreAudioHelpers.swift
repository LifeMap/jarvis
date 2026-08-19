import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case deviceNotFound(String)

    var description: String {
        switch self {
        case .osStatus(let call, let status):
            return "\(call) failed, OSStatus=\(CoreAudioHelpers.formatOSStatus(status))"
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

    /// Mirrors PlugInTypes.h's `JarvisPCMDeviceDiagnostics` C struct byte-for-byte (verified
    /// offsets: version=0, ioClientCount=4, outputOperationCount=8, outputFrames=16,
    /// outputNonZeroCallbacks=24, outputPeakLinear=32, loopbackWriteFrames=40,
    /// loopbackReadFrames=48, loopbackUnderrunCount=56, loopbackOverrunFrameCount=64,
    /// inputOperationCount=72, inputFrames=80, inputNonZeroCallbacks=88, inputPeakLinear=96;
    /// sizeof=104 on LP64 Darwin). There is no shared C header between this tool's process and
    /// the driver process (same constraint as the `Ract`/`Rclr` selectors above), so the CFData
    /// payload is decoded field-by-field at these fixed offsets rather than assumed to match
    /// Swift's own (unspecified) struct layout.
    struct PCMDeviceDiagnostics {
        let version: UInt32
        let ioClientCount: UInt32
        let outputOperationCount: Int64
        let outputFrames: Int64
        let outputNonZeroCallbacks: Int64
        let outputPeakLinear: Float
        let loopbackWriteFrames: UInt64
        let loopbackReadFrames: UInt64
        let loopbackUnderrunCount: UInt64
        let loopbackOverrunFrameCount: UInt64
        let inputOperationCount: Int64
        let inputFrames: Int64
        let inputNonZeroCallbacks: Int64
        let inputPeakLinear: Float
    }

    /// Must match PlugInTypes.h's `JarvisPCMDeviceDiagnostics.version` — the only version this
    /// decoder knows how to interpret. Bumped only in lockstep with a driver-side layout change.
    static let pcmDiagnosticsSupportedVersion: UInt32 = 1

    /// Pure decode — the ONE place this payload's byte layout is interpreted (§27: "do not
    /// maintain two ambiguous decoding paths"). `getPCMDiagnostics` below is the only production
    /// caller; unit tests exercise this directly with synthetic `Data`, never touching CoreAudio.
    /// Returns `nil` for anything that doesn't decode safely: too-short data (§28's "short CFData"
    /// case) or an unsupported `version` field (§28 — "on mismatch ... stop decoding", never
    /// reinterpret an unknown layout's remaining bytes as if they matched the current one).
    static func decodePCMDiagnostics(from data: Data) -> PCMDeviceDiagnostics? {
        guard data.count >= 104 else { return nil }
        let version = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard version == pcmDiagnosticsSupportedVersion else { return nil }
        return data.withUnsafeBytes { raw -> PCMDeviceDiagnostics in
            PCMDeviceDiagnostics(
                version: version,
                ioClientCount: raw.load(fromByteOffset: 4, as: UInt32.self),
                outputOperationCount: raw.load(fromByteOffset: 8, as: Int64.self),
                outputFrames: raw.load(fromByteOffset: 16, as: Int64.self),
                outputNonZeroCallbacks: raw.load(fromByteOffset: 24, as: Int64.self),
                outputPeakLinear: raw.load(fromByteOffset: 32, as: Float.self),
                loopbackWriteFrames: raw.load(fromByteOffset: 40, as: UInt64.self),
                loopbackReadFrames: raw.load(fromByteOffset: 48, as: UInt64.self),
                loopbackUnderrunCount: raw.load(fromByteOffset: 56, as: UInt64.self),
                loopbackOverrunFrameCount: raw.load(fromByteOffset: 64, as: UInt64.self),
                inputOperationCount: raw.load(fromByteOffset: 72, as: Int64.self),
                inputFrames: raw.load(fromByteOffset: 80, as: Int64.self),
                inputNonZeroCallbacks: raw.load(fromByteOffset: 88, as: Int64.self),
                inputPeakLinear: raw.load(fromByteOffset: 96, as: Float.self)
            )
        }
    }

    /// §30 — centralized OSStatus formatting: decimal always, plus the FourCC reading ONLY when
    /// all four bytes are printable ASCII (never a guessed/invented symbolic name for anything
    /// not actually spelled out that way — an unprintable value is reported as the bare decimal
    /// OSStatus and nothing else).
    static func formatOSStatus(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let fourCC = String(bytes: bytes, encoding: .ascii) else {
            return "\(status)"
        }
        return "\(status) ('\(fourCC)')"
    }

    /// §9-§15 investigation — every CoreAudio stage of a single Rpcm read, kept separate so a
    /// caller (`pcm-inspect-stability`) can report exactly which stage failed rather than only
    /// "the read failed". This is the ONE canonical Rpcm-reading implementation (§15/§27 — no
    /// second, subtly different property-read code path exists anywhere else in this tool);
    /// `getPCMDiagnostics` below is a thin throwing convenience wrapper around it, and
    /// `pcm-inspect`/`pcm-inspect-stability` both ultimately call through here.
    struct PCMDiagnosticsStageResult {
        let hasPropertyBefore: Bool
        let sizeStatus: OSStatus
        let returnedSize: UInt32
        let dataStatus: OSStatus
        let hasPropertyAfter: Bool
        let diagnostics: PCMDeviceDiagnostics?

        var succeeded: Bool { hasPropertyBefore && sizeStatus == noErr && dataStatus == noErr && diagnostics != nil && hasPropertyAfter }
    }

    static func readPCMDiagnosticsStaged(_ deviceID: AudioObjectID) -> PCMDiagnosticsStageResult {
        var address = AudioObjectPropertyAddress(mSelector: JarvisCallAudio.propertyPCMDiagnostics, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

        let hasBefore = AudioObjectHasProperty(deviceID, &address)
        guard hasBefore else {
            return PCMDiagnosticsStageResult(hasPropertyBefore: false, sizeStatus: noErr, returnedSize: 0, dataStatus: noErr, hasPropertyAfter: false, diagnostics: nil)
        }

        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            return PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: sizeStatus, returnedSize: size, dataStatus: noErr, hasPropertyAfter: AudioObjectHasProperty(deviceID, &address), diagnostics: nil)
        }

        var value: Unmanaged<CFData>?
        var dataSize = size
        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard dataStatus == noErr, let value else {
            return PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: sizeStatus, returnedSize: size, dataStatus: dataStatus, hasPropertyAfter: AudioObjectHasProperty(deviceID, &address), diagnostics: nil)
        }
        // Cross-process CF property marshaling hands this client its own owned proxy object —
        // matching the "caller releases" contract AudioServerPlugIn.h documents for
        // CopyFromStorage's CFPropertyList values (the only explicit ownership language in that
        // header for this exact leaf type), and the same convention already relied on by
        // getBoolProperty/getCFString above.
        let data = value.takeRetainedValue() as Data
        let decoded = decodePCMDiagnostics(from: data)
        let hasAfter = AudioObjectHasProperty(deviceID, &address)
        return PCMDiagnosticsStageResult(hasPropertyBefore: true, sizeStatus: sizeStatus, returnedSize: size, dataStatus: dataStatus, hasPropertyAfter: hasAfter, diagnostics: decoded)
    }

    /// Read-only. Never calls AudioObjectSetPropertyData — `kJarvisDevicePropertyPCMDiagnostics`
    /// has no settable case in the driver's Driver_SetPropertyData at all.
    static func getPCMDiagnostics(_ deviceID: AudioObjectID) throws -> PCMDeviceDiagnostics {
        let staged = readPCMDiagnosticsStaged(deviceID)
        guard staged.hasPropertyBefore else { throw CoreAudioError.osStatus("HasProperty(PCMDiagnostics)", kAudioHardwareUnknownPropertyError) }
        guard staged.sizeStatus == noErr else { throw CoreAudioError.osStatus("GetPropertyDataSize(PCMDiagnostics)", staged.sizeStatus) }
        guard staged.dataStatus == noErr else { throw CoreAudioError.osStatus("GetPropertyData(PCMDiagnostics)", staged.dataStatus) }
        guard let decoded = staged.diagnostics else {
            throw CoreAudioError.osStatus("GetPropertyData(PCMDiagnostics) undersized payload or unsupported diagnostics version", staged.dataStatus)
        }
        return decoded
    }

    struct RouteSnapshot: Equatable, CustomStringConvertible {
        let inputName: String
        let outputName: String
        let systemOutputName: String

        var description: String { "Input=\(inputName) Output=\(outputName) SystemOutput=\(systemOutputName)" }
    }

    /// Every AudioDeviceID currently registered with the HAL — real hardware, other virtual
    /// drivers (e.g. a third-party HAL plug-in), and this driver's own devices all appear here
    /// alongside each other; read-only, never mutates anything.
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        guard status == noErr else { return [] }
        return devices
    }

    static func getUID(_ deviceID: AudioDeviceID) -> String? {
        try? getCFString(deviceID, kAudioDevicePropertyDeviceUID)
    }

    static func getName(_ deviceID: AudioDeviceID) -> String? {
        try? getCFString(deviceID, kAudioObjectPropertyName)
    }

    static func getManufacturer(_ deviceID: AudioDeviceID) -> String? {
        try? getCFString(deviceID, kAudioObjectPropertyManufacturer)
    }

    static func totalChannels(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        guard let streams = try? getStreams(deviceID, scope: scope) else { return 0 }
        return streams.reduce(0) { total, streamID in
            guard let format = try? getFormat(streamID) else { return total }
            return total + Int(format.mChannelsPerFrame)
        }
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
