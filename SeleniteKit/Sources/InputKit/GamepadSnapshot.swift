/// Plain copy of a controller's inputs, decoupled from GameController so the mapping is testable.
public struct GamepadSnapshot: Sendable, Equatable {
    public var a = false, b = false, x = false, y = false
    public var leftShoulder = false, rightShoulder = false, leftThumb = false, rightThumb = false
    public var menu = false, options = false, home = false
    public var up = false, down = false, left = false, right = false
    public var touchpadButton = false, misc = false
    public var paddle1 = false, paddle2 = false, paddle3 = false, paddle4 = false
    public var leftTrigger: Float = 0, rightTrigger: Float = 0
    public var leftX: Float = 0, leftY: Float = 0, rightX: Float = 0, rightY: Float = 0
    public init() {}
}
