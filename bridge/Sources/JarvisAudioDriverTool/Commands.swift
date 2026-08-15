import CoreAudio
import Foundation

enum DriverTarget: String {
    case capture, inject, all

    var deviceUIDs: [(label: String, uid: String)] {
        switch self {
        case .capture: return [("Capture", JarvisCallAudio.Capture.deviceUID)]
        case .inject: return [("Inject", JarvisCallAudio.Inject.deviceUID)]
        case .all: return [("Capture", JarvisCallAudio.Capture.deviceUID), ("Inject", JarvisCallAudio.Inject.deviceUID)]
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
}
