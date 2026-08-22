import AudioToolbox
import CoreAudio
import Foundation
import JarvisPCMRealtime

/// Real implementation of `CallAudioPCMControlling` — the only file that ever calls
/// `AudioDeviceCreateIOProcID`/`AudioDeviceStart` for Capture/Inject.
///
/// Phase 3 CHECKPOINT 2 — C Native real-time callbacks. Capture RX taps the WriteMix shared
/// ring (`JarvisCaptureRXRing`) from `JarvisPCMCaptureAUInputCallback` (AUHAL is only a clock;
/// HAL ReadInput for an extra client is silence). Inject TX stays on `JarvisPCMInjectIOProc`.
/// Neither callback calls back into Swift. This class is the non-real-time control-plane
/// orchestrator.
@MainActor
final class SystemCallAudioPCMController: CallAudioPCMControlling, ObservableObject {
    @Published private(set) var state: CallAudioPCMState = .idle
    @Published private(set) var metrics: CallAudioPCMMetrics = .zero
    @Published private(set) var testToneState: CallAudioTestToneState = .idle
    @Published private(set) var format: CallAudioPCMFormat?

    private let logger: BridgeLogger

    /// The C runtime's opaque context (§10/§11 — Swift never sees its internal atomic fields,
    /// only the pointer). Allocated in `start()`, strictly before either IOProc is registered;
    /// freed in `stop()`, strictly after both IOProcs have been stopped and destroyed — see the
    /// lifetime contract documented in `JarvisPCMRealtime.h`.
    private var runtime: OpaquePointer?

    private var captureDeviceID: AudioDeviceID?
    private var captureAudioUnit: AudioUnit?
    private var injectDeviceID: AudioDeviceID?
    private var injectProcID: AudioDeviceIOProcID?
    private var metricsTimer: Timer?
    /// Phase 3 CHECKPOINT 2 RX-metrics investigation (§16) — throttles the new
    /// `[CALL-PCM-METRICS]` diagnostic line to ~1 Hz even though the metrics timer itself ticks
    /// at 5 Hz; reset to `nil` on every `start()` so a new call never logs using a stale
    /// previous-call timestamp.
    private var lastMetricsLogAt: Date?
    /// When the shm ring is leftover from a previous process, writeIndex never moves.
    /// After this deadline we drop it and ingest Capture `Rrxc` instead.
    private var pcmRunningAt: Date?
    private var didAbandonStaleCaptureRXRing = false
    /// Control-plane poll of Capture `Rrxc` when POSIX shm cannot be opened.
    private var fallbackRXTimer: Timer?
    private var fallbackCaptureDeviceID: AudioDeviceID?
    private let toneProducer = CallAudioToneRingProducer()

    /// §19 — one fixed diagnostic tone: 1 kHz, 1.0s (48,000 frames at the native 48 kHz rate),
    /// same signal on every channel, amplitude 0.1 ≈ -20 dBFS, deterministic phase starting at 0
    /// every time. Generation lives on this control-plane producer; Inject IOProc only reads the TX ring.
    private static let toneDurationSeconds: Double = 1.0

    init(logger: BridgeLogger) {
        self.logger = logger
        logger.log("[CALL-PCM] realtime backend=native-c-writemix-ring-rx+tx-ring")
    }

