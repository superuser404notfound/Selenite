import Foundation

/// Turns the Siri Remote's touch surface into relative mouse motion, like a laptop trackpad, and a
/// circle on its outer ring into the scroll wheel.
///
/// Samples are the surface's absolute position (`reportsAbsoluteDpadValues`), -1...1 on both axes
/// with y up. Measured on a Siri Remote (2026-09-28):
/// - The axes update one at a time. A touch starts as (x, 0) and ends through (0, y) to (0, 0), so a
///   sample with either axis exactly 0 is the edge of a touch, never a position.
/// - The first position after touching down is a guess the surface corrects 60 to 450 ms later by
///   up to 0.14 units, while tracking reports every 10 to 15 ms. A sample after a longer gap, and
///   its other axis arriving right behind it, therefore only re-anchors.
/// - Circling the ring stays 0.67 to 1.0 from the centre (median 0.8). A touch that starts at least
///   `ringEntryRadius` out scrolls; if it comes inside `ringExitRadius` it is a pointer move that
///   began at the edge and moves the pointer for the rest of the touch.
public struct RemotePointer: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Pointer pixels per surface unit at slow speed (the surface is 2 units wide).
        public var pixelsPerUnit: Float
        /// Multiplier reached at `fullBoostSpeed` and above.
        public var maxBoost: Float
        /// Surface units per second at which the boost is complete; it rises linearly up to there.
        public var fullBoostSpeed: Float
        /// While the surface is clicked, motion stays still until the finger has travelled this far
        /// from where it was on the press, so clicking does not nudge the pointer but dragging works.
        public var clickDeadzone: Float
        /// Degrees of ring rotation per wheel notch.
        public var degreesPerNotch: Float

        public init(pixelsPerUnit: Float, maxBoost: Float, fullBoostSpeed: Float, clickDeadzone: Float,
                    degreesPerNotch: Float = 30) {
            self.pixelsPerUnit = pixelsPerUnit
            self.maxBoost = maxBoost
            self.fullBoostSpeed = fullBoostSpeed
            self.clickDeadzone = clickDeadzone
            self.degreesPerNotch = degreesPerNotch
        }

        public static let standard = Tuning(pixelsPerUnit: 350, maxBoost: 2.5, fullBoostSpeed: 4, clickDeadzone: 0.12)
    }

    /// One sample's output: pointer pixels (y down) and wheel units (120 per notch, positive up).
    public struct Motion: Sendable, Equatable {
        public var dx: Int16
        public var dy: Int16
        public var scroll: Int16

        public init(dx: Int16 = 0, dy: Int16 = 0, scroll: Int16 = 0) {
            self.dx = dx
            self.dy = dy
            self.scroll = scroll
        }

        public static let none = Motion()
    }

    private enum Mode {
        case pointer
        case ring
    }

    /// A sample arriving this long after the previous one re-anchors instead of moving.
    public static let resyncGap = 0.05
    /// A sample this close behind a re-anchoring one is its other axis and re-anchors too.
    public static let axisTwinWindow = 0.005
    public static let ringEntryRadius: Float = 0.65
    public static let ringExitRadius: Float = 0.5
    /// Rotation a ring touch must reach before it scrolls, so an edge-started pointer move that
    /// turns a little on its way in never scrolls.
    public static let ringCommitDegrees: Float = 15
    public static let wheelUnitsPerNotch: Float = 120

    public var tuning: Tuning
    private var last: (x: Float, y: Float, time: Double)?
    private var remainder: (x: Float, y: Float) = (0, 0)
    private var clickTravel: Float?
    private var anchorTime = -Double.infinity
    private var mode: Mode?
    private var ringDegrees: Float = 0
    private var ringCommitted = false
    private var scrollRemainder: Float = 0

    public init(tuning: Tuning = .standard) {
        self.tuning = tuning
    }

    /// One surface sample. `time` is in seconds.
    public mutating func touch(x: Float, y: Float, time: Double) -> Motion {
        guard x != 0, y != 0 else {
            endTouch()
            return .none
        }
        defer { last = (x, y, time) }
        guard let last, time - last.time <= Self.resyncGap else {
            anchorTime = time
            return .none
        }
        guard time - anchorTime > Self.axisTwinWindow else { return .none }
        if mode == nil {
            mode = Self.radius(last.x, last.y) >= Self.ringEntryRadius ? .ring : .pointer
        }
        if mode == .ring, Self.radius(x, y) < Self.ringExitRadius {
            mode = .pointer
        }
        switch mode {
        case .ring:
            return Motion(scroll: ringStep(from: last, toX: x, toY: y))
        case .pointer, nil:
            return pointerStep(from: last, toX: x, toY: y, time: time)
        }
    }

    /// The surface's click. Pressing starts the deadzone; releasing ends it.
    public mutating func setClick(pressed: Bool) {
        clickTravel = pressed ? 0 : nil
    }

    private mutating func endTouch() {
        last = nil
        remainder = (0, 0)
        mode = nil
        ringDegrees = 0
        ringCommitted = false
        scrollRemainder = 0
    }

    private mutating func pointerStep(from last: (x: Float, y: Float, time: Double), toX x: Float, toY y: Float,
                                      time: Double) -> Motion {
        let moveX = x - last.x
        let moveY = y - last.y
        let distance = (moveX * moveX + moveY * moveY).squareRoot()
        if let travel = clickTravel {
            let total = travel + distance
            if total < tuning.clickDeadzone {
                clickTravel = total
                return .none
            }
            clickTravel = nil
        }
        let elapsed = max(time - last.time, 0.001)
        let speed = distance / Float(elapsed)
        let ramp = min(speed / tuning.fullBoostSpeed, 1)
        let scale = tuning.pixelsPerUnit * (1 + ramp * (tuning.maxBoost - 1))
        let wantX = moveX * scale + remainder.x
        let wantY = -moveY * scale + remainder.y
        let dx = Self.clamp(wantX.rounded(.towardZero))
        let dy = Self.clamp(wantY.rounded(.towardZero))
        remainder = (wantX - Float(dx), wantY - Float(dy))
        return Motion(dx: dx, dy: dy)
    }

    /// Clockwise (the angle falling, y up) scrolls down, which is a negative wheel amount.
    private mutating func ringStep(from last: (x: Float, y: Float, time: Double), toX x: Float, toY y: Float) -> Int16 {
        var turn = (atan2(y, x) - atan2(last.y, last.x)) * 180 / .pi
        if turn > 180 { turn -= 360 }
        if turn < -180 { turn += 360 }
        if !ringCommitted {
            ringDegrees += turn
            guard abs(ringDegrees) >= Self.ringCommitDegrees else { return 0 }
            ringCommitted = true
            turn = ringDegrees
        }
        let want = turn / tuning.degreesPerNotch * Self.wheelUnitsPerNotch + scrollRemainder
        let amount = Self.clamp(want.rounded(.towardZero))
        scrollRemainder = want - Float(amount)
        return amount
    }

    private static func radius(_ x: Float, _ y: Float) -> Float {
        (x * x + y * y).squareRoot()
    }

    private static func clamp(_ value: Float) -> Int16 {
        Int16(max(Float(Int16.min), min(Float(Int16.max), value)))
    }
}
