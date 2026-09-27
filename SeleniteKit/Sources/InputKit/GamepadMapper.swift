import MoonlightCore

public struct GamepadState: Sendable, Equatable {
    public var buttons: Int32 = 0
    public var leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0
    public var leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0
    public init() {}
}

public enum GamepadMapper {
    public static func state(from s: GamepadSnapshot) -> GamepadState {
        var flags: Int32 = 0
        func set(_ on: Bool, _ flag: Int32) { if on { flags |= flag } }
        set(s.a, Int32(A_FLAG)); set(s.b, Int32(B_FLAG)); set(s.x, Int32(X_FLAG)); set(s.y, Int32(Y_FLAG))
        set(s.leftShoulder, Int32(LB_FLAG)); set(s.rightShoulder, Int32(RB_FLAG))
        set(s.leftThumb, Int32(LS_CLK_FLAG)); set(s.rightThumb, Int32(RS_CLK_FLAG))
        set(s.menu, Int32(PLAY_FLAG)); set(s.options, Int32(BACK_FLAG)); set(s.home, Int32(SPECIAL_FLAG))
        set(s.up, Int32(UP_FLAG)); set(s.down, Int32(DOWN_FLAG)); set(s.left, Int32(LEFT_FLAG)); set(s.right, Int32(RIGHT_FLAG))
        set(s.touchpadButton, Int32(TOUCHPAD_FLAG)); set(s.misc, Int32(MISC_FLAG))
        set(s.paddle1, Int32(PADDLE1_FLAG)); set(s.paddle2, Int32(PADDLE2_FLAG))
        set(s.paddle3, Int32(PADDLE3_FLAG)); set(s.paddle4, Int32(PADDLE4_FLAG))
        var state = GamepadState()
        state.buttons = flags
        state.leftTrigger = trigger(s.leftTrigger); state.rightTrigger = trigger(s.rightTrigger)
        state.leftX = axis(s.leftX); state.leftY = axis(s.leftY)
        state.rightX = axis(s.rightX); state.rightY = axis(s.rightY)
        return state
    }

    static func trigger(_ v: Float) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
    static func axis(_ v: Float) -> Int16 { Int16((min(max(v, -1), 1) * 32767).rounded()) }
}