    @discardableResult
    func start(reason: String) async -> Bool {
        guard state == .idle else {
            logger.log("[CALL-PCM] start ignored — already state=\(state.rawValue)")
            return state == .running
        }
        state = .starting
        metrics = .zero
        testToneState = .idle
        format = nil
        lastMetricsLogAt = nil
        pcmRunningAt = nil
        didAbandonStaleCaptureRXRing = false
        logger.log("[CALL-PCM] prepare reason=\(reason)")

        // §14 — verified once, before any IOProc is registered, never discovered from inside a
        // callback. On every real Apple Silicon/Intel Mac target this project supports, these
        // atomic types are always lock-free (also asserted at compile time in the C runtime);
        // this is the documented non-RT fallback for anything that compile-time check can't
        // prove.
        guard JarvisPCMRuntimeAtomicsAreLockFree() else {
            logger.log("[CALL-PCM] atomics not lock-free on this platform — refusing to start")
            state = .failed
            return false
        }

        guard let runtime = JarvisPCMRuntimeCreate() else {
            logger.log("[CALL-PCM] runtime allocation failed")
            state = .failed
            return false
        }
        self.runtime = runtime
        if JarvisPCMRuntimeOpenCaptureRXRing(runtime) {
            logger.log("[CALL-PCM] capture-rx ring opened writeIndex=\(JarvisPCMRuntimeCaptureRXRingWriteIndex(runtime))")
        } else {
            logger.log("[CALL-PCM] capture-rx ring unavailable — using Rrxc property fallback")
        }

        // §10 — resolved fresh every time, never cached/persisted, with a UID round-trip check —
        // exactly mirroring `SystemCallAudioRouteController.setDefault`'s existing pattern.
        guard let tapID = Self.resolvedDeviceID(forUID: JarvisAudioDeviceUIDs.tap, role: "tap", logger: logger) else {
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .idle
            return false
        }
        logger.log("[CALL-PCM] tap device resolved deviceID=\(tapID)")

        guard let injectID = Self.resolvedDeviceID(forUID: JarvisAudioDeviceUIDs.inject, role: "inject", logger: logger) else {
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .idle
            return false
        }
        logger.log("[CALL-PCM] inject device resolved deviceID=\(injectID)")

        // §48 — format validation stays in the Swift control plane, never moved into the
        // real-time callback; validated against the actual driver ASBD, never assumed.
        guard let tapFormat = Self.nativeFormat(deviceID: tapID, scope: kAudioObjectPropertyScopeInput) else {
            logger.log("[CALL-PCM] tap format query failed")
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .failed
            return false
        }
        guard tapFormat == .expected else {
            logger.log("[CALL-PCM] tap format validation failed expected=\(CallAudioPCMFormat.expected) actual=\(tapFormat)")
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .failed
            return false
        }
        logger.log("[CALL-PCM] tap format \(tapFormat)")

        guard let injectFormat = Self.nativeFormat(deviceID: injectID, scope: kAudioObjectPropertyScopeOutput) else {
            logger.log("[CALL-PCM] inject format query failed")
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .failed
            return false
        }
        guard injectFormat == .expected else {
            logger.log("[CALL-PCM] inject format validation failed expected=\(CallAudioPCMFormat.expected) actual=\(injectFormat)")
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .failed
            return false
        }
        logger.log("[CALL-PCM] inject format \(injectFormat)")
        format = tapFormat

        let clientData = UnsafeMutableRawPointer(runtime)

        // RX opens the hidden Tap device, not Capture. Same-call evidence: any extra input
        // client on Capture (IOProc or AUHAL) got 512-frame silence while Capture ReadInput
        // ran at 960 frames with real PCM. Tap has its own HAL IO cycle and reads Capture's ring.
        guard startCaptureAUHAL(deviceID: tapID, runtime: runtime) else {
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .failed
            return false
        }

        var newInjectProcID: AudioDeviceIOProcID?
        let injectCreateStatus = AudioDeviceCreateIOProcID(injectID, JarvisPCMInjectIOProc, clientData, &newInjectProcID)
        guard injectCreateStatus == noErr, let newInjectProcID else {
            logger.log("[CALL-PCM] inject io creation failed osStatus=\(injectCreateStatus)")
            // §26/§51 — unwind only what was actually started: Capture AUHAL already started.
            Self.disposeAudioUnit(captureAudioUnit)
            captureAudioUnit = nil
            captureDeviceID = nil
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .failed
            return false
        }
        logger.log("[CALL-PCM] inject io created")

        // Inject IOProc is TX-only. Disable its unused input so a full-duplex in-place buffer
        // cannot alias Inject's output the way Capture's did for RX.
        IOProcStreamUsageReader.configureAndLog(role: "inject", deviceID: injectID, procID: newInjectProcID, inputUsed: false, outputUsed: true, logger: logger)

        let injectStartStatus = AudioDeviceStart(injectID, newInjectProcID)
        guard injectStartStatus == noErr else {
            logger.log("[CALL-PCM] inject start failed osStatus=\(injectStartStatus)")
            AudioDeviceDestroyIOProcID(injectID, newInjectProcID)
            Self.disposeAudioUnit(captureAudioUnit)
            captureAudioUnit = nil
            captureDeviceID = nil
            JarvisPCMRuntimeDestroy(runtime)
            self.runtime = nil
            state = .failed
            return false
        }
        injectDeviceID = injectID
        injectProcID = newInjectProcID
        logger.log("[CALL-PCM] inject started")

        startMetricsTimer()
        pcmRunningAt = Date()
        if !JarvisPCMRuntimeCaptureRXRingIsMapped(runtime) {
            fallbackCaptureDeviceID = Self.resolvedDeviceID(forUID: JarvisAudioDeviceUIDs.capture, role: "capture-rx-fallback", logger: logger)
            startFallbackRXTimer()
        }
        state = .running
        logger.log("[CALL-PCM] state=running")
        return true
    }

