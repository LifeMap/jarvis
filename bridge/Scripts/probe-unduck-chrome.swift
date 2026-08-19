#!/usr/bin/env swift
import AudioToolbox
import CoreAudio
import Foundation

/// Mute Chrome HAL playback and replay the process tap onto M80C.
///
/// Test 1 — already-ducked call, boost the tap:
///   swift probe-unduck-chrome.swift --gain-db 12 --seconds 20
///
/// Test 2 — own the mix BEFORE answering (0 dB, stay up so a call can land):
///   swift probe-unduck-chrome.swift --gain-db 0 --seconds 180
///
///   swift probe-unduck-chrome.swift --seconds 0   # until Ctrl+C

let m80cUID = "4C2D05E0-0000-0000-2B20-0104B5462778"
let chromeBundles = ["com.google.Chrome.helper", "com.google.Chrome"]

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

func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func objectIDs(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = address(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func chromeProcessIDs() -> [AudioObjectID] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter { objectID in
        let bundle = cfString(objectID, kAudioProcessPropertyBundleID) ?? ""
        guard chromeBundles.contains(bundle) else { return false }
        return uint32(objectID, kAudioProcessPropertyIsRunningOutput) == 1
    }
}

func runningOutputBundles() -> [String] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { objectID in
        guard uint32(objectID, kAudioProcessPropertyIsRunningOutput) == 1 else { return nil }
        return cfString(objectID, kAudioProcessPropertyBundleID)
    }.sorted()
}

func applyGain(src: UnsafeRawPointer, dst: UnsafeMutableRawPointer, byteCount: Int, gain: Float) {
    let count = byteCount / MemoryLayout<Float>.size
    let inSamples = src.bindMemory(to: Float.self, capacity: count)
    let outSamples = dst.bindMemory(to: Float.self, capacity: count)
    if gain == 1 {
        if src != UnsafeRawPointer(dst) {
            memcpy(dst, src, byteCount)
        }
        return
    }
    for index in 0..<count {
        let boosted = inSamples[index] * gain
        outSamples[index] = max(-1, min(1, boosted))
    }
}

var seconds: TimeInterval = 20
var gainDB: Float = 0
let args = Array(CommandLine.arguments.dropFirst())
if let index = args.firstIndex(of: "--seconds"), index + 1 < args.count {
    seconds = TimeInterval(args[index + 1]) ?? seconds
}
if let index = args.firstIndex(of: "--gain-db"), index + 1 < args.count {
    gainDB = Float(args[index + 1]) ?? gainDB
}
let gain = pow(10 as Float, gainDB / 20)

setlinebuf(stdout)
setlinebuf(stderr)

let writers = runningOutputBundles()
print("running-output=\(writers)")
let callLikely = writers.contains { $0 == "com.apple.avconferenced" }
print("call-likely=\(callLikely)")

let processes = chromeProcessIDs()
print("chrome output processes=\(processes) gain-db=\(gainDB) gain-lin=\(String(format: "%.3f", gain)) seconds=\(seconds == 0 ? "until-SIGINT" : String(Int(seconds)))")
guard !processes.isEmpty else {
    print("FAIL no Chrome helper is currently playing")
    exit(1)
}

let description = CATapDescription(stereoMixdownOfProcesses: processes)
description.name = "Jarvis Unduck Chrome"
description.uuid = UUID()
description.isPrivate = true
description.muteBehavior = .muted

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
print("create-tap status=\(tapStatus) tapID=\(tapID)")
guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
    print("FAIL tap-create")
    exit(1)
}

let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Jarvis Unduck Chrome Agg",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: m80cUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: m80cUID],
    ],
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: description.uuid.uuidString],
    ],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
print("create-aggregate status=\(aggStatus) aggID=\(aggregateID)")
guard aggStatus == noErr, aggregateID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    print("FAIL aggregate-create")
    exit(1)
}

var procID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, DispatchQueue.global(qos: .userInteractive)) { _, inInput, _, outOutput, _ in
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    let outList = UnsafeMutableAudioBufferListPointer(outOutput)
    for index in 0..<min(inList.count, outList.count) {
        guard let src = inList[index].mData, let dst = outList[index].mData else { continue }
        let byteCount = min(Int(inList[index].mDataByteSize), Int(outList[index].mDataByteSize))
        applyGain(src: src, dst: dst, byteCount: byteCount, gain: gain)
        outList[index].mDataByteSize = UInt32(byteCount)
    }
}
print("create-ioproc status=\(ioStatus)")
guard ioStatus == noErr, let procID else {
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    print("FAIL ioproc")
    exit(1)
}

let startStatus = AudioDeviceStart(aggregateID, procID)
print("start status=\(startStatus)")
guard startStatus == noErr else {
    AudioDeviceDestroyIOProcID(aggregateID, procID)
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    print("FAIL start")
    exit(1)
}

func release() {
    AudioDeviceStop(aggregateID, procID)
    AudioDeviceDestroyIOProcID(aggregateID, procID)
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    print("RELEASED — Chrome HAL playback is back. If a call is still up, YouTube should return to the ducked level.")
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    FileHandle.standardError.write(Data("\nSIGINT — releasing tap\n".utf8))
    release()
    exit(0)
}
sigint.resume()

if gainDB == 0 {
    print("PASSTHROUGH armed — YouTube should stay at the current level (we own Chrome → M80C)")
    if callLikely {
        print("NOTE call already looks active. Test 2 needs this started BEFORE answer.")
    } else {
        print("Now answer a call. If YouTube stays loud, owning the mix before ducking works.")
    }
} else {
    print("BOOST armed +\(gainDB) dB for \(Int(seconds))s — listen whether YouTube gets loud on M80C")
    if !callLikely {
        print("NOTE no avconferenced output. Test 1 needs an already-ducked call.")
    }
}

if seconds <= 0 {
    dispatchMain()
} else {
    Thread.sleep(forTimeInterval: seconds)
    release()
}
