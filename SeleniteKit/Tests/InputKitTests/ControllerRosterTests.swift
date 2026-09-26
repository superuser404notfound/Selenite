import Testing
@testable import InputKit

private final class Token {}

@Test func numbersAreLowestFreeAndMaskFollows() {
    var roster = ControllerRoster()
    let a = Token(), b = Token(), c = Token()
    #expect(roster.connect(id: ObjectIdentifier(a)) == 0)
    #expect(roster.connect(id: ObjectIdentifier(b)) == 1)
    #expect(roster.mask == 0b11)
    #expect(roster.disconnect(id: ObjectIdentifier(a)) == 0)
    #expect(roster.mask == 0b10)
    #expect(roster.connect(id: ObjectIdentifier(c)) == 0)
    #expect(roster.mask == 0b11)
}

@Test func reconnectingKeepsItsNumber() {
    var roster = ControllerRoster()
    let a = Token()
    let first = roster.connect(id: ObjectIdentifier(a))
    #expect(roster.connect(id: ObjectIdentifier(a)) == first)
}

/// Review focus: a controller that disconnects mid-game must release every button on the host.
/// The pure release helper is what `ControllerManager.disconnect` calls, tested here without
/// needing GameController.
@Test func disconnectReleasesEveryButtonInTwoSteps() {
    let events = ControllerRoster.releaseEvents(number: 1, remainingMask: 0b0100)
    #expect(events.count == 2)
    // Step 1: neutral state while the controller is still advertised in the mask.
    #expect(events[0].mask == 0b0110)
    #expect(events[0].state == GamepadState())
    // Step 2: the same neutral state under the mask with its bit cleared.
    #expect(events[1].mask == 0b0100)
    #expect(events[1].state == GamepadState())
}

@Test func releaseEventsWorkAtTheTopNumber() {
    let events = ControllerRoster.releaseEvents(number: 15, remainingMask: 0)
    #expect(events[0].mask == 0b1000_0000_0000_0000)
    #expect(events[1].mask == 0)
}