    func stop(reason: String) async {
        guard state != .idle else { return } // idempotent (§22)
        state = .stopping
        logger.log("[CALL-PCM] stop started reason=\(reason)")

        stopMetricsTimer() // prevents any further test-tone-state observation/logging before teardown.
        stopTonePump()
        stopFallbackRXTimer()
        fallbackCaptureDeviceID = nil
        pcmRunningAt = nil
        didAbandonStaleCaptureRXRing = false

        // §14/§22/§24/§25 — Inject (TX, the side Phone.app is actively reading from) stops
        // before Capture; each is fully stopped (`AudioDeviceStop` returns — CoreAudio
        // guarantees no further callback invocation after this) and its IOProc ID destroyed
        // before this function returns. Only THEN is the C runtime context freed — the context
        // must never be freed while either callback could still be executing or about to be
        // invoked again.
        if let injectDeviceID, let injectProcID {
            Self.stopAndDestroy(deviceID: injectDeviceID, procID: injectProcID)
        }
        injectDeviceID = nil
        injectProcID = nil
        logger.log("[CALL-PCM] inject stopped")

        if let captureAudioUnit {
            Self.disposeAudioUnit(captureAudioUnit)
        }
        captureAudioUnit = nil
        captureDeviceID = nil
        logger.log("[CALL-PCM] capture stopped")

        if let runtime {
            JarvisPCMRuntimeDestroy(runtime)
        }
        runtime = nil
        logger.log("[CALL-PCM] io disposed")

        testToneState = .idle
        format = nil
        metrics = .zero
        state = .idle
        logger.log("[CALL-PCM] state=idle")
    }

