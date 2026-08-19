#!/usr/bin/env swift
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Virtual-speaker pass-through using the dedicated Jarvis Speaker device.
/// Activate Speaker, start the M80C player, then set Speaker as default output.
/// Chrome only follows after YouTube is restarted. Requires the rebuilt driver installed.
///
///   /tmp/probe-passthrough-speaker --seconds 180
///   /tmp/probe-passthrough-speaker --seconds 0   # until Ctrl+C

let m80cUID = "4C2D05E0-0000-0000-2B20-0104B5462778"
let speakerUID = "com.jarvis.callbridge.audio.speaker"
let propertyActive: AudioObjectPropertySelector = 0x5261_6374 // 'Ract'
let shmName = "/jarvis-callbridge-speaker-tx"
let ringMagic: UInt32 = 0x4A52_5852
let ringVersion: UInt32 = 1
let ringChannels = 2
let ringCapacity = 48_000

struct RXHeader {
    var magic: UInt32
    var version: UInt32
    var channelCount: UInt32
    var capacityFrames: UInt32
    var writeIndex: UInt64
    var readIndex: UInt64
    var underrunCount: UInt64
    var overrunFrameCount: UInt64
}

func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func cfString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func deviceID(forUID uid: String) -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var uidRef = uid as CFString
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &uidRef) { pointer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
    }
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = address(selector)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
    return id == kAudioObjectUnknown ? nil : id
}

func setDefaultDevice(_ selector: AudioObjectPropertySelector, id: AudioDeviceID) -> OSStatus {
    var addr = address(selector)
    var value = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
}

func waitForDefault(_ selector: AudioObjectPropertySelector, expected: AudioDeviceID) -> Bool {
    for _ in 0..<20 {
        if defaultDeviceID(selector) == expected { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return defaultDeviceID(selector) == expected
}

func setActive(_ id: AudioDeviceID, _ active: Bool) -> OSStatus {
    var addr = address(propertyActive)
    var cfValue: CFBoolean = active ? kCFBooleanTrue : kCFBooleanFalse
    return withUnsafeMutablePointer(to: &cfValue) { pointer in
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<CFBoolean>.size), pointer)
    }
}

func getActive(_ id: AudioDeviceID) -> Bool? {
    var addr = address(propertyActive)
    var value: Unmanaged<CFBoolean>?
    var size = UInt32(MemoryLayout<Unmanaged<CFBoolean>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return CFBooleanGetValue(value.takeRetainedValue())
}

func streamFormat(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    var addr = address(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
    var streamID = AudioObjectID(kAudioObjectUnknown)
    var streamSize = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &streamSize, &streamID) == noErr else { return nil }
    var formatAddr = address(kAudioStreamPropertyVirtualFormat)
    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(streamID, &formatAddr, 0, nil, &formatSize, &format) == noErr else { return nil }
    return format
}

func tapLatest(
    header: UnsafePointer<RXHeader>,
    samples: UnsafePointer<Float>,
    dest: UnsafeMutablePointer<Float>,
    frameCount: Int,
    lastWriteIndex: inout UInt64
) -> Float {
    let capacity = UInt64(max(header.pointee.capacityFrames, 1))
    let channels = Int(max(header.pointee.channelCount, 1))
    let writeIndex = header.pointee.writeIndex
    if writeIndex <= lastWriteIndex {
        for frame in 0..<frameCount {
            dest[frame * 2] = 0
            dest[frame * 2 + 1] = 0
        }
        return 0
    }
    lastWriteIndex = writeIndex
    let available = writeIndex < capacity ? Int(writeIndex) : Int(capacity)
    let toCopy = min(available, frameCount)
    let start = writeIndex &- UInt64(toCopy)
    var peak: Float = 0
    for frame in 0..<toCopy {
        let slot = Int((start &+ UInt64(frame)) % capacity)
        let left = samples[slot * channels]
        let right = channels > 1 ? samples[slot * channels + 1] : left
        dest[frame * 2] = left
        dest[frame * 2 + 1] = right
        peak = max(peak, max(abs(left), abs(right)))
    }
    for frame in toCopy..<frameCount {
        dest[frame * 2] = 0
        dest[frame * 2 + 1] = 0
    }
    return peak
}

func queryStreamCount(_ deviceID: AudioDeviceID, procID: AudioDeviceIOProcID, scope: AudioObjectPropertyScope) -> Int {
    var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
    guard AudioObjectHasProperty(deviceID, &addr) else { return 0 }
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
    let rawProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer?.self)
    guard let rawProc else { return 0 }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: 8)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(dataSize))
    buffer.storeBytes(of: rawProc, toByteOffset: 0, as: UnsafeMutableRawPointer.self)
    var outSize = dataSize
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &outSize, buffer) == noErr else { return 0 }
    return Int(buffer.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self))
}

