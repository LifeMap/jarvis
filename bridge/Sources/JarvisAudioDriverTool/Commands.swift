import CoreAudio
import Foundation

enum DriverTarget: String {
    case capture, inject, all

    var deviceUIDs: [(label: String, uid: String)] {
        switch self {
        case .capture: return [("Capture", JarvisCallAudio.Capture.deviceUID)]
        case .inject: return [("Inject", JarvisCallAudio.Inject.deviceUID)]
        case .all: return [("Capture", JarvisCallAudio.Capture.deviceUID), ("Inject", JarvisCallAudio.Inject.deviceUID), ("Tap", JarvisCallAudio.Tap.deviceUID)]
        }
    }
}

enum Commands {
    static func status() {
        print("=== JarvisCallAudio driver status ===")
        for (label, uid) in DriverTarget.all.deviceUIDs {
            printDeviceStatus(label: label, uid: uid, verbose: true)
        }
        print("")
        print("Route (must stay unchanged across install/activate/deactivate): \(CoreAudioHelpers.currentRoute())")
    }

    static func list() {
        for (label, uid) in DriverTarget.all.deviceUIDs {
            printDeviceStatus(label: label, uid: uid, verbose: true)
        }
    }

    /// Per §12: reports found/AudioObjectID/UID/hidden/active/format explicitly, and — critically
    /// — distinguishes "device not found at all" from "device found but a property read failed"
    /// (the CHECKPOINT 2 bug looked identical to a routing problem until this distinction made it
    /// obvious the failure was specifically on the custom Active property, not on the device
    /// resolving to a wrong/broken AudioObjectID).
    private static func printDeviceStatus(label: String, uid: String, verbose: Bool) {
        guard let deviceID = CoreAudioHelpers.deviceID(forUID: uid) else {
            print("\(label): NOT FOUND (uid=\(uid)) — driver not installed/loaded?")
            return
        }
        print("\(label): found deviceID=\(deviceID) uid=\(uid)")

        do {
            let hidden = try CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyIsHidden)
            print("  hidden: \(hidden == 1)")
        } catch {
            print("  hidden: ERROR — \(error)")
        }

        do {
            let active = try CoreAudioHelpers.getBoolProperty(deviceID, JarvisCallAudio.propertyActive)
            print("  active: \(active)")
        } catch {
            print("  active: ERROR — \(error)")
        }

