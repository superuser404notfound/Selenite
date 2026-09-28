import Testing
@testable import InputKit

private let flat = RemotePointer.Tuning(pixelsPerUnit: 100, maxBoost: 1, fullBoostSpeed: 4, clickDeadzone: 0.2)
private let tick = 0.015

/// Feeds samples one `tick` apart starting at `start` and returns the summed motion.
private func feed(_ pointer: inout RemotePointer, _ samples: [(Float, Float)], start: Double = 0) -> (dx: Int, dy: Int) {
    var total = (dx: 0, dy: 0)
    for (index, sample) in samples.enumerated() {
        let move = pointer.touch(x: sample.0, y: sample.1, time: start + Double(index) * tick)
        total.dx += Int(move.dx)
        total.dy += Int(move.dy)
    }
    return total
}

@Test func firstSampleOnlyAnchors() {
    var pointer = RemotePointer(tuning: flat)
    #expect(pointer.touch(x: 0.5, y: 0.5, time: 0) == (0, 0))
}

@Test func motionScalesAndFlipsY() {
    var pointer = RemotePointer(tuning: flat)
    #expect(feed(&pointer, [(0.25, 0.25), (0.5, 0.125)]) == (25, 12))
}

@Test func liftingNeverJumpsOnTheNextTouch() {
    var pointer = RemotePointer(tuning: flat)
    _ = feed(&pointer, [(-0.75, -0.75), (0, 0)])
    #expect(feed(&pointer, [(0.5, 0.5), (0.75, 0.5)], start: 1) == (25, 0))
}

/// Replays a measured touch: down as (x, 0) then y, up through (0, y) to (0, 0).
@Test func axisByAxisEdgesNeverMove() {
    var pointer = RemotePointer(tuning: flat)
    let down = feed(&pointer, [(-0.187, 0), (-0.187, -0.104)])
    let up = feed(&pointer, [(0, -0.104), (0, 0)], start: 1)
    #expect(down == (0, 0))
    #expect(up == (0, 0))
    #expect(feed(&pointer, [(0.25, 0), (0.25, 0.25), (0.5, 0.25)], start: 2) == (25, 0))
}

/// Replays a measured correction: the touch-down guess is fixed 419 ms later, axis by axis.
@Test func correctionAfterTouchDownOnlyReanchors() {
    var pointer = RemotePointer(tuning: flat)
    _ = feed(&pointer, [(0.267, 0), (0.267, 0.066)])
    #expect(pointer.touch(x: 0.212, y: 0.066, time: 0.434) == (0, 0))
    #expect(pointer.touch(x: 0.212, y: 0.009, time: 0.435) == (0, 0))
    #expect(pointer.touch(x: 0.462, y: 0.009, time: 0.450) == (25, 0))
}

@Test func slowMotionKeepsItsFractions() {
    var pointer = RemotePointer(tuning: flat)
    let samples = (0...10).map { (Float(0.1) + Float($0) * 0.004, Float(0.5)) }
    let total = feed(&pointer, samples).dx
    #expect(total == 3 || total == 4)
}

@Test func fastMotionIsBoosted() {
    let tuning = RemotePointer.Tuning(pixelsPerUnit: 1000, maxBoost: 3, fullBoostSpeed: 4, clickDeadzone: 0.2)
    var slow = RemotePointer(tuning: tuning)
    var fast = RemotePointer(tuning: tuning)
    // 1/128 unit in one tick is 0.52 units/s: boost 1.26, 9.8 px.
    #expect(feed(&slow, [(0.25, 0.5), (0.25 + 1.0 / 128, 0.5)]).dx == 9)
    #expect(feed(&fast, [(0.25, 0.5), (0.5, 0.5)]).dx == 750)
}

@Test func clickHoldsThePointerInsideTheDeadzone() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.1, time: 0)
    pointer.setClick(pressed: true)
    #expect(feed(&pointer, [(0.15, 0.1), (0.2, 0.1)], start: tick) == (0, 0))
    pointer.setClick(pressed: false)
    #expect(pointer.touch(x: 0.3, y: 0.1, time: 3 * tick).dx == 10)
}

@Test func dragPastTheDeadzoneMoves() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.1, time: 0)
    pointer.setClick(pressed: true)
    #expect(pointer.touch(x: 0.25, y: 0.1, time: tick) == (0, 0))
    #expect(pointer.touch(x: 0.4, y: 0.1, time: 2 * tick).dx == 15)
    #expect(pointer.touch(x: 0.5, y: 0.1, time: 3 * tick).dx == 10)
}