func setStreamUsage(_ deviceID: AudioDeviceID, procID: AudioDeviceIOProcID, scope: AudioObjectPropertyScope, used: Bool) -> Bool {
    let count = queryStreamCount(deviceID, procID: procID, scope: scope)
    guard count > 0 else { return false }
    var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
    let rawProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer?.self)
    guard let rawProc else { return false }
    var bytes = [UInt8](repeating: 0, count: MemoryLayout<UnsafeRawPointer>.size)
    withUnsafeBytes(of: rawProc) { pointerBytes in
        for index in 0..<min(pointerBytes.count, bytes.count) {
            bytes[index] = pointerBytes[index]
        }
    }
    withUnsafeBytes(of: UInt32(count)) { bytes.append(contentsOf: $0) }
    for _ in 0..<count {
        withUnsafeBytes(of: UInt32(used ? 1 : 0)) { bytes.append(contentsOf: $0) }
    }
    let dataSize = UInt32(bytes.count)
    let status = bytes.withUnsafeMutableBytes { buffer in
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, dataSize, buffer.baseAddress!)
    }
    return status == noErr
}

func writeOutput(
    format: AudioStreamBasicDescription,
    src: UnsafePointer<Float>,
    dst: UnsafeMutableRawPointer,
    frames: Int
) {
    let channels = Int(format.mChannelsPerFrame)
    if format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32 {
        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            let plane = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer<AudioBufferList>(mutating: dst.assumingMemoryBound(to: AudioBufferList.self)))
            // handled by caller via buffer list
            _ = plane
        }
        memcpy(dst, src, frames * 2 * MemoryLayout<Float>.size)
        return
    }
    if format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 16 {
        let out = dst.assumingMemoryBound(to: Int16.self)
        for frame in 0..<frames {
            for channel in 0..<min(channels, 2) {
                let sample = max(-1, min(1, src[frame * 2 + channel]))
                out[frame * channels + channel] = Int16(sample * 32767)
            }
        }
        return
    }
    memcpy(dst, src, frames * 2 * MemoryLayout<Float>.size)
}

setlinebuf(stdout)
setlinebuf(stderr)

var seconds: TimeInterval = 180
let args = Array(CommandLine.arguments.dropFirst())
if let index = args.firstIndex(of: "--seconds"), index + 1 < args.count {
    seconds = TimeInterval(args[index + 1]) ?? seconds
}

guard let speakerDeviceID = deviceID(forUID: speakerUID) else {
    print("FAIL Jarvis Speaker not found — rebuild and reinstall the driver")
    exit(1)
}
guard let speakerID = deviceID(forUID: m80cUID) else {
    print("FAIL M80C not found")
    exit(1)
}

let originalOutputID = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
let originalOutputUID = originalOutputID.flatMap { cfString($0, kAudioDevicePropertyDeviceUID) } ?? "?"
let originalOutputName = originalOutputID.flatMap { cfString($0, kAudioObjectPropertyName) } ?? "?"
print("original-output=\(originalOutputName) uid=\(originalOutputUID)")