    func sendTestTone() {
        guard state == .running, let runtime else {
            logger.log("[CALL-PCM] test-tone ignored reason=pcm-not-running")
            return
        }
        // §21 — the atomic compare-exchange (inside the C runtime) is the single source of truth
        // for accept/reject, never the `@Published testToneState` mirror, which the 5Hz timer
        // may not have caught up on yet.
        let frameCount = Int32(Self.toneDurationSeconds * CallAudioPCMFormat.expected.sampleRate)
        guard JarvisPCMRuntimeRequestTone(runtime, frameCount) else {
            var snapshot = JarvisPCMMetricsSnapshot()
            JarvisPCMRuntimeReadMetrics(runtime, &snapshot)
            logger.log("[CALL-PCM] test-tone ignored reason=already-\(Self.toneStateDescription(snapshot.toneState))")
            return
        }
        testToneState = .queued
        logger.log("[CALL-PCM] test-tone queued")
        var samples = [Float](repeating: 0, count: Int(frameCount) * 2)
        let sampleRate = CallAudioPCMFormat.expected.sampleRate
        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(2 * Double.pi * 1000.0 * Double(frame) / sampleRate)) * 0.1
            samples[frame * 2] = sample
            samples[frame * 2 + 1] = sample
        }
        toneProducer.start(runtime: runtime, interleavedStereo: samples)
    }

    private func stopTonePump() {
        toneProducer.stop()
    }

    // MARK: - Low-frequency UI metrics (§32/§34 — never per-callback; ~5Hz, only while running)

    private func startMetricsTimer() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            // `OpaquePointer` isn't `Sendable`, so `runtime` is deliberately re-read from
            // `self.runtime` inside the hop rather than captured here — this closure only ever
            // carries a plain `weak self` across the boundary.
            Task { @MainActor in self?.publishMetrics() }
        }
        RunLoop.main.add(timer, forMode: .common)
        metricsTimer = timer
    }

    private func stopMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    private func abandonStaleCaptureRXRingIfNeeded(runtime: OpaquePointer) {
        guard !didAbandonStaleCaptureRXRing else { return }
        guard JarvisPCMRuntimeCaptureRXRingIsMapped(runtime) else { return }
        guard !JarvisPCMRuntimeCaptureRXRingProducerHasAdvanced(runtime) else { return }
        guard let pcmRunningAt, Date().timeIntervalSince(pcmRunningAt) >= 0.3 else { return }
        didAbandonStaleCaptureRXRing = true
        let frozenIndex = JarvisPCMRuntimeCaptureRXRingWriteIndex(runtime)
        JarvisPCMRuntimeCloseCaptureRXRing(runtime)
        fallbackCaptureDeviceID = Self.resolvedDeviceID(forUID: JarvisAudioDeviceUIDs.capture, role: "capture-rx-fallback", logger: logger)
        startFallbackRXTimer()
        logger.log("[CALL-PCM] capture-rx ring stale writeIndex=\(frozenIndex) — falling back to Rrxc")
    }

    private func startFallbackRXTimer() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ingestFallbackRXChunk() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackRXTimer = timer
        logger.log("[CALL-PCM] capture-rx fallback poller started")
    }

    private func stopFallbackRXTimer() {
        fallbackRXTimer?.invalidate()
        fallbackRXTimer = nil
    }

    private func ingestFallbackRXChunk() {
        guard let runtime, let deviceID = fallbackCaptureDeviceID else { return }
        guard let samples = Self.readCaptureRXChunk(deviceID: deviceID), samples.count >= 2 else { return }
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            JarvisPCMRuntimePublishRXFrames(runtime, base, UInt32(samples.count / 2))
        }
    }

    /// Capture `Rrxc` — last WriteMix chunk as CFData. Same +1 CF ownership as Rpcm.
    private static func readCaptureRXChunk(deviceID: AudioDeviceID) -> [Float]? {
        var address = AudioObjectPropertyAddress(
            mSelector: 0x52727863, /* 'Rrxc' */
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
        var value: Unmanaged<CFData>?
        var dataSize = size
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr, let value else { return nil }
        let data = value.takeRetainedValue() as Data
        guard data.count >= 16 else { return nil }
        let version: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let frameCount: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let channelCount: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        guard version == 1, frameCount > 0, channelCount == 2 else { return nil }
        let floatCount = Int(frameCount) * 2
        let headerSize = 16
        let needed = headerSize + floatCount * MemoryLayout<Float>.size
        guard data.count >= needed else { return nil }
        return data.subdata(in: headerSize..<needed).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// §16 — dB conversion happens here, off the real-time thread: the C runtime publishes only
    /// linear `rxMeanSquareLinear`/`rxPeakLinear`.
    private func publishMetrics() {
        guard let runtime else { return }
        abandonStaleCaptureRXRingIfNeeded(runtime: runtime)
        var snapshot = JarvisPCMMetricsSnapshot()
        JarvisPCMRuntimeReadMetrics(runtime, &snapshot)

        let rmsLinear = sqrt(Double(snapshot.rxMeanSquareLinear))
        let rmsDBFS = Self.dBFS(Float(rmsLinear))
        metrics = CallAudioPCMMetrics(
            rxFrames: snapshot.rxFrames, rxCallbacks: snapshot.rxCallbacks,
            rxRMSDBFS: rmsDBFS, rxPeakDBFS: Self.dBFS(snapshot.rxPeakLinear),
            rxActive: rmsDBFS > CallAudioPCMMetrics.activityThresholdDBFS,
            txFrames: snapshot.txFrames, txCallbacks: snapshot.txCallbacks, txUnderrunCount: snapshot.txUnderrunCount
        )

        let newToneState = Self.toneState(fromRaw: snapshot.toneState)
        if newToneState != testToneState {
            if newToneState == .playing {
                logger.log("[CALL-PCM] test-tone started")
            } else if newToneState == .idle, testToneState == .playing {
                logger.log("[CALL-PCM] test-tone completed")
            }
            testToneState = newToneState
        }

        // Phase 3 CHECKPOINT 2 RX-metrics investigation (§16/§39/§49) — non-real-time only
        // (this whole function already only ever runs off the 5Hz UI timer, never from a
        // callback), aggregate values only (no raw PCM, no transcript, no caller identity),
        // throttled to ~1/sec so a multi-minute call doesn't flood the log.
        let now = Date()
        if lastMetricsLogAt == nil || now.timeIntervalSince(lastMetricsLogAt!) >= 1.0 {
            lastMetricsLogAt = now
            // §12 — input-shape fields distinguish "no input ABL" / "ABL but zero buffers" /
            // "buffers but mData NULL" / "readable buffers" from each other, so a real-device log
            // alone can localize the RX failure without needing a same-call CoreAudio debugger
            // attach.
            logger.log("[CALL-PCM-METRICS] rxFrames=\(snapshot.rxFrames) rxCallbacks=\(snapshot.rxCallbacks) rawMeanSquareLinear=\(snapshot.rxMeanSquareLinear) rawPeakLinear=\(snapshot.rxPeakLinear) rmsDbFS=\(metrics.rxRMSDBFS) peakDbFS=\(metrics.rxPeakDBFS) activity=\(metrics.rxActive ? "active" : "silence") txUnderrunCount=\(snapshot.txUnderrunCount) ioProcInvocations=\(snapshot.rxIOProcInvocations) inputListNullCallbacks=\(snapshot.rxNullInputListCallbacks) inputZeroBufferCountCallbacks=\(snapshot.rxZeroBufferCountCallbacks) inputBufferCountLast=\(snapshot.rxInputBufferCountLast) inputNullDataBufferCount=\(snapshot.rxNullDataBufferCount) readableDataBufferCount=\(snapshot.rxReadableDataBufferCount) readableNonZeroBufferCount=\(snapshot.rxReadableNonZeroBufferCount)")
        }
    }

    private static func toneState(fromRaw raw: Int32) -> CallAudioTestToneState {
        switch raw {
        case 1: return .queued
        case 2: return .playing
        default: return .idle
        }
    }

    private static func toneStateDescription(_ raw: Int32) -> String {
        toneState(fromRaw: raw).rawValue.lowercased()
    }

    // MARK: - CoreAudio plumbing (mirrors SystemCallAudioRouteController's proven patterns)

    private static func resolvedDeviceID(forUID uid: String, role: String, logger: BridgeLogger) -> AudioDeviceID? {
        guard let deviceID = SystemCallAudioRouteController.deviceID(forUID: uid) else {
            logger.log("[CALL-PCM] \(role) device resolution failed uid=\(uid)")
            return nil
        }
        return deviceID
    }

    private static func streams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ids)
        guard status == noErr else { return [] }
        return ids
    }

    /// §48 — queries the actual driver-advertised ASBD on the relevant stream (Capture's INPUT
    /// stream for RX, Inject's OUTPUT stream for TX). Never assumed.
    private static func nativeFormat(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> CallAudioPCMFormat? {
        guard let streamID = streams(deviceID: deviceID, scope: scope).first else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return CallAudioPCMFormat(sampleRate: asbd.mSampleRate, channelCount: Int(asbd.mChannelsPerFrame), bytesPerFrame: asbd.mBytesPerFrame, isFloat: isFloat, isInterleaved: isInterleaved)
    }

    private static func expectedASBD() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: CallAudioPCMFormat.expected.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: CallAudioPCMFormat.expected.bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: CallAudioPCMFormat.expected.bytesPerFrame,
            mChannelsPerFrame: UInt32(CallAudioPCMFormat.expected.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func disposeAudioUnit(_ audioUnit: AudioUnit?) {
        guard let audioUnit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
    }

    private func startCaptureAUHAL(deviceID: AudioDeviceID, runtime: OpaquePointer) -> Bool {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            logger.log("[CALL-PCM] capture auhal component missing")
            return false
        }

        var audioUnit: AudioUnit?
        let newStatus = AudioComponentInstanceNew(component, &audioUnit)
        guard newStatus == noErr, let audioUnit else {
            logger.log("[CALL-PCM] capture auhal instance failed osStatus=\(newStatus)")
            return false
        }

        func fail(_ stage: String, _ status: OSStatus) -> Bool {
            logger.log("[CALL-PCM] capture auhal \(stage) failed osStatus=\(status)")
            Self.disposeAudioUnit(audioUnit)
            return false
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        let ioSize = UInt32(MemoryLayout<UInt32>.size)
        let enableStatus = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, ioSize)
        guard enableStatus == noErr else { return fail("enable-input", enableStatus) }
        let disableStatus = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, ioSize)
        guard disableStatus == noErr else { return fail("disable-output", disableStatus) }

        var device = deviceID
        let deviceStatus = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else { return fail("set-device", deviceStatus) }

        var asbd = Self.expectedASBD()
        let formatStatus = AudioUnitSetProperty(
            audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard formatStatus == noErr else { return fail("set-format", formatStatus) }

        var maxFrames = UInt32(JARVIS_PCM_CAPTURE_RENDER_MAX_FRAMES)
        let maxStatus = AudioUnitSetProperty(
            audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFrames, UInt32(MemoryLayout<UInt32>.size)
        )
        guard maxStatus == noErr else { return fail("set-max-frames", maxStatus) }

        var callback = AURenderCallbackStruct(
            inputProc: JarvisPCMCaptureAUInputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(runtime)
        )
        let callbackStatus = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else { return fail("set-callback", callbackStatus) }

        guard JarvisPCMRuntimeAttachCaptureAudioUnit(runtime, audioUnit) else {
            logger.log("[CALL-PCM] capture auhal attach failed")
            Self.disposeAudioUnit(audioUnit)
            return false
        }

        let initStatus = AudioUnitInitialize(audioUnit)
        guard initStatus == noErr else { return fail("initialize", initStatus) }
        let startStatus = AudioOutputUnitStart(audioUnit)
        guard startStatus == noErr else { return fail("start", startStatus) }

        captureDeviceID = deviceID
        captureAudioUnit = audioUnit
        logger.log("[CALL-PCM] tap auhal started")
        return true
    }

    private static func stopAndDestroy(deviceID: AudioDeviceID, procID: AudioDeviceIOProcID) {
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
    }

    /// Non-real-time only — called exclusively from `publishMetrics` (the 5Hz UI reader), never
    /// from a callback (§16: the C runtime publishes only linear values).
    nonisolated static func dBFS(_ linear: Float) -> Float {
        guard linear > 0 else { return CallAudioPCMMetrics.silenceFloorDBFS }
        return max(20 * log10(linear), CallAudioPCMMetrics.silenceFloorDBFS)
    }
}

