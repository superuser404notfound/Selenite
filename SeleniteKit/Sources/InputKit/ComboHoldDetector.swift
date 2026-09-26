/// Fires once when a combination has been held for `holdSeconds`; releasing re-arms it.
public struct ComboHoldDetector: Sendable {
    // Tolerance for the floating-point elapsed-time comparison at the hold boundary
    // (e.g. 1.9 - 0.9 == 0.9999999999999999 in IEEE 754 double, not exactly 1.0).
    private static let epsilon = 1e-9

    public let holdSeconds: Double
    private var pressedSince: Double?
    private var fired = false

    public init(holdSeconds: Double = 1.0) { self.holdSeconds = holdSeconds }

    public mutating func update(pressed: Bool, now: Double) -> Bool {
        guard pressed else { pressedSince = nil; fired = false; return false }
        let start = pressedSince ?? now
        pressedSince = start
        guard !fired, now - start >= holdSeconds - Self.epsilon else { return false }
        fired = true
        return true
    }
}
