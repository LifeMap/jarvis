import Combine
import Foundation

@MainActor
final class FeasibilityModel: ObservableObject {
    let logger: ProbeLogger
    let calls: CallStateMonitor
    let callGuess: PhoneAppAccessibilityProbe
    let rx: RXAudioProbe
    let tx: TXAudioProbe
    let vmicTX: VirtualMicTXProbe
    let separation: SeparationMonitor

    @Published private(set) var running = false
    @Published private(set) var simultaneousTestRunning = false

    init() {
        let logger = ProbeLogger()
        self.logger = logger
        self.calls = CallStateMonitor(logger: logger)
        self.callGuess = PhoneAppAccessibilityProbe(logger: logger)
        self.rx = RXAudioProbe(logger: logger)
        self.tx = TXAudioProbe(logger: logger)
        self.vmicTX = VirtualMicTXProbe(logger: logger)
        self.separation = SeparationMonitor(logger: logger, rx: rx, tx: vmicTX)
    }

    func start() async {
        guard !running else { return }
        running = true
        logger.write("[TEST] Phase 0 probe starting; no result is PASS until checked with a real cellular call")
        calls.start()
        callGuess.start()
        await rx.start()
    }

    func stop() async {
        stopSimultaneousTest()
        tx.stop()
        vmicTX.stop()
        await rx.stop()
        calls.stop()
        callGuess.stop()
        running = false
        logger.write("[TEST] Phase 0 probe stopped; resources released")
    }

    /// CB Phase 0-C: runs RX capture + Virtual Mic TX playback together and logs both RMS levels
    /// side by side so a human tester can judge separation/feedback during a real simultaneous
    /// speech test. Starting this does not itself prove separation — see SeparationMonitor.
    func startSimultaneousTest() {
        guard running, !simultaneousTestRunning else { return }
        simultaneousTestRunning = true
        vmicTX.playSpeechSample()
        separation.start()
    }

    func stopSimultaneousTest() {
        guard simultaneousTestRunning else { return }
        separation.stop()
        vmicTX.stopPlayback()
        simultaneousTestRunning = false
    }
}
