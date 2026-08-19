import CoreAudio
import Foundation

/// Phase 3 CHECKPOINT 2 — RX IOProc Stream Usage / Input Buffer Delivery investigation.
///
/// `kAudioDevicePropertyIOProcStreamUsage` query + the Phase 3 CHECKPOINT 2 RX fix Set.
///
/// Per `AudioHardware.h`: "If a stream is marked as not being used, the given IOProc will see a
/// corresponding NULL buffer pointer in the AudioBufferList passed to its IO proc." Same-call
/// evidence (driver Capture INPUT peak > 0, Bridge RX stuck at -96 dBFS) localized the failure
/// to HAL handing `JarvisPCMCaptureIOProc` a zeroed full-duplex buffer. Capture therefore Sets
/// output streams unused (input stays on) after `AudioDeviceCreateIOProcID` and before
/// `AudioDeviceStart`. Inject Sets input unused (output stays on). Parse/encode stay
/// CoreAudio-free so automated tests never touch a real device.
enum IOProcStreamUsageReader {
    struct Snapshot: Equatable {
        let streamCount: Int
        let enabled: [Bool]
    }

    /// Pure parsing of an `AudioHardwareIOProcStreamUsage`-shaped byte buffer:
    /// `mIOProc` (pointer-sized) + `mNumberStreams` (UInt32) + `mNumberStreams` × UInt32
    /// (`mStreamIsOn`). Never touches CoreAudio — this is what makes the format testable without
    /// a real device (§28). Returns `nil` on any malformed/undersized input (§28's "incorrect
    /// returned byte size" case) rather than crashing or fabricating a value.
    static func parse(rawBytes: [UInt8], pointerSize: Int = MemoryLayout<UnsafeRawPointer>.size) -> Snapshot? {
        let headerSize = pointerSize + MemoryLayout<UInt32>.size
        guard rawBytes.count >= headerSize else { return nil }

        let streamCount32 = rawBytes.withUnsafeBytes { buffer -> UInt32 in
            buffer.loadUnaligned(fromByteOffset: pointerSize, as: UInt32.self)
        }
        let streamCount = Int(streamCount32)
        guard streamCount >= 0 else { return nil }

        let expectedTotalSize = headerSize + streamCount * MemoryLayout<UInt32>.size
        guard rawBytes.count >= expectedTotalSize else { return nil }

        guard streamCount > 0 else { return Snapshot(streamCount: 0, enabled: []) }

        var enabled: [Bool] = []
        enabled.reserveCapacity(streamCount)
        rawBytes.withUnsafeBytes { buffer in
            for index in 0..<streamCount {
                let value = buffer.loadUnaligned(fromByteOffset: headerSize + index * MemoryLayout<UInt32>.size, as: UInt32.self)
                enabled.append(value != 0)
            }
        }
        return Snapshot(streamCount: streamCount, enabled: enabled)
    }

    static func flags(streamCount: Int, used: Bool) -> [Bool] {
        guard streamCount > 0 else { return [] }
        return Array(repeating: used, count: streamCount)
    }

