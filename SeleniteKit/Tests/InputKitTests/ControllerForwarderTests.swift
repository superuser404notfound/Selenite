import Testing
@testable import InputKit

private final class RecordingSink: ControllerEventSink, @unchecked Sendable {
    struct Sent: Equatable {
        let number: UInt8
        let mask: UInt16
        let state: GamepadState
    }
    var states: [Sent] = []
    var arrivals: [UInt8] = []
    var touches = 0

    func controllerArrived(number: UInt8, mask: UInt16, kind: ControllerKind) { arrivals.append(number) }
    func controllerState(number: UInt8, mask: UInt16, state: GamepadState) {
        states.append(Sent(number: number, mask: mask, state: state))
    }
    func controllerTouch(number: UInt8, event: UInt8, pointer: UInt32, x: Float, y: Float, pressure: Float) { touches += 1 }
    func controllerMotion(number: UInt8, type: UInt8, x: Float, y: Float, z: Float) {}
    func controllerBattery(number: UInt8, state: UInt8, percent: UInt8) {}
}

private func pressing(_ buttons: Int32) -> GamepadState {
    var state = GamepadState()
    state.buttons = buttons
    return state
}

@MainActor private func twoControllers() -> (RecordingSink, ControllerForwarder) {
    let sink = RecordingSink()
    let forwarder = ControllerForwarder(sink: sink)
    forwarder.arrived(number: 0, mask: 0b01, kind: .xbox)
    forwarder.arrived(number: 1, mask: 0b11, kind: .dualSense)
    return (sink, forwarder)
}

@MainActor @Test func statesReachTheHostWhileForwarding() {
    let (sink, forwarder) = twoControllers()
    forwarder.state(number: 0, mask: 0b11, state: pressing(0x1000))
    let expected: [RecordingSink.Sent] = [.init(number: 0, mask: 0b11, state: pressing(0x1000))]
    #expect(sink.states == expected)
    #expect(sink.arrivals == [0, 1])
}

@MainActor @Test func pausingSendsOneNeutralStatePerController() {
    let (sink, forwarder) = twoControllers()
    forwarder.state(number: 0, mask: 0b11, state: pressing(0x1000))
    sink.states.removeAll()
    forwarder.setForwarding(false)
    let expected: [RecordingSink.Sent] = [
        .init(number: 0, mask: 0b11, state: GamepadState()),
        .init(number: 1, mask: 0b11, state: GamepadState()),
    ]
    #expect(sink.states == expected)
    #expect(!forwarder.isForwarding)
}

@MainActor @Test func nothingIsSentWhilePaused() {
    let (sink, forwarder) = twoControllers()
    forwarder.setForwarding(false)
    sink.states.removeAll()
    forwarder.state(number: 0, mask: 0b11, state: pressing(0x1000))
    forwarder.touch(number: 0, event: 1, pointer: 0, x: 0.5, y: 0.5, pressure: 1)
    #expect(sink.states.isEmpty)
    #expect(sink.touches == 0)
}

@MainActor @Test func resumingSendsTheCurrentNotTheStaleState() {
    // Review Focus 3: A held when the overlay opens, released while it is open.
    let (sink, forwarder) = twoControllers()
    forwarder.state(number: 0, mask: 0b11, state: pressing(0x1000))
    forwarder.setForwarding(false)
    forwarder.state(number: 0, mask: 0b11, state: GamepadState())
    var tilted = pressing(0x0001)
    tilted.leftX = 1200
    forwarder.state(number: 1, mask: 0b11, state: tilted)
    sink.states.removeAll()
    forwarder.setForwarding(true)
    var axesOnly = GamepadState()
    axesOnly.leftX = 1200
    let expected: [RecordingSink.Sent] = [
        .init(number: 0, mask: 0b11, state: GamepadState()),
        .init(number: 1, mask: 0b11, state: axesOnly),
    ]
    #expect(sink.states == expected)
    #expect(forwarder.isForwarding)
}

@MainActor @Test func aButtonHeldAtResumeStaysMaskedUntilReleased() {
    // The button that closed the overlay is still down when forwarding resumes.
    let (sink, forwarder) = twoControllers()
    forwarder.setForwarding(false)
    forwarder.state(number: 0, mask: 0b11, state: pressing(0x1000))
    forwarder.setForwarding(true)
    sink.states.removeAll()
    var held = pressing(0x1000 | 0x2000)
    held.rightY = -500
    forwarder.state(number: 0, mask: 0b11, state: held)
    forwarder.state(number: 0, mask: 0b11, state: GamepadState())
    forwarder.state(number: 0, mask: 0b11, state: pressing(0x1000))
    var fresh = pressing(0x2000)
    fresh.rightY = -500
    let expected: [RecordingSink.Sent] = [
        .init(number: 0, mask: 0b11, state: fresh),
        .init(number: 0, mask: 0b11, state: GamepadState()),
        .init(number: 0, mask: 0b11, state: pressing(0x1000)),
    ]
    #expect(sink.states == expected)
}

@MainActor @Test func theMaskIsPerController() {
    let (sink, forwarder) = twoControllers()
    forwarder.setForwarding(false)
    forwarder.state(number: 0, mask: 0b11, state: pressing(0x1000))
    forwarder.setForwarding(true)
    sink.states.removeAll()
    forwarder.state(number: 1, mask: 0b11, state: pressing(0x1000))
    let expected: [RecordingSink.Sent] = [.init(number: 1, mask: 0b11, state: pressing(0x1000))]
    #expect(sink.states == expected)
}

@MainActor @Test func settingTheSameForwardingTwiceSendsNothing() {
    let (sink, forwarder) = twoControllers()
    forwarder.setForwarding(true)
    #expect(sink.states.isEmpty)
    forwarder.setForwarding(false)
    sink.states.removeAll()
    forwarder.setForwarding(false)
    #expect(sink.states.isEmpty)
}

@MainActor @Test func releaseAllLiftsEveryControllerAndClearsTheMask() {
    let (sink, forwarder) = twoControllers()
    forwarder.state(number: 1, mask: 0b11, state: pressing(0x1000))
    sink.states.removeAll()
    forwarder.releaseAll()
    let expected: [RecordingSink.Sent] = [
        .init(number: 0, mask: 0b11, state: GamepadState()),
        .init(number: 0, mask: 0b10, state: GamepadState()),
        .init(number: 1, mask: 0b10, state: GamepadState()),
        .init(number: 1, mask: 0b00, state: GamepadState()),
    ]
    #expect(sink.states == expected)
}

@MainActor @Test func releaseAllLeavesTheForwarderForwardingAndEmpty() {
    let (sink, forwarder) = twoControllers()
    forwarder.setForwarding(false)
    forwarder.releaseAll()
    sink.states.removeAll()
    #expect(forwarder.isForwarding)
    forwarder.setForwarding(false)
    #expect(sink.states.isEmpty)
}

@MainActor @Test func aReleasedControllerIsNotResumedLater() {
    let (sink, forwarder) = twoControllers()
    forwarder.setForwarding(false)
    forwarder.released(number: 1, remainingMask: 0b01)
    sink.states.removeAll()
    forwarder.setForwarding(true)
    let expected: [RecordingSink.Sent] = [.init(number: 0, mask: 0b01, state: GamepadState())]
    #expect(sink.states == expected)
}
