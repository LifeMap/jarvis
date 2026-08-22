@MainActor
protocol RealtimePCMBuffering: AnyObject {
    var isRunning: Bool { get }
    func readRXFrames(maxFrames: Int) -> [Float]
    func writeTXFrames(_ interleavedStereo: [Float]) -> Int
    func queuedTXFrames() -> Int
    func clearRX()
}
