import MoonlightCore

public enum ControllerKind: Sendable, Equatable {
    case xbox, dualSense, dualShock4, generic

    public var moonlightType: UInt8 {
        switch self {
        case .xbox: UInt8(LI_CTYPE_XBOX)
        case .dualSense, .dualShock4: UInt8(LI_CTYPE_PS)
        case .generic: UInt8(LI_CTYPE_UNKNOWN)
        }
    }

    public var capabilities: UInt16 {
        // No LI_CCAP_BATTERY_STATE: battery reporting is not implemented in M1-A.
        let base = UInt16(LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE)
        switch self {
        case .xbox: return base | UInt16(LI_CCAP_TRIGGER_RUMBLE)
        case .dualSense, .dualShock4: return base | UInt16(LI_CCAP_TOUCHPAD | LI_CCAP_ACCEL | LI_CCAP_GYRO | LI_CCAP_RGB_LED)
        case .generic: return UInt16(LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE)
        }
    }

    public var supportedButtons: UInt32 {
        let base = UInt32(A_FLAG | B_FLAG | X_FLAG | Y_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG
                          | LB_FLAG | RB_FLAG | PLAY_FLAG | BACK_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | SPECIAL_FLAG)
        switch self {
        case .xbox: return base | UInt32(MISC_FLAG | PADDLE1_FLAG | PADDLE2_FLAG | PADDLE3_FLAG | PADDLE4_FLAG)
        case .dualSense: return base | UInt32(TOUCHPAD_FLAG | MISC_FLAG)
        case .dualShock4: return base | UInt32(TOUCHPAD_FLAG)
        case .generic: return base
        }
    }
}
