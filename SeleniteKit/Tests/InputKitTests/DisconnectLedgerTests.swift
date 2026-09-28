import Testing
@testable import InputKit

private final class Token {}

@Test func newControllersAreAdmitted() {
    var ledger = DisconnectLedger()
    let a = Token(), b = Token()
    let admitted = ledger.admissible(live: [ObjectIdentifier(a), ObjectIdentifier(b)], tracked: [ObjectIdentifier(a)])
    #expect(admitted == [ObjectIdentifier(b)])
}

@Test func aReleasedControllerStillListedIsNotReadmitted() {
    var ledger = DisconnectLedger()
    let a = Token()
    ledger.markReleased(ObjectIdentifier(a))
    let admitted = ledger.admissible(live: [ObjectIdentifier(a)], tracked: [])
    #expect(admitted.isEmpty)
}

@Test func theLedgerForgetsAControllerOnceItLeavesTheList() {
    var ledger = DisconnectLedger()
    let a = Token()
    ledger.markReleased(ObjectIdentifier(a))
    let gone = ledger.admissible(live: [], tracked: [])
    #expect(gone.isEmpty)
    let back = ledger.admissible(live: [ObjectIdentifier(a)], tracked: [])
    #expect(back == [ObjectIdentifier(a)])
}

@Test func aReconnectNotificationClearsTheEntry() {
    var ledger = DisconnectLedger()
    let a = Token()
    ledger.markReleased(ObjectIdentifier(a))
    ledger.markReconnected(ObjectIdentifier(a))
    let admitted = ledger.admissible(live: [ObjectIdentifier(a)], tracked: [])
    #expect(admitted == [ObjectIdentifier(a)])
}