    /// Inverse of `parse` — `mIOProc` bytes stay zero here; `setAllStreams` overwrites them
    /// with the live `AudioDeviceIOProcID` immediately before `AudioObjectSetPropertyData`.
    static func encode(enabled: [Bool], pointerSize: Int = MemoryLayout<UnsafeRawPointer>.size) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: pointerSize)
        withUnsafeBytes(of: UInt32(enabled.count)) { bytes.append(contentsOf: $0) }
        for flag in enabled {
            withUnsafeBytes(of: UInt32(flag ? 1 : 0)) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    /// Real CoreAudio query — intentionally not exercised by automated tests (would require a
    /// real device/IOProc; `parse(rawBytes:)` above carries the unit-testable logic). Fills the
    /// required `mIOProc` field with the live `AudioDeviceIOProcID` per the SDK's documented
    /// "when getting the value of the property, one must fill out the mIOProc field" requirement.
    /// Returns `nil` on any failure (property absent, size query failure, get failure, or
    /// malformed payload) — never fabricates a reading.
    static func query(deviceID: AudioDeviceID, procID: AudioDeviceIOProcID, scope: AudioObjectPropertyScope) -> Snapshot? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return nil }

        let rawProcPointer = unsafeBitCast(procID, to: UnsafeMutableRawPointer?.self)
        guard let rawProcPointer else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(dataSize))
        buffer.storeBytes(of: rawProcPointer, toByteOffset: 0, as: UnsafeMutableRawPointer.self)

        var outSize = dataSize
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &outSize, buffer)
        guard status == noErr else { return nil }

        let bytes = [UInt8](UnsafeRawBufferPointer(start: buffer, count: Int(outSize)))
        return parse(rawBytes: bytes)
    }

    /// One `[CALL-PCM-STREAM-USAGE]` line per direction, read-only. `role` is `"capture"`/
    /// `"inject"`; `scope` is whichever direction actually matters for that device
    /// (`kAudioObjectPropertyScopeInput` for Capture, `kAudioObjectPropertyScopeOutput` for
    /// Inject) — matching how the rest of this controller already scopes format queries.
    @MainActor
    static func logSnapshot(role: String, scopeLabel: String, deviceID: AudioDeviceID, procID: AudioDeviceIOProcID, scope: AudioObjectPropertyScope, logger: BridgeLogger) {
        guard let snapshot = query(deviceID: deviceID, procID: procID, scope: scope) else {
            logger.log("[CALL-PCM-STREAM-USAGE] role=\(role) scope=\(scopeLabel) result=unavailable")
            return
        }
        let enabledList = snapshot.enabled.map { $0 ? "1" : "0" }.joined(separator: ",")
        logger.log("[CALL-PCM-STREAM-USAGE] role=\(role) scope=\(scopeLabel) streamCount=\(snapshot.streamCount) enabled=[\(enabledList)]")
    }

    /// Sets every stream in `scope` on or off for this IOProc. Query-first so the payload's
    /// `mNumberStreams` matches the host; never invents a stream count. Returns `false` on any
    /// failure without throwing — caller logs and decides whether to continue PCM start.
    @discardableResult
    static func setAllStreams(deviceID: AudioDeviceID, procID: AudioDeviceIOProcID, scope: AudioObjectPropertyScope, used: Bool) -> Bool {
        guard let current = query(deviceID: deviceID, procID: procID, scope: scope) else { return false }
        let desired = flags(streamCount: current.streamCount, used: used)
        guard !desired.isEmpty else { return true }
        if current.enabled == desired { return true }

        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue else { return false }

        let rawProcPointer = unsafeBitCast(procID, to: UnsafeMutableRawPointer?.self)
        guard let rawProcPointer else { return false }

        var bytes = encode(enabled: desired)
        withUnsafeBytes(of: rawProcPointer) { pointerBytes in
            for index in 0..<min(pointerBytes.count, MemoryLayout<UnsafeRawPointer>.size) {
                bytes[index] = pointerBytes[index]
            }
        }

        let dataSize = UInt32(bytes.count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, buffer.baseAddress!)
        }
        return status == noErr
    }

    @MainActor
    static func configureAndLog(role: String, deviceID: AudioDeviceID, procID: AudioDeviceIOProcID, inputUsed: Bool, outputUsed: Bool, logger: BridgeLogger) {
        logSnapshot(role: role, scopeLabel: "input", deviceID: deviceID, procID: procID, scope: kAudioObjectPropertyScopeInput, logger: logger)
        logSnapshot(role: role, scopeLabel: "output", deviceID: deviceID, procID: procID, scope: kAudioObjectPropertyScopeOutput, logger: logger)

        let inputOK = setAllStreams(deviceID: deviceID, procID: procID, scope: kAudioObjectPropertyScopeInput, used: inputUsed)
        let outputOK = setAllStreams(deviceID: deviceID, procID: procID, scope: kAudioObjectPropertyScopeOutput, used: outputUsed)
        logger.log("[CALL-PCM-STREAM-USAGE] role=\(role) set inputUsed=\(inputUsed) inputOK=\(inputOK) outputUsed=\(outputUsed) outputOK=\(outputOK)")

        logSnapshot(role: role, scopeLabel: "input", deviceID: deviceID, procID: procID, scope: kAudioObjectPropertyScopeInput, logger: logger)
        logSnapshot(role: role, scopeLabel: "output", deviceID: deviceID, procID: procID, scope: kAudioObjectPropertyScopeOutput, logger: logger)
    }
}
