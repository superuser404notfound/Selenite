/// Turns the Siri Remote's touch surface into relative mouse motion, like a laptop trackpad.
///
/// Samples are the surface's absolute position (`reportsAbsoluteDpadValues`), -1...1 on both axes
/// with y up. The surface reports exactly (0, 0) when the finger lifts, so that sample ends the
/// touch and the next one only anchors: putting the finger down elsewhere never jumps the pointer.
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

        public static let standard = Tuning(pixelsPerUnit: 500, maxBoost: 3, fullBoostSpeed: 4, clickDeadzone: 0.12)
    }

    public var tuning: Tuning
    private var last: (x: Float, y: Float, time: Double)?
    private var remainder: (x: Float, y: Float) = (0, 0)
    private var clickTravel: Float?

    public init(tuning: Tuning = .standard) {
        self.tuning = tuning
    }

    /// One surface sample; returns the pointer motion in host pixels, y down. `time` is in seconds.
    public mutating func touch(x: Float, y: Float, time: Double) -> (dx: Int16, dy: Int16) {
        guard x != 0 || y != 0 else {
            last = nil
            remainder = (0, 0)
            return (0, 0)
        }
        defer { last = (x, y, time) }
        guard let last else { return (0, 0) }
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
