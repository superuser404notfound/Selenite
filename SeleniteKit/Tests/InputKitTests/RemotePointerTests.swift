import Testing
@testable import InputKit

private let flat = RemotePointer.Tuning(pixelsPerUnit: 100, maxBoost: 1, fullBoostSpeed: 4, clickDeadzone: 0.2)

@Test func firstSampleOnlyAnchors() {
    var pointer = RemotePointer(tuning: flat)
    #expect(pointer.touch(x: 0.5, y: 0.5, time: 0) == (0, 0))
}

@Test func motionScalesAndFlipsY() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.1, time: 0)
    let move = pointer.touch(x: 0.2, y: 0.0001, time: 1)
    #expect(move.dx == 10)
    #expect(move.dy == 9)
}

@Test func liftingNeverJumpsOnTheNextTouch() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: -0.8, y: -0.8, time: 0)
    #expect(pointer.touch(x: 0, y: 0, time: 0.1) == (0, 0))
    #expect(pointer.touch(x: 0.5, y: 0.5, time: 0.2) == (0, 0))
    #expect(pointer.touch(x: 0.75, y: 0.5, time: 1.2) == (25, 0))
}

@Test func slowMotionKeepsItsFractions() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.5, time: 0)
    var total = 0
    for step in 1...10 {
        total += Int(pointer.touch(x: 0.1 + Float(step) * 0.004, y: 0.5, time: Double(step)).dx)
    }
    #expect(total == 3 || total == 4)
}

@Test func fastMotionIsBoosted() {
    let tuning = RemotePointer.Tuning(pixelsPerUnit: 100, maxBoost: 3, fullBoostSpeed: 4, clickDeadzone: 0.2)
    var slow = RemotePointer(tuning: tuning)
    _ = slow.touch(x: 0.1, y: 0.5, time: 0)
    let slowMove = slow.touch(x: 0.2, y: 0.5, time: 1)
    var fast = RemotePointer(tuning: tuning)
    _ = fast.touch(x: 0.1, y: 0.5, time: 0)
    let fastMove = fast.touch(x: 0.2, y: 0.5, time: 0.01)
    #expect(slowMove.dx == 10)
    #expect(fastMove.dx == 30)
}

@Test func clickHoldsThePointerInsideTheDeadzone() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.1, time: 0)
    pointer.setClick(pressed: true)
    #expect(pointer.touch(x: 0.15, y: 0.1, time: 1) == (0, 0))
    #expect(pointer.touch(x: 0.2, y: 0.1, time: 2) == (0, 0))
    pointer.setClick(pressed: false)
    #expect(pointer.touch(x: 0.3, y: 0.1, time: 3).dx == 10)
}

@Test func dragPastTheDeadzoneMoves() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.1, time: 0)
    pointer.setClick(pressed: true)
    #expect(pointer.touch(x: 0.25, y: 0.1, time: 1) == (0, 0))
    #expect(pointer.touch(x: 0.4, y: 0.1, time: 2).dx == 15)
    #expect(pointer.touch(x: 0.5, y: 0.1, time: 3).dx == 10)
}
