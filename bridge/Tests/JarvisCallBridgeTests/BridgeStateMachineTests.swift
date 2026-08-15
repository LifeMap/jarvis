import CoreAudio
import XCTest
@testable import JarvisCallBridge

@MainActor
final class BridgeStateMachineTests: XCTestCase {
    func testInitialStateIsDisabled() {
        let machine = BridgeStateMachine(logger: BridgeLogger())
        XCTAssertEqual(machine.state, .disabled)
        XCTAssertFalse(machine.workModeEnabled)
    }

    func testWorkModeOnTransitionsToArmed() {
        let machine = BridgeStateMachine(logger: BridgeLogger())
        machine.setWorkMode(true)
        XCTAssertEqual(machine.state, .armed)
        XCTAssertTrue(machine.workModeEnabled)
    }

    func testWorkModeOffTransitionsBackToDisabled() {
        let machine = BridgeStateMachine(logger: BridgeLogger())
        machine.setWorkMode(true)
        machine.setWorkMode(false)
        XCTAssertEqual(machine.state, .disabled)
        XCTAssertFalse(machine.workModeEnabled)
    }

    func testInvalidTransitionsAreRejected() {
        let machine = BridgeStateMachine(logger: BridgeLogger())
        // Phase 0 must never reach these states, regardless of what requests it.
        XCTAssertFalse(machine.requestTransition(to: .ringing))
        XCTAssertFalse(machine.requestTransition(to: .activeAI))
        XCTAssertFalse(machine.requestTransition(to: .handoffToIPhone))
        XCTAssertEqual(machine.state, .disabled, "state must be unchanged after a rejected transition")

        machine.setWorkMode(true)
        XCTAssertFalse(machine.requestTransition(to: .preparing))
        XCTAssertEqual(machine.state, .armed, "state must be unchanged after a rejected transition")
    }

    func testWorkModeTogglingNeverMutatesAudioRoute() {
        let spy = AudioRouteMutationSpy()
        let machine = BridgeStateMachine(routeMutator: spy, logger: BridgeLogger())

        machine.setWorkMode(true)
        XCTAssertEqual(machine.state, .armed)
        XCTAssertEqual(spy.callCount, 0, "entering ARMED must not touch the audio route")

        machine.setWorkMode(false)
        XCTAssertEqual(machine.state, .disabled)
        XCTAssertEqual(spy.callCount, 0, "leaving ARMED must not touch the audio route")
    }
}

/// Test double proving `BridgeStateMachine` never calls into audio route mutation, even though a
/// (future-phase) implementation is available to call.
final class AudioRouteMutationSpy: AudioRouteMutating, @unchecked Sendable {
    private(set) var callCount = 0

    func setDefaultInputDevice(_ deviceID: AudioDeviceID) { callCount += 1 }
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) { callCount += 1 }
    func setDefaultSystemOutputDevice(_ deviceID: AudioDeviceID) { callCount += 1 }
}
