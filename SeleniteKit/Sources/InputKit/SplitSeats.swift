/// A controller's identity while it stays connected (GameController's object identity).
public typealias PadID = ObjectIdentifier

/// The two halves of a split screen in reading order: `first` is left or top.
public enum SplitSide: String, Codable, Sendable, CaseIterable {
    case first, second

    public var other: SplitSide { self == .first ? .second : .first }
}

public enum StickDirection: Sendable, Equatable {
    case center, left, right, up, down

    /// The D-pad wins; otherwise the left stick's dominant axis once it passes `threshold`.
    public static func from(_ snapshot: GamepadSnapshot, threshold: Float = 0.5) -> StickDirection {
        if snapshot.left { return .left }
        if snapshot.right { return .right }
        if snapshot.up { return .up }
        if snapshot.down { return .down }
        let x = snapshot.leftX, y = snapshot.leftY
        guard max(abs(x), abs(y)) >= threshold else { return .center }
        if abs(x) >= abs(y) { return x < 0 ? .left : .right }
        return y > 0 ? .up : .down
    }
}

/// Which controller plays on which side (M2 spec, section 3). Join order is kept, so each side
/// numbers its players in the order they joined.
public struct SeatMap: Equatable, Sendable {
    private var order: [PadID] = []
    private var sides: [PadID: SplitSide] = [:]

    public init() {}

    public func side(of pad: PadID) -> SplitSide? { sides[pad] }
    public func pads(on side: SplitSide) -> [PadID] { order.filter { sides[$0] == side } }
    public func count(on side: SplitSide) -> Int { pads(on: side).count }
    /// One seated pad is enough: an empty side streams too and can be joined later.
    public var isReady: Bool { !order.isEmpty }
    public var seatedPads: Set<PadID> { Set(order) }

    /// A pad keeps its join position when it changes sides.
    public mutating func seat(_ pad: PadID, on side: SplitSide) {
        if sides[pad] == nil { order.append(pad) }
        sides[pad] = side
    }

    public mutating func unseat(_ pad: PadID) {
        sides[pad] = nil
        order.removeAll { $0 == pad }
    }

    public mutating func keep(only live: Set<PadID>) {
        for pad in order where !live.contains(pad) { unseat(pad) }
    }

    /// The side an A press joins: the direction held along the layout's axis, otherwise the side
    /// with fewer players, `first` on a tie.
    public func joinSide(for direction: StickDirection, stacked: Bool) -> SplitSide {
        switch (direction, stacked) {
        case (.left, false), (.up, true): .first
        case (.right, false), (.down, true): .second
        default: count(on: .second) < count(on: .first) ? .second : .first
        }
    }
}
