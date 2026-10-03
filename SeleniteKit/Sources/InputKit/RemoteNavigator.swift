/// The Siri Remote's touch surface as a menu remote for a cursor that is not UIKit focus (the split
/// overlay): a swipe moves one step per `swipeStep` of travel, a click selects. A click on the
/// surface's edge never comes through here: tvOS delivers it only as a UIKit arrow press
/// (measured on device 2026-10-02), so the split container handles those.
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
        return [.select]
    }

    private static func direction(dx: Float, dy: Float) -> StickDirection {
        abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
    }
}