        do {
            let alive = try CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceIsAlive)
            let running = try CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceIsRunning)
            print("  alive=\(alive == 1) running=\(running == 1)")
        } catch {
            print("  alive/running: ERROR — \(error)")
        }

        // Apple convention scopes CanBeDefaultDevice per direction (Input/Output), not Global —
        // querying it at Global scope is itself the error on some hosts, independent of what the
        // plugin would answer. Check both directions explicitly; this is the property backing our
        // core safety invariant (PRD §10), so it's worth reading precisely rather than papering
        // over a query-scope mismatch.
        do {
            let canDefaultOutput = try CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput)
            let canDefaultInput = try CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput)
            print("  canBeDefaultDevice: output=\(canDefaultOutput == 1) input=\(canDefaultInput == 1)")
        } catch {
            print("  canBeDefaultDevice: ERROR — \(error)")
        }

        guard verbose else { return }
        do {
            let outputStreams = try CoreAudioHelpers.getStreams(deviceID, scope: kAudioObjectPropertyScopeOutput)
            let inputStreams = try CoreAudioHelpers.getStreams(deviceID, scope: kAudioObjectPropertyScopeInput)
            for streamID in outputStreams {
                let format = try CoreAudioHelpers.getFormat(streamID)
                print("  output stream \(streamID) format: \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch")
            }
            for streamID in inputStreams {
                let format = try CoreAudioHelpers.getFormat(streamID)
                print("  input stream \(streamID) format: \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch")
            }
        } catch {
            print("  format: ERROR — \(error)")
        }
    }

    static func setActive(_ target: DriverTarget, _ active: Bool) {
        for (label, uid) in target.deviceUIDs {
            guard let deviceID = CoreAudioHelpers.deviceID(forUID: uid) else {
                print("\(label): NOT FOUND — cannot \(active ? "activate" : "deactivate")")
                continue
            }
            do {
                try CoreAudioHelpers.setBoolProperty(deviceID, JarvisCallAudio.propertyActive, active)
                print("\(label): \(active ? "activated" : "deactivated")")
            } catch {
                print("\(label): FAILED — \(error)")
            }
        }
    }

    static func clearBuffers(_ target: DriverTarget) {
        for (label, uid) in target.deviceUIDs {
            guard let deviceID = CoreAudioHelpers.deviceID(forUID: uid) else {
                print("\(label): NOT FOUND — cannot clear")
                continue
            }
            do {
                try CoreAudioHelpers.triggerProperty(deviceID, JarvisCallAudio.propertyClearBuffers)
                print("\(label): buffers cleared")
            } catch {
                print("\(label): FAILED — \(error)")
            }
        }
    }

    /// CHECKPOINT 4/5. Writes a deterministic, channel-identifiable stereo tone into the given
    /// device's Output and captures back from its Input, then analyzes what came back. Per PRD
    /// §14, "RMS moved" alone is never treated as PASS — correlation against the exact tone we
    /// generated is the real evidence.
    static func loopbackTest(label: String, uid: String, primaryHz: Double = 440, secondaryHz: Double = 880, seconds: Double = 2) {
        print("=== \(label) loopback test (expected \(Int(primaryHz))Hz ch0 / \(Int(secondaryHz))Hz ch1) ===")
        guard let deviceID = CoreAudioHelpers.deviceID(forUID: uid) else {
            print("FAIL: device not found (uid=\(uid))")
            return
        }

        let before = CoreAudioHelpers.currentRoute()
        do { try CoreAudioHelpers.setBoolProperty(deviceID, JarvisCallAudio.propertyActive, true) }
        catch { print("FAIL: could not activate device — \(error)"); return }

        let session = DeviceIOSession(deviceID: deviceID)
        do {
            try session.start(writeFrequencyHz: primaryHz, stereoSecondToneHz: secondaryHz, capture: true)
        } catch {
            print("FAIL: could not start IO — \(error)")
            return
        }

        Thread.sleep(forTimeInterval: seconds)
        session.stop()

        let after = CoreAudioHelpers.currentRoute()
        let captured = session.snapshotCapturedFrames()
        let channelCount = JarvisCallAudio.channelCount
        let totalFrames = captured.count / max(channelCount, 1)
        print("frames captured: \(totalFrames)")

        let ch0 = ToneAnalysis.analyze(captured: captured, channel: 0, channelCount: channelCount, expectedFrequencyHz: primaryHz, sampleRate: JarvisCallAudio.sampleRate)
        let ch1 = ToneAnalysis.analyze(captured: captured, channel: 1, channelCount: channelCount, expectedFrequencyHz: secondaryHz, sampleRate: JarvisCallAudio.sampleRate)
        print("channel 0: \(ch0)")
        print("channel 1: \(ch1)")

        let nonSilent = ch0.rms > 0.02 && ch1.rms > 0.02
        let correlated = abs(ch0.correlation) > 0.6 && abs(ch1.correlation) > 0.6
        let routeUnchanged = before == after
        print("non-silent: \(nonSilent)  correlated-with-expected-tone: \(correlated)  route-unchanged: \(routeUnchanged)")
        print(nonSilent && correlated && routeUnchanged ? "RESULT: PASS" : "RESULT: FAIL (see metrics above)")
    }

    /// CHECKPOINT 6. Drives Capture and Inject simultaneously with different, identifiable tones
    /// and confirms each device's Input only reflects its OWN Output — never the other device's.
    static func isolationTest(captureHz: Double = 440, injectHz: Double = 880, seconds: Double = 2) {
        print("=== Cross-device isolation test (Capture=\(Int(captureHz))Hz, Inject=\(Int(injectHz))Hz) ===")
        guard let captureID = CoreAudioHelpers.deviceID(forUID: JarvisCallAudio.Capture.deviceUID) else {
            print("FAIL: Capture device not found"); return
        }
        guard let injectID = CoreAudioHelpers.deviceID(forUID: JarvisCallAudio.Inject.deviceUID) else {
            print("FAIL: Inject device not found"); return
        }

        do {
            try CoreAudioHelpers.setBoolProperty(captureID, JarvisCallAudio.propertyActive, true)
            try CoreAudioHelpers.setBoolProperty(injectID, JarvisCallAudio.propertyActive, true)
        } catch {
            print("FAIL: could not activate devices — \(error)"); return
        }

        let captureSession = DeviceIOSession(deviceID: captureID)
        let injectSession = DeviceIOSession(deviceID: injectID)
        do {
            try captureSession.start(writeFrequencyHz: captureHz, capture: true)
            try injectSession.start(writeFrequencyHz: injectHz, capture: true)
        } catch {
            print("FAIL: could not start IO — \(error)"); return
        }

        Thread.sleep(forTimeInterval: seconds)
        captureSession.stop()
        injectSession.stop()

        let captureCaptured = captureSession.snapshotCapturedFrames()
        let injectCaptured = injectSession.snapshotCapturedFrames()
        let channelCount = JarvisCallAudio.channelCount

        let captureOwn = ToneAnalysis.analyze(captured: captureCaptured, channel: 0, channelCount: channelCount, expectedFrequencyHz: captureHz, sampleRate: JarvisCallAudio.sampleRate)
        let captureForeign = ToneAnalysis.goertzelMagnitude(ToneAnalysis.extractChannel(captureCaptured, channel: 0, channelCount: channelCount), targetHz: injectHz, sampleRate: JarvisCallAudio.sampleRate)
        let injectOwn = ToneAnalysis.analyze(captured: injectCaptured, channel: 0, channelCount: channelCount, expectedFrequencyHz: injectHz, sampleRate: JarvisCallAudio.sampleRate)
        let injectForeign = ToneAnalysis.goertzelMagnitude(ToneAnalysis.extractChannel(injectCaptured, channel: 0, channelCount: channelCount), targetHz: captureHz, sampleRate: JarvisCallAudio.sampleRate)

        print("Capture input: own-tone \(captureOwn) foreignToneMagnitude=\(captureForeign)")
        print("Inject  input: own-tone \(injectOwn) foreignToneMagnitude=\(injectForeign)")

        let captureIsolated = captureOwn.goertzelMagnitude > captureForeign * 3
        let injectIsolated = injectOwn.goertzelMagnitude > injectForeign * 3
        print("capture isolated from inject: \(captureIsolated)  inject isolated from capture: \(injectIsolated)")
        print((captureIsolated && injectIsolated) ? "RESULT: PASS" : "RESULT: FAIL — cross-device contamination detected")
    }

    /// CHECKPOINT 7. Repeated activate -> IO start/stop -> deactivate to check lifecycle
    /// stability without leaving stale devices/streams/routes behind.
    static func stress(iterations: Int = 10) {
        print("=== Lifecycle stress test (\(iterations) iterations) ===")
        let before = CoreAudioHelpers.currentRoute()
        var failures = 0

        for iteration in 1...iterations {
            guard let captureID = CoreAudioHelpers.deviceID(forUID: JarvisCallAudio.Capture.deviceUID),
                  let injectID = CoreAudioHelpers.deviceID(forUID: JarvisCallAudio.Inject.deviceUID) else {
                print("iteration \(iteration): FAIL — device(s) not resolvable")
                failures += 1
                continue
            }

            do {
                try CoreAudioHelpers.setBoolProperty(captureID, JarvisCallAudio.propertyActive, true)
                try CoreAudioHelpers.setBoolProperty(injectID, JarvisCallAudio.propertyActive, true)

                let captureSession = DeviceIOSession(deviceID: captureID)
                let injectSession = DeviceIOSession(deviceID: injectID)
                try captureSession.start(writeFrequencyHz: 440, capture: true)
                try injectSession.start(writeFrequencyHz: 880, capture: true)
                Thread.sleep(forTimeInterval: 0.2)
                captureSession.stop()
                injectSession.stop()

                try CoreAudioHelpers.setBoolProperty(captureID, JarvisCallAudio.propertyActive, false)
                try CoreAudioHelpers.setBoolProperty(injectID, JarvisCallAudio.propertyActive, false)

                print("iteration \(iteration): PASS")
            } catch {
                print("iteration \(iteration): FAIL — \(error)")
                failures += 1
            }
        }

        let after = CoreAudioHelpers.currentRoute()
        print("")
        print("route before: \(before)")
        print("route after:  \(after)")
        print("route unchanged: \(before == after)")
        print(failures == 0 && before == after ? "RESULT: PASS" : "RESULT: FAIL (\(failures) iteration failures)")
    }

    /// Phase 3 CHECKPOINT 1 route-setter investigation (§16/§24) — READ-ONLY. Enumerates every
    /// AudioDeviceID currently registered with the HAL and prints the properties relevant to
    /// whether AudioObjectSetPropertyData(kAudioHardwarePropertyDefault{Output,Input}Device) will
    /// actually take effect against it, plus the currently-active default route identities. Never
    /// calls AudioObjectSetPropertyData, never activates/deactivates a device, never places a
    /// call — safe to run against the real Mac at any time, including with a live call in
    /// progress.
    private static func printDeviceProperties(_ deviceID: AudioDeviceID, label: String) {
        print("--- \(label) (deviceID=\(deviceID)) ---")
        print("  uid: \(CoreAudioHelpers.getUID(deviceID) ?? "(unknown)")")
        print("  name: \(CoreAudioHelpers.getName(deviceID) ?? "(unknown)")")
        print("  manufacturer: \(CoreAudioHelpers.getManufacturer(deviceID) ?? "(unknown)")")

        if let alive = try? CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceIsAlive) {
            print("  alive: \(alive == 1)")
        }
        if let running = try? CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceIsRunning) {
            print("  running: \(running == 1)")
        }
        if let hidden = try? CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyIsHidden) {
            print("  hidden: \(hidden == 1)")
        }
        if let transport = try? CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyTransportType) {
            print("  transportType: \(transport)")
        }
        // §3 of the investigation: this is the property this whole investigation is about —
        // printed at both scopes since Apple's own convention scopes it per-direction.
        if let canDefaultOut = try? CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput) {
            print("  canBeDefaultDevice(output): \(canDefaultOut == 1)")
        }
        if let canDefaultIn = try? CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput) {
            print("  canBeDefaultDevice(input): \(canDefaultIn == 1)")
        }
        if let canDefaultSys = try? CoreAudioHelpers.getUInt32(deviceID, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: kAudioObjectPropertyScopeOutput) {
            print("  canBeDefaultSystemDevice(output): \(canDefaultSys == 1)")
        }
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nominalRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &nominalRate) == noErr {
            print("  nominalSampleRate: \(nominalRate)")
        }
        let outputChannels = CoreAudioHelpers.totalChannels(deviceID, scope: kAudioObjectPropertyScopeOutput)
        let inputChannels = CoreAudioHelpers.totalChannels(deviceID, scope: kAudioObjectPropertyScopeInput)
        print("  channels: output=\(outputChannels) input=\(inputChannels)")
        let outputStreamCount = (try? CoreAudioHelpers.getStreams(deviceID, scope: kAudioObjectPropertyScopeOutput).count) ?? 0
        let inputStreamCount = (try? CoreAudioHelpers.getStreams(deviceID, scope: kAudioObjectPropertyScopeInput).count) ?? 0
        print("  streams: output=\(outputStreamCount) input=\(inputStreamCount)")
        print("")
    }

    static func inspect() {
        print("=== JarvisAudioDriverTool inspect (READ-ONLY — no mutation) ===\n")

        // Resolved directly via TranslateUIDToDevice (same as `status`), NOT only from the
        // kAudioHardwarePropertyDevices enumeration below — a hidden device (both Jarvis devices
        // are hidden whenever Work Mode isn't actively routing a call) may not appear in that
        // general list even though it's still fully resolvable and queryable by UID.
        if let captureID = CoreAudioHelpers.deviceID(forUID: JarvisCallAudio.Capture.deviceUID) {
            printDeviceProperties(captureID, label: "Jarvis Call Capture")
        } else {
            print("--- Jarvis Call Capture --- NOT FOUND (driver not installed/loaded?)\n")
        }
        if let injectID = CoreAudioHelpers.deviceID(forUID: JarvisCallAudio.Inject.deviceUID) {
            printDeviceProperties(injectID, label: "Jarvis Call Inject")
        } else {
            print("--- Jarvis Call Inject --- NOT FOUND (driver not installed/loaded?)\n")
        }

        let allIDs = CoreAudioHelpers.allDeviceIDs()
        print("kAudioHardwarePropertyDevices enumeration reports \(allIDs.count) device(s) — this")
        print("list can legitimately EXCLUDE hidden devices (both Jarvis devices are hidden at")
        print("Idle), which is why they're resolved explicitly above rather than only via this")
        print("enumeration. Any AITakeCall device below is a READ-ONLY reference comparison only —")
        print("nothing here modifies it.\n")

        for deviceID in allIDs {
            let uid = CoreAudioHelpers.getUID(deviceID) ?? ""
            guard uid.hasPrefix(JarvisCallAudio.bundleID) == false else { continue } // already printed above
            let isAITakeCall = uid.lowercased().contains("aitakecall") || (CoreAudioHelpers.getName(deviceID)?.lowercased().contains("aitakecall") ?? false)
            guard isAITakeCall else { continue }
            printDeviceProperties(deviceID, label: "AITakeCall device — reference comparison")
        }

        print("--- Current default route identities ---")
        func printDefault(_ label: String, _ selector: AudioObjectPropertySelector) {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
                print("  \(label): ERROR reading default device ID")
                return
            }
            let uid = CoreAudioHelpers.getUID(deviceID) ?? "(unknown)"
            let name = CoreAudioHelpers.getName(deviceID) ?? "(unknown)"
            print("  \(label): deviceID=\(deviceID) uid=\(uid) name=\(name)")
        }
        printDefault("Default Output", kAudioHardwarePropertyDefaultOutputDevice)
        printDefault("Default Input", kAudioHardwarePropertyDefaultInputDevice)
        printDefault("Default System Output", kAudioHardwarePropertyDefaultSystemOutputDevice)

        print("\nThis command never calls AudioObjectSetPropertyData and never activates/deactivates")
        print("a device — it only reads. No route was mutated by running this.")
    }

    /// Phase 3 CHECKPOINT 2 RX investigation (§15) — READ-ONLY. Prints the per-device PCM stage
    /// diagnostics (client Output write, driver loopback, driver Input read for Capture; the
    /// mirrored Inject fields for future TX debugging per §27) plus current Input/Output/System
    /// Output identity. Intended to be run WHILE a real call is Active + Routed + PCM Running, so
    /// the counters reflect a live call rather than an idle driver. Never calls
    /// AudioObjectSetPropertyData, never activates/deactivates a device, never starts an IOProc,
    /// never writes PCM — reads three existing properties only (PCMDiagnostics, Active, and the
    /// current default route), exactly like `inspect` above.
    static func pcmInspect() {
        print("=== JarvisAudioDriverTool pcm-inspect (READ-ONLY — no mutation, no route/PCM changes) ===\n")
        print("Run this WHILE a real call is Active + Routed + PCM Running for it to mean anything —")
        print("against an idle driver every counter below will legitimately read zero.\n")

        print("--- Route identity (before) ---")
        printRouteIdentity()
        print("")

        printPCM(label: "Jarvis Call Capture", uid: JarvisCallAudio.Capture.deviceUID)
        printPCM(label: "Jarvis Call Inject", uid: JarvisCallAudio.Inject.deviceUID)
        printPCM(label: "Jarvis Call Tap", uid: JarvisCallAudio.Tap.deviceUID)

        print("--- Route identity (after) ---")
        printRouteIdentity()

        print("\nInterpretation guide (Capture/RX):")
        print("  OUTPUT operationCount=0, or frames>0 but nonZeroCallbacks=0 despite real caller speech")
        print("    -> Phone.app is probably not sending caller audio to Jarvis Call Capture at all;")
        print("       investigate call audio route selection/takeover timing, not the driver.")
        print("  OUTPUT nonZeroCallbacks>0 but LOOPBACK writeFrames/readFrames stay far behind it")
        print("    -> HAL loopback implementation defect.")
        print("  LOOPBACK readFrames>0 (i.e. driver Input side has data) but INPUT nonZeroCallbacks=0")
        print("    -> Bridge's own JarvisPCMCaptureIOProc buffer-interpretation defect.")
        print("  All non-zero -> compare against Bridge's own [CALL-PCM] RX metrics log line; if")
        print("    those also show non-zero, RX PCM is working end-to-end.")
        print("\nThis command never calls AudioObjectSetPropertyData, never activates/deactivates a")
        print("device, never starts an IOProc, and never writes PCM — it only reads.")
    }

    /// §19/§33/§34 investigation — richer than `CoreAudioHelpers.currentRoute()` (which other
    /// commands use purely for before/after equality comparison and legitimately collapses any
    /// failure into the string "Unknown"): this always shows the numeric default AudioObjectID
    /// plus explicit per-field read status, so "Input=Unknown" can never again hide *which*
    /// step failed (bad default-device read vs. UID read vs. name read) or whether the ID even
    /// resolved to something hidden-device enumeration would have missed.
    private static func printRouteIdentity() {
        func describe(_ label: String, _ selector: AudioObjectPropertySelector) {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
            guard status == noErr else {
                print("  \(label): ERROR reading default device ID osStatus=\(status)")
                return
            }
            let uid = CoreAudioHelpers.getUID(deviceID)
            let name = CoreAudioHelpers.getName(deviceID)
            print("  \(label): defaultDeviceID=\(deviceID) uidReadStatus=\(uid != nil ? "ok" : "failed") uid=\(uid ?? "(unavailable)") nameReadStatus=\(name != nil ? "ok" : "failed") name=\(name ?? "(unavailable)")")
        }
        describe("Default Input", kAudioHardwarePropertyDefaultInputDevice)
        describe("Default Output", kAudioHardwarePropertyDefaultOutputDevice)
        describe("Default System Output", kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    /// §17/§18 investigation — resolves the UID fresh immediately before EACH logically separate
    /// property read (never reuses one cached `AudioDeviceID` across them), and explicitly logs
    /// `AUDIO_OBJECT_ID_CHANGED` if two consecutive resolves of the SAME UID within this single
    /// invocation ever disagree — proving or disproving ID churn happening *inside* one
    /// `pcm-inspect` run, as opposed to across separate process invocations (where AudioObjectID
    /// comparison was never meaningful in the first place — see the Phase 3 report). A resolve
    /// failure is never silently treated as "the device is gone"; every step prints an explicit
    /// result.
    private static func printPCM(label: String, uid: String) {
        guard let preID = CoreAudioHelpers.deviceID(forUID: uid) else {
            print("--- \(label) --- NOT FOUND (driver not installed/loaded?)\n")
            return
        }
        let preReadBackUID = CoreAudioHelpers.getUID(preID)
        print("--- \(label) ---")
        print("  PRE:  requestedUID=\(uid) resolvedID=\(preID) readBackUID=\(preReadBackUID ?? "(unavailable)")")

        guard let activeID = CoreAudioHelpers.deviceID(forUID: uid) else {
            print("  active: NOT FOUND — device no longer resolves (was resolvedID=\(preID) moments ago)")
            print("")
            return
        }
        if activeID != preID {
            print("  AUDIO_OBJECT_ID_CHANGED: resolvedID changed \(preID) -> \(activeID) between PRE and the active-property read")
        }
        do {
            let active = try CoreAudioHelpers.getBoolProperty(activeID, JarvisCallAudio.propertyActive)
            print("  active: \(active)")
        } catch {
            print("  active: ERROR — \(error)")
        }

        guard let pcmID = CoreAudioHelpers.deviceID(forUID: uid) else {
            print("  PCM diagnostics: NOT FOUND — device no longer resolves (was resolvedID=\(activeID) moments ago)")
            print("")
            return
        }
        if pcmID != activeID {
            print("  AUDIO_OBJECT_ID_CHANGED: resolvedID changed \(activeID) -> \(pcmID) between the active-property read and the PCM diagnostics read")
        }
        do {
            let d = try CoreAudioHelpers.getPCMDiagnostics(pcmID)
            // §20 correction — a real-device run showed ioClientCount=1 simultaneously with
            // thousands of non-zero Capture OUTPUT callbacks, proving Phone.app can deliver real
            // PCM to this device without this counter ever exceeding 1. It is auxiliary
            // host/client-start telemetry only, NOT authoritative process attribution — the
            // direct signal evidence for "is real PCM arriving" is outputNonZeroCallbacks/
            // outputPeakLinear (and the mirrored input* fields) below, never this count alone.
            print("  ioClientCount: \(d.ioClientCount)  (auxiliary AudioDeviceStart-client telemetry only — NOT proof of whether another process is sending PCM; use outputNonZeroCallbacks/outputPeakLinear below for that)")
            print("  OUTPUT stage (a client writing to this device's Output — e.g. Phone.app if it renders call audio here):")
            print("    operationCount=\(d.outputOperationCount) frames=\(d.outputFrames) nonZeroCallbacks=\(d.outputNonZeroCallbacks) peakLinear=\(d.outputPeakLinear)")
            print("  LOOPBACK stage (this device's internal Output->Input ring):")
            print("    writeFrames=\(d.loopbackWriteFrames) readFrames=\(d.loopbackReadFrames) underrunCount=\(d.loopbackUnderrunCount) overrunFrameCount=\(d.loopbackOverrunFrameCount)")
            print("  INPUT stage (what a driver client — Bridge's own C IOProc — actually receives as this device's Input):")
            print("    operationCount=\(d.inputOperationCount) frames=\(d.inputFrames) nonZeroCallbacks=\(d.inputNonZeroCallbacks) peakLinear=\(d.inputPeakLinear)")
        } catch {
            print("  PCM diagnostics: ERROR — \(error)")
        }

        let postReadBackUID = CoreAudioHelpers.getUID(pcmID)
        print("  POST: resolvedID=\(pcmID) readBackUID=\(postReadBackUID ?? "(unavailable)")")
        print("")
    }

    /// §21/§24/§44 investigation — safe, read-only stability harness. Run this WHILE Jarvis
    /// devices are idle/inactive (never during a call) to prove or disprove UID/AudioObjectID/
    /// Rpcm-read instability independent of any real call — reproducing the bug here first is
    /// strictly preferred over debugging it against a live cellular call. Never calls
    /// AudioObjectSetPropertyData, AudioDeviceStart/Stop, or AudioDeviceCreateIOProcID/
    /// DestroyIOProcID — resolves + reads only, `iterations` times.
    static func pcmInspectStability(iterations: Int = 50) {
        print("=== JarvisAudioDriverTool pcm-inspect-stability (READ-ONLY — \(iterations) iterations) ===")
        print("Run this WHILE Jarvis devices are idle/inactive — it never activates or routes anything itself.\n")

        var idChanges = 0
        var uidMismatches = 0
        var rpcmFailures = 0
        var lastCaptureID: AudioDeviceID?
        var lastInjectID: AudioDeviceID?

        func checkOnce(uid: String, label: String, lastID: inout AudioDeviceID?) {
            guard let resolvedID = CoreAudioHelpers.deviceID(forUID: uid) else {
                print("  [\(label)] NOT FOUND (driver not installed/loaded?)")
                return
            }
            if let lastID, lastID != resolvedID {
                idChanges += 1
                print("  [\(label)] AUDIO_OBJECT_ID_CHANGED: \(lastID) -> \(resolvedID)")
            }
            lastID = resolvedID

            let readBackUID = CoreAudioHelpers.getUID(resolvedID)
            if readBackUID != uid {
                uidMismatches += 1
                print("  [\(label)] UID_READBACK_MISMATCH: requested=\(uid) readBack=\(readBackUID ?? "(unavailable)")")
            }

            // §14 investigation — staged so a failure shows exactly WHICH CoreAudio call broke,
            // not just "the read failed". Success is intentionally silent (this command runs up
            // to hundreds of times; spamming every passing row would bury the failures).
            let staged = CoreAudioHelpers.readPCMDiagnosticsStaged(resolvedID)
            if !staged.succeeded {
                rpcmFailures += 1
                print("  [\(label)] id=\(resolvedID) hasBefore=\(staged.hasPropertyBefore) sizeStatus=\(CoreAudioHelpers.formatOSStatus(staged.sizeStatus)) size=\(staged.returnedSize) dataStatus=\(CoreAudioHelpers.formatOSStatus(staged.dataStatus)) hasAfter=\(staged.hasPropertyAfter)")
            }
        }

        let routeBefore = CoreAudioHelpers.currentRoute()
        for i in 1...iterations {
            checkOnce(uid: JarvisCallAudio.Capture.deviceUID, label: "capture#\(i)", lastID: &lastCaptureID)
            checkOnce(uid: JarvisCallAudio.Inject.deviceUID, label: "inject#\(i)", lastID: &lastInjectID)
        }
        let routeAfter = CoreAudioHelpers.currentRoute()

        print("")
        print("iterations=\(iterations) idChanges=\(idChanges) uidReadbackMismatches=\(uidMismatches) rpcmFailures=\(rpcmFailures)")
        print("route before: \(routeBefore)")
        print("route after:  \(routeAfter)")
        let routeUnchanged = routeBefore == routeAfter
        print("route unchanged: \(routeUnchanged)")
        let pass = idChanges == 0 && uidMismatches == 0 && rpcmFailures == 0 && routeUnchanged
        print(pass ? "RESULT: PASS" : "RESULT: FAIL (see counts above)")
        print("\nThis command never calls AudioObjectSetPropertyData, AudioDeviceStart/Stop, or")
        print("AudioDeviceCreateIOProcID/DestroyIOProcID — it only resolves and reads.")
    }
}