/// Control-plane TX producer for the 1 s diagnostic tone. With JARVIS_PCM_TX_RING_FRAMES = 48000
/// the entire 1 s sine fits in one write; the timer path is never entered and no underrun is possible.
final class CallAudioToneRingProducer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jarvis.callbridge.tone-pump")
    private var source: DispatchSourceTimer?
    private var runtime: OpaquePointer?
    private var samples: [Float] = []
    private var framesWritten = 0

    func start(runtime: OpaquePointer, interleavedStereo: [Float]) {
        stop()
        queue.sync {
            self.runtime = runtime
            self.samples = interleavedStereo
            self.framesWritten = 0
            self.writeAvailable()
            guard self.framesWritten * 2 < interleavedStereo.count else { return }
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
            source.setEventHandler { [weak self] in
                self?.writeAvailable()
            }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            runtime = nil
            samples = []
            framesWritten = 0
        }
    }

    private func writeAvailable() {
        guard let runtime else { return }
        let totalFrames = samples.count / 2
        guard framesWritten < totalFrames else {
            source?.cancel()
            source = nil
            return
        }
        let remaining = UInt32(totalFrames - framesWritten)
        let written = samples.withUnsafeBufferPointer { buf -> UInt32 in
            guard let base = buf.baseAddress else { return 0 }
            return JarvisPCMRuntimeWriteTXFrames(runtime, base + framesWritten * 2, remaining)
        }
        framesWritten += Int(written)
        if framesWritten >= totalFrames {
            source?.cancel()
            source = nil
        }
    }
}
