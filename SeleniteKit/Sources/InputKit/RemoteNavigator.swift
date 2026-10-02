/// The Siri Remote as a menu remote for a cursor that is not UIKit focus (the split overlay): a
/// swipe moves one step per `swipeStep` of travel, a click on the edge of the surface moves one
/// step that way, a click in the middle selects, as tvOS does for focus.
///
/// Samples are absolute positions (`reportsAbsoluteDpadValues`), -1...1 with y up. A sample with
/// either axis exactly 0 is the edge of a touch, never a position (see `RemotePointer`).
public struct RemoteNavigator: Sendable {
    public enum Event: Sendable, Equatable {
        case move(StickDirection)
        case select
    }

    /// Surface units of travel per step; the surface is 2 units wide.
    public static let swipeStep: Float = 0.5
    /// A click this far from the centre on the dominant axis is a directional click.
    public static let edgeClick: Float = 0.5

    private var anchor: (x: Float, y: Float)?
    private var position: (x: Float, y: Float)?
    private var isClicked = false

    public init() {}

    public mutating func touch(x: Float, y: Float) -> [Event] {
        guard x != 0, y != 0 else {
            if x == 0, y == 0 { anchor = nil; position = nil }
            return []
        }
        position = (x, y)
        guard !isClicked, let anchor else {
            anchor = (x, y)
            return []
        }
        let dx = x - anchor.x, dy = y - anchor.y
        guard max(abs(dx), abs(dy)) >= Self.swipeStep else { return [] }
        self.anchor = (x, y)
        return [.move(Self.direction(dx: dx, dy: dy))]
    }

    /// Acts on the press, like a focus click; the release only lets swiping resume.
    public mutating func click(pressed: Bool) -> [Event] {
        isClicked = pressed
        guard pressed else {
            anchor = position.map { (x: $0.x, y: $0.y) }
            return []
        }
        guard let position, max(abs(position.x), abs(position.y)) >= Self.edgeClick else { return [.select] }
        return [.move(Self.direction(dx: position.x, dy: position.y))]
    }

    private static func direction(dx: Float, dy: Float) -> StickDirection {
        abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
    }
}
