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

    /// PRD §23: "ARMED ≠ Audio Driver Active". Even with a real activator available to call,
    /// Work Mode toggling must never activate/deactivate the Phase 1 HAL driver.
    func testWorkModeTogglingNeverActivatesAudioDriver() {
        let spy = AudioDriverActivationSpy()
        let machine = BridgeStateMachine(driverActivator: spy, logger: BridgeLogger())

        machine.setWorkMode(true)
        XCTAssertEqual(machine.state, .armed)
        XCTAssertEqual(spy.activateCallCount, 0, "entering ARMED must not activate the audio driver")
        XCTAssertEqual(spy.deactivateCallCount, 0)

        machine.setWorkMode(false)
        XCTAssertEqual(machine.state, .disabled)
        XCTAssertEqual(spy.activateCallCount, 0)
        XCTAssertEqual(spy.deactivateCallCount, 0, "leaving ARMED must not touch the audio driver either")
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

/// Test double proving `BridgeStateMachine` never activates/deactivates the CB v2 Phase 1 audio
/// driver, even though a (future-phase) implementation is available to call.
final class AudioDriverActivationSpy: AudioDriverActivating, @unchecked Sendable {
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    func activateCallAudioDriver() { activateCallCount += 1 }
    func deactivateCallAudioDriver() { deactivateCallCount += 1 }
}
