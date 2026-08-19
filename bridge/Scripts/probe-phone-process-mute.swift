#!/usr/bin/env swift
import AudioToolbox
import CoreAudio
import Foundation

/// Read-only HAL process dump, plus an optional Phone.app-only mute tap scoped to one output.
/// Does not change default devices and does not hog.
///
/// Usage:
///   swift probe-phone-process-mute.swift list
///   swift probe-phone-process-mute.swift mute --uid 4C2D05E0-0000-0000-2B20-0104B5462778 --seconds 20

let m80cUIDDefault = "4C2D05E0-0000-0000-2B20-0104B5462778"
let safeMuteBundles: Set<String> = [
    "com.apple.mobilephone",
    "com.apple.FaceTime",
    "com.apple.InCallService",
]
let neverMuteBundles: Set<String> = [
    "com.apple.mediaserverd",
    "com.apple.audio.coreaudiod",
    "com.apple.coreaudiod",
]

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

func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = address(selector, scope: scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func pidValue(_ id: AudioObjectID) -> pid_t? {
    var addr = address(kAudioProcessPropertyPID)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
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

func deviceName(_ id: AudioDeviceID) -> String {
    cfString(id, kAudioObjectPropertyName) ?? "id=\(id)"
}

func deviceUID(_ id: AudioDeviceID) -> String {
    cfString(id, kAudioDevicePropertyDeviceUID) ?? "?"
}

struct HALProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let runningOut: Bool
    let runningIn: Bool
    let outputDevices: [(id: AudioDeviceID, name: String, uid: String)]
    let inputDevices: [(id: AudioDeviceID, name: String, uid: String)]
}

func allProcesses() -> [HALProcess] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { objectID in
        let pid = pidValue(objectID) ?? -1
        let bundle = cfString(objectID, kAudioProcessPropertyBundleID) ?? "?"
        let outs = objectIDs(objectID, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).map {
            (id: $0, name: deviceName($0), uid: deviceUID($0))
        }
        let ins = objectIDs(objectID, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput).map {
            (id: $0, name: deviceName($0), uid: deviceUID($0))
        }
        return HALProcess(
            objectID: objectID,
            pid: pid,
            bundleID: bundle,
            runningOut: uint32(objectID, kAudioProcessPropertyIsRunningOutput) == 1,
            runningIn: uint32(objectID, kAudioProcessPropertyIsRunningInput) == 1,
            outputDevices: outs,
            inputDevices: ins
        )
    }
}

func printProcessList(targetUID: String) {
    let processes = allProcesses()
    print("HAL processes: \(processes.count)")
    for process in processes.sorted(by: { $0.bundleID < $1.bundleID }) {
        let outHit = process.outputDevices.contains { $0.uid == targetUID }
        let marker = outHit ? " ★M80C-OUT" : ""
        let outNames = process.outputDevices.map(\.name).joined(separator: ",")
        let inNames = process.inputDevices.map(\.name).joined(separator: ",")
        print("  \(process.bundleID) pid=\(process.pid) obj=\(process.objectID) outRun=\(process.runningOut) inRun=\(process.runningIn) out=[\(outNames)] in=[\(inNames)]\(marker)")
    }
    let writers = processes.filter { process in
        process.outputDevices.contains { $0.uid == targetUID }
    }
    print("writers-to-target: \(writers.map(\.bundleID).joined(separator: ", "))")
}

func parseArgs() -> (mode: String, uid: String, seconds: TimeInterval, bundles: [String]) {
    let args = Array(CommandLine.arguments.dropFirst())
    let mode = args.first ?? "list"
    var uid = m80cUIDDefault
    var seconds: TimeInterval = 20
    var bundles = Array(safeMuteBundles)
    var index = 1
    while index < args.count {
        let arg = args[index]
        if arg == "--uid", index + 1 < args.count {
            uid = args[index + 1]
            index += 2
        } else if arg == "--seconds", index + 1 < args.count {
            seconds = TimeInterval(args[index + 1]) ?? seconds
            index += 2
        } else if arg == "--bundle", index + 1 < args.count {
            bundles = args[index + 1].split(separator: ",").map(String.init)
            index += 2
        } else {
            index += 1
        }
    }
    return (mode, uid, seconds, bundles)
}

func muteTarget(uid: String, seconds: TimeInterval, bundles: [String]) {
    let forbidden = bundles.filter { neverMuteBundles.contains($0) }
    precondition(forbidden.isEmpty, "refusing to mute \(forbidden)")

    let matches = allProcesses().filter { bundles.contains($0.bundleID) }
    print("mute candidates:")
    if matches.isEmpty {
        print("  none of \(bundles.joined(separator: ", ")) have a HAL process object yet")
    } else {
        for process in matches {
            print("  \(process.bundleID) pid=\(process.pid) obj=\(process.objectID) out=\(process.outputDevices.map(\.name).joined(separator: ","))")
        }
    }

    let objectIDsToTap = matches.map(\.objectID)
    let description: CATapDescription
    if objectIDsToTap.isEmpty {
        description = CATapDescription()
        description.bundleIDs = bundles
        description.isProcessRestoreEnabled = true
    } else {
        description = CATapDescription(stereoMixdownOfProcesses: objectIDsToTap)
        description.bundleIDs = bundles
        description.isProcessRestoreEnabled = true
    }
    description.name = "Jarvis Phone Mute Probe"
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = .muted

    var tapID = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
    print("create-tap status=\(tapStatus) tapID=\(tapID) scope=process-only")
    guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
        print("FAIL tap-create")
        return
    }

    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Jarvis Phone Mute Probe Agg",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: "BuiltInSpeakerDevice",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: "BuiltInSpeakerDevice"],
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ],
        ],
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
    print("create-aggregate status=\(aggStatus) aggID=\(aggregateID)")
    guard aggStatus == noErr, aggregateID != kAudioObjectUnknown else {
        AudioHardwareDestroyProcessTap(tapID)
        print("FAIL aggregate-create — tap alone does not mute")
        return
    }

    print("MUTE armed for \(Int(seconds))s on uid=\(uid) bundles=\(bundles.joined(separator: ","))")
    print("Listen now: M80C call voice should drop; YouTube/meeting on M80C should stay.")
    Thread.sleep(forTimeInterval: seconds)

    let destroyAgg = AudioHardwareDestroyAggregateDevice(aggregateID)
    let destroyTap = AudioHardwareDestroyProcessTap(tapID)
    print("cleanup aggregate=\(destroyAgg) tap=\(destroyTap)")
    print("MUTE released — call voice on M80C should return if this path was the leak.")
}

let parsed = parseArgs()
switch parsed.mode {
case "mute":
    muteTarget(uid: parsed.uid, seconds: parsed.seconds, bundles: parsed.bundles)
default:
    printProcessList(targetUID: parsed.uid)
}
