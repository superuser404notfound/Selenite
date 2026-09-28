/// Turns the Siri Remote's touch surface into relative mouse motion, like a laptop trackpad.
///
/// Samples are the surface's absolute position (`reportsAbsoluteDpadValues`), -1...1 on both axes
/// with y up. Measured on a Siri Remote (2026-09-28):
/// - The axes update one at a time. A touch starts as (x, 0) and ends through (0, y) to (0, 0), so a
///   sample with either axis exactly 0 is the edge of a touch, never a position.
/// - The first position after touching down is a guess the surface corrects 60 to 450 ms later by
///   up to 0.14 units, while tracking reports every 10 to 15 ms. A sample after a longer gap, and
///   its other axis arriving right behind it, therefore only re-anchors.
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

        public init(pixelsPerUnit: Float, maxBoost: Float, fullBoostSpeed: Float, clickDeadzone: Float) {
            self.pixelsPerUnit = pixelsPerUnit
            self.maxBoost = maxBoost
            self.fullBoostSpeed = fullBoostSpeed
            self.clickDeadzone = clickDeadzone
        }

        public static let standard = Tuning(pixelsPerUnit: 350, maxBoost: 2.5, fullBoostSpeed: 4, clickDeadzone: 0.12)
    }

    /// A sample arriving this long after the previous one re-anchors instead of moving.
    public static let resyncGap = 0.05
    /// A sample this close behind a re-anchoring one is its other axis and re-anchors too.
    public static let axisTwinWindow = 0.005

    public var tuning: Tuning
    private var last: (x: Float, y: Float, time: Double)?
    private var remainder: (x: Float, y: Float) = (0, 0)
    private var clickTravel: Float?
    private var anchorTime = -Double.infinity

    public init(tuning: Tuning = .standard) {
        self.tuning = tuning
    }

    /// One surface sample; returns the pointer motion in host pixels, y down. `time` is in seconds.
    public mutating func touch(x: Float, y: Float, time: Double) -> (dx: Int16, dy: Int16) {
        guard x != 0, y != 0 else {
            last = nil
            remainder = (0, 0)
            return (0, 0)
        }
        defer { last = (x, y, time) }
        guard let last, time - last.time <= Self.resyncGap else {
            anchorTime = time
            return (0, 0)
        }
        guard time - anchorTime > Self.axisTwinWindow else { return (0, 0) }
        let moveX = x - last.x
        let moveY = y - last.y
        let distance = (moveX * moveX + moveY * moveY).squareRoot()
        if let travel = clickTravel {
            let total = travel + distance
            if total < tuning.clickDeadzone {
                clickTravel = total
                return (0, 0)
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
        return (dx, dy)
    }

    /// The surface's click. Pressing starts the deadzone; releasing ends it.
    public mutating func setClick(pressed: Bool) {
        clickTravel = pressed ? 0 : nil
    }

    private static func clamp(_ value: Float) -> Int16 {
        Int16(max(Float(Int16.min), min(Float(Int16.max), value)))
    }
}
