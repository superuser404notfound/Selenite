import Testing
@testable import InputKit

private final class Pad {}

@Test func seatingCountsPerSideAndIsReadyWithOnePad() {
    let a = Pad(), b = Pad(), c = Pad()
    var seats = SeatMap()
    #expect(!seats.isReady)
    seats.seat(ObjectIdentifier(a), on: .first)
    #expect(seats.isReady)
    seats.seat(ObjectIdentifier(b), on: .second)
    seats.seat(ObjectIdentifier(c), on: .second)
    #expect(seats.isReady)
    #expect(seats.count(on: .first) == 1)
    #expect(seats.pads(on: .second) == [ObjectIdentifier(b), ObjectIdentifier(c)])
}

@Test func reseatingMovesAPadAndKeepsItsJoinOrder() {
    let a = Pad(), b = Pad()
    var seats = SeatMap()
    seats.seat(ObjectIdentifier(a), on: .first)
    seats.seat(ObjectIdentifier(b), on: .first)
    seats.seat(ObjectIdentifier(a), on: .second)
    #expect(seats.side(of: ObjectIdentifier(a)) == .second)
    #expect(seats.pads(on: .first) == [ObjectIdentifier(b)])
    seats.seat(ObjectIdentifier(a), on: .first)
    #expect(seats.pads(on: .first) == [ObjectIdentifier(a), ObjectIdentifier(b)])
}

@Test func keepOnlyDropsDisconnectedPads() {
    let a = Pad(), b = Pad()
    var seats = SeatMap()
    seats.seat(ObjectIdentifier(a), on: .first)
    seats.seat(ObjectIdentifier(b), on: .second)
    seats.keep(only: [ObjectIdentifier(b)])
    #expect(seats.side(of: ObjectIdentifier(a)) == nil)
    #expect(seats.seatedPads == [ObjectIdentifier(b)])
}

@Test func joinFollowsTheHeldDirectionAlongTheLayoutAxis() {
    let seats = SeatMap()
    #expect(seats.joinSide(for: .left, stacked: false) == .first)
    #expect(seats.joinSide(for: .right, stacked: false) == .second)
    #expect(seats.joinSide(for: .up, stacked: true) == .first)
    #expect(seats.joinSide(for: .down, stacked: true) == .second)
}

@Test func joinWithoutADirectionPicksTheSideWithFewerPlayers() {
    let a = Pad()
    var seats = SeatMap()
    #expect(seats.joinSide(for: .center, stacked: false) == .first)
    seats.seat(ObjectIdentifier(a), on: .first)
    #expect(seats.joinSide(for: .center, stacked: false) == .second)
    // A direction off the layout's axis counts as none.
    #expect(seats.joinSide(for: .up, stacked: false) == .second)
}

@Test func directionPrefersTheDpadThenTheDominantStickAxis() {
    var s = GamepadSnapshot()
    #expect(StickDirection.from(s) == .center)
    s.leftX = -0.9; s.leftY = 0.3
    #expect(StickDirection.from(s) == .left)
    s.leftX = 0.2; s.leftY = -0.8
    #expect(StickDirection.from(s) == .down)
    s.leftX = 0.3; s.leftY = 0.2
    #expect(StickDirection.from(s) == .center)
    s.right = true
    #expect(StickDirection.from(s) == .right)
}
