import XCTest
@testable import JarvisCallBridge

@MainActor
final class RealtimeVoiceAdapterTests: XCTestCase {
    func testMockConnectDisconnectAndBuffers() async {
        let mock = MockRealtimeVoiceAdapter()
        XCTAssertFalse(mock.isConnected)
        let connected = await mock.connect()
        XCTAssertTrue(connected)
        XCTAssertTrue(mock.isConnected)

        let rx = RealtimeAudioConverter.toProviderRX(interleavedStereo48k: [0.1, 0.1, 0.1, 0.1])
        mock.sendRX(rx)
        XCTAssertEqual(mock.sentRX.count, 1)
        XCTAssertEqual(mock.sentRX[0], rx)

        mock.enqueueTX([0, 1, 2])
        XCTAssertEqual(mock.pollTX(), [0, 1, 2])
        XCTAssertEqual(mock.pollTX(), [])

        await mock.disconnect()
        XCTAssertFalse(mock.isConnected)
        XCTAssertTrue(mock.sentRX.isEmpty)
    }

    func testMockConnectFailure() async {
        let mock = MockRealtimeVoiceAdapter()
        mock.failConnect = true
        let connected = await mock.connect()
        XCTAssertFalse(connected)
        XCTAssertFalse(mock.isConnected)
    }
}
