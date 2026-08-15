import Combine
import Foundation

/// CB Phase 0-C. Pure instrumentation: while RX capture and Virtual Mic TX are both running,
/// periodically logs both RMS levels side by side so a human tester can, during a real
/// simultaneous-speech test, judge feedback/loopback level and whether both streams stay
/// alive at once. No echo cancellation or other signal processing is performed here — that is
/// explicitly out of scope for Phase 0 (see PRD §20).
@MainActor
final class SeparationMonitor: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var sampleCount = 0

    private let logger: ProbeLogger
    private weak var rx: RXAudioProbe?
    private weak var tx: VirtualMicTXProbe?
    private var task: Task<Void, Never>?
    private let tickInterval: Duration = .milliseconds(200)

    init(logger: ProbeLogger, rx: RXAudioProbe, tx: VirtualMicTXProbe) {
        self.logger = logger
        self.rx = rx
        self.tx = tx
    }

    func start() {
        guard !running else { return }
        running = true
        sampleCount = 0
        logger.write("[SEP] simultaneous RX/TX monitor started")

        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.tick()
                try? await Task.sleep(for: self.tickInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        logger.write("[SEP] simultaneous RX/TX monitor stopped, samples=\(sampleCount)")
    }

    private func tick() {
        guard let rx, let tx else { return }
        sampleCount += 1
        let rxDb = rx.currentRMSdB
        let txDb = tx.currentRMSdB
        let rxLabel = rxDb.isFinite ? String(format: "%.1f", rxDb) : "-inf"
        let txLabel = txDb.isFinite ? String(format: "%.1f", txDb) : "-inf"
        logger.write("[SEP] rxState=\(rx.state.rawValue) txState=\(tx.state.rawValue) rxRMS=\(rxLabel)dB txRMS=\(txLabel)dB underruns=\(tx.underrunCount)")
    }
}