let speakerWasActive = getActive(speakerDeviceID) ?? false
print("speaker-was-active=\(speakerWasActive) speakerDeviceID=\(speakerDeviceID) m80cID=\(speakerID)")
if !speakerWasActive {
    let activateStatus = setActive(speakerDeviceID, true)
    print("activate-speaker status=\(activateStatus)")
    guard activateStatus == noErr else {
        print("FAIL activate Speaker")
        exit(1)
    }
    Thread.sleep(forTimeInterval: 0.2)
}

typealias ShmOpenFn = @convention(c) (UnsafePointer<CChar>, Int32, mode_t) -> Int32
let libc = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW)
let shmOpen = unsafeBitCast(dlsym(libc, "shm_open"), to: ShmOpenFn.self)
let mappingSize = MemoryLayout<RXHeader>.size + ringChannels * ringCapacity * MemoryLayout<Float>.size
let fd = shmOpen(shmName, O_RDWR, 0o666)
guard fd >= 0 else {
    print("FAIL shm_open \(shmName) errno=\(errno) — install the rebuilt driver so Speaker TX ring exists")
    if !speakerWasActive { _ = setActive(speakerDeviceID, false) }
    exit(1)
}
let mapped = mmap(nil, mappingSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
guard mapped != MAP_FAILED, let mapped else {
    print("FAIL mmap")
    close(fd)
    if !speakerWasActive { _ = setActive(speakerDeviceID, false) }
    exit(1)
}
let header = mapped.assumingMemoryBound(to: RXHeader.self)
guard header.pointee.magic == ringMagic, header.pointee.version == ringVersion else {
    print("FAIL ring magic/version magic=\(header.pointee.magic) version=\(header.pointee.version)")
    munmap(mapped, mappingSize)
    close(fd)
    if !speakerWasActive { _ = setActive(speakerDeviceID, false) }
    exit(1)
}
let samples = UnsafePointer<Float>(OpaquePointer(mapped.advanced(by: MemoryLayout<RXHeader>.size)))
print("ring ok writeIndex=\(header.pointee.writeIndex) channels=\(header.pointee.channelCount) capacity=\(header.pointee.capacityFrames)")

guard let format = streamFormat(speakerID, scope: kAudioObjectPropertyScopeOutput) else {
    print("FAIL M80C output format")
    munmap(mapped, mappingSize)
    close(fd)
    if !speakerWasActive { _ = setActive(speakerDeviceID, false) }
    exit(1)
}
print("m80c format rate=\(format.mSampleRate) bits=\(format.mBitsPerChannel) ch=\(format.mChannelsPerFrame) flags=\(format.mFormatFlags)")

var lastPeakBits: UInt32 = 0
var callbackCount: UInt64 = 0
var emptyOutputCount: UInt64 = 0
var lastWriteIndex: UInt64 = 0

var procID: AudioDeviceIOProcID?
let bytesPerFrame = format.mBytesPerFrame > 0 ? Int(format.mBytesPerFrame) : Int(format.mChannelsPerFrame) * Int(format.mBitsPerChannel / 8)
print("m80c bytesPerFrame=\(bytesPerFrame) headerSize=\(MemoryLayout<RXHeader>.size)")
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, speakerID, DispatchQueue.global(qos: .userInteractive)) { _, _, _, outOutput, _ in
    let outList = UnsafeMutableAudioBufferListPointer(outOutput)
    callbackCount &+= 1
    guard let first = outList.first, let dst = first.mData, first.mDataByteSize > 0 else {
        emptyOutputCount &+= 1
        return
    }
    let outFrames = Int(first.mDataByteSize) / max(bytesPerFrame, 1)
    guard outFrames > 0 else {
        emptyOutputCount &+= 1
        return
    }
    var interleaved = [Float](repeating: 0, count: outFrames * 2)
    let peak = tapLatest(header: UnsafePointer(header), samples: samples, dest: &interleaved, frameCount: outFrames, lastWriteIndex: &lastWriteIndex)
    var bits: UInt32 = 0
    withUnsafeBytes(of: peak) { bits = $0.load(as: UInt32.self) }
    lastPeakBits = bits
    if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
        for (index, buffer) in outList.enumerated() where index < 2 {
            guard let plane = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let planeFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for frame in 0..<min(planeFrames, outFrames) {
                plane[frame] = interleaved[frame * 2 + index]
            }
        }
        return
    }
    writeOutput(format: format, src: &interleaved, dst: dst, frames: outFrames)
}
print("create-ioproc status=\(ioStatus)")
guard ioStatus == noErr, let procID else {
    munmap(mapped, mappingSize)
    close(fd)
    if !speakerWasActive { _ = setActive(speakerDeviceID, false) }
    print("FAIL ioproc")
    exit(1)
}

