import Foundation
import Testing
@testable import InputKit

private let flat = RemotePointer.Tuning(pixelsPerUnit: 100, maxBoost: 1, fullBoostSpeed: 4, clickDeadzone: 0.2)
private let tick = 0.015

private struct Total: Equatable {
    var dx = 0
    var dy = 0
    var scroll = 0
}

/// Feeds samples one `tick` apart starting at `start` and returns the summed output.
private func feed(_ pointer: inout RemotePointer, _ samples: [(Float, Float)], start: Double = 0) -> Total {
    var total = Total()
    for (index, sample) in samples.enumerated() {
        let motion = pointer.touch(x: sample.0, y: sample.1, time: start + Double(index) * tick)
        total.dx += Int(motion.dx)
        total.dy += Int(motion.dy)
        total.scroll += Int(motion.scroll)
    }
    return total
}

/// Points on a circle of `radius`, from `from` to `to` degrees in `steps` equal steps.
private func arc(radius: Float, from: Float, to: Float, steps: Int) -> [(Float, Float)] {
    (0...steps).map { index in
        let degrees = from + (to - from) * Float(index) / Float(steps)
        let radians = degrees * .pi / 180
        return (radius * cos(radians), radius * sin(radians))
    }
}

@Test func firstSampleOnlyAnchors() {
    var pointer = RemotePointer(tuning: flat)
    #expect(pointer.touch(x: 0.25, y: 0.25, time: 0) == .none)
}

@Test func motionScalesAndFlipsY() {
    var pointer = RemotePointer(tuning: flat)
    #expect(feed(&pointer, [(0.25, 0.25), (0.5, 0.125)]) == Total(dx: 25, dy: 12))
}

@Test func liftingNeverJumpsOnTheNextTouch() {
    var pointer = RemotePointer(tuning: flat)
    _ = feed(&pointer, [(-0.25, -0.25), (0, 0)])
    #expect(feed(&pointer, [(0.25, 0.25), (0.5, 0.25)], start: 1) == Total(dx: 25))
}

/// Replays a measured touch: down as (x, 0) then y, up through (0, y) to (0, 0).
@Test func axisByAxisEdgesNeverMove() {
    var pointer = RemotePointer(tuning: flat)
    let down = feed(&pointer, [(-0.187, 0), (-0.187, -0.104)])
    let up = feed(&pointer, [(0, -0.104), (0, 0)], start: 1)
    #expect(down == Total())
    #expect(up == Total())
    #expect(feed(&pointer, [(0.25, 0), (0.25, 0.25), (0.5, 0.25)], start: 2) == Total(dx: 25))
}

/// Replays a measured correction: the touch-down guess is fixed 419 ms later, axis by axis.
@Test func correctionAfterTouchDownOnlyReanchors() {
    var pointer = RemotePointer(tuning: flat)
    _ = feed(&pointer, [(0.267, 0), (0.267, 0.066)])
    #expect(pointer.touch(x: 0.212, y: 0.066, time: 0.434) == .none)
    #expect(pointer.touch(x: 0.212, y: 0.009, time: 0.435) == .none)
    #expect(pointer.touch(x: 0.462, y: 0.009, time: 0.450) == RemotePointer.Motion(dx: 25))
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
    #expect(feed(&slow, [(0.25, 0.25), (0.25 + 1.0 / 128, 0.25)]).dx == 9)
    #expect(feed(&fast, [(0.25, 0.25), (0.5, 0.25)]).dx == 750)
}

@Test func clickHoldsThePointerInsideTheDeadzone() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.1, time: 0)
    pointer.setClick(pressed: true)
    #expect(feed(&pointer, [(0.15, 0.1), (0.2, 0.1)], start: tick) == Total())
    pointer.setClick(pressed: false)
    #expect(pointer.touch(x: 0.3, y: 0.1, time: 3 * tick).dx == 10)
}

@Test func dragPastTheDeadzoneMoves() {
    var pointer = RemotePointer(tuning: flat)
    _ = pointer.touch(x: 0.1, y: 0.1, time: 0)
    pointer.setClick(pressed: true)
    #expect(pointer.touch(x: 0.25, y: 0.1, time: tick) == .none)
    #expect(pointer.touch(x: 0.4, y: 0.1, time: 2 * tick).dx == 15)
    #expect(pointer.touch(x: 0.5, y: 0.1, time: 3 * tick).dx == 10)
}

@Test func clockwiseOnTheRingScrollsDown() {
    var pointer = RemotePointer(tuning: flat)
    let total = feed(&pointer, arc(radius: 0.8, from: 91, to: -89, steps: 36))
    #expect(total.dx == 0 && total.dy == 0)
    #expect(total.scroll <= -715 && total.scroll >= -720)
}

@Test func counterClockwiseOnTheRingScrollsUp() {
    var pointer = RemotePointer(tuning: flat)
    let total = feed(&pointer, arc(radius: 0.8, from: 1, to: 361, steps: 72))
    #expect(total.scroll >= 1435 && total.scroll <= 1440)
}

@Test func ringCrossingTheLeftSideKeepsItsDirection() {
    var pointer = RemotePointer(tuning: flat)
    let total = feed(&pointer, arc(radius: 0.8, from: 150, to: 210, steps: 12))
    #expect(total.scroll >= 235 && total.scroll <= 240)
}

@Test func ringBelowTheCommitAngleNeverScrolls() {
    var pointer = RemotePointer(tuning: flat)
    #expect(feed(&pointer, arc(radius: 0.8, from: 1, to: 13, steps: 6)).scroll == 0)
}

/// A pointer move started at the edge that heads inwards moves the pointer once inside.
@Test func edgeStartedMoveInwardsBecomesThePointer() {
    var pointer = RemotePointer(tuning: flat)
    let samples: [(Float, Float)] = [(0.8, 0.05), (0.7, 0.05), (0.6, 0.05), (0.45, 0.05), (0.3, 0.05), (0.2, 0.05)]
    let total = feed(&pointer, samples)
    #expect(total.scroll == 0)
    #expect(total.dx == -40)
}

@Test func liftEndsTheRing() {
    var pointer = RemotePointer(tuning: flat)
    _ = feed(&pointer, arc(radius: 0.8, from: 1, to: 89, steps: 18))
    _ = pointer.touch(x: 0, y: 0, time: 1)
    #expect(feed(&pointer, [(0.25, 0.25), (0.5, 0.25)], start: 2) == Total(dx: 25))
}