let inputOff = setStreamUsage(speakerID, procID: procID, scope: kAudioObjectPropertyScopeInput, used: false)
let outputOn = setStreamUsage(speakerID, procID: procID, scope: kAudioObjectPropertyScopeOutput, used: true)
print("stream-usage inputOff=\(inputOff) outputOn=\(outputOn)")

let startStatus = AudioDeviceStart(speakerID, procID)
print("start-m80c status=\(startStatus)")
guard startStatus == noErr else {
    AudioDeviceDestroyIOProcID(speakerID, procID)
    munmap(mapped, mappingSize)
    close(fd)
    if !speakerWasActive { _ = setActive(speakerDeviceID, false) }
    print("FAIL start M80C")
    exit(1)
}

let setOut = setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, id: speakerDeviceID)
print("set-default-output-speaker status=\(setOut)")
let outputNowSpeaker = waitForDefault(kAudioHardwarePropertyDefaultOutputDevice, expected: speakerDeviceID)
print("default-output-is-speaker=\(outputNowSpeaker)")

func release() {
    if let m80c = deviceID(forUID: m80cUID) {
        _ = setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, id: m80c)
        _ = waitForDefault(kAudioHardwarePropertyDefaultOutputDevice, expected: m80c)
    } else if let originalOutputID, originalOutputID != speakerDeviceID {
        _ = setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, id: originalOutputID)
        _ = waitForDefault(kAudioHardwarePropertyDefaultOutputDevice, expected: originalOutputID)
    }
    AudioDeviceStop(speakerID, procID)
    AudioDeviceDestroyIOProcID(speakerID, procID)
    munmap(mapped, mappingSize)
    close(fd)
    if !speakerWasActive {
        _ = setActive(speakerDeviceID, false)
    }
    print("RELEASED default-output restored to \(originalOutputName). Restart YouTube if it stays on Jarvis Speaker.")
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler {
    FileHandle.standardError.write(Data("\nSIGINT — releasing\n".utf8))
    release()
    exit(0)
}
sigint.resume()

print("PASSTHROUGH armed — restart YouTube NOW so Chrome binds to Jarvis Speaker")
print("YouTube should play on M80C through Jarvis Speaker. Then answer a call and listen if it stays loud.")
print("seconds=\(seconds == 0 ? "until-SIGINT" : String(Int(seconds)))")

func logPulse() {
    var peak: Float = 0
    withUnsafeBytes(of: lastPeakBits) { peak = $0.load(as: Float.self) }
    print("pulse writeIndex=\(header.pointee.writeIndex) peak=\(String(format: "%.4f", peak)) callbacks=\(callbackCount) emptyOut=\(emptyOutputCount)")
}

if seconds <= 0 {
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in logPulse() }
    dispatchMain()
} else {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        Thread.sleep(forTimeInterval: 1)
        logPulse()
    }
    release()
}
