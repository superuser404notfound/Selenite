import MoonlightCore
import Testing
@testable import InputKit

@Test func buttonsMapToMoonlightFlags() {
    var s = GamepadSnapshot()
    s.a = true; s.leftShoulder = true; s.menu = true; s.options = true; s.home = true; s.up = true; s.touchpadButton = true
    let state = GamepadMapper.state(from: s)
    #expect(state.buttons == Int32(A_FLAG | LB_FLAG | PLAY_FLAG | BACK_FLAG | SPECIAL_FLAG | UP_FLAG | TOUCHPAD_FLAG))
}

@Test func triggersScaleToByteRange() {
    var s = GamepadSnapshot()
    s.leftTrigger = 1; s.rightTrigger = 0.5
    let state = GamepadMapper.state(from: s)
    #expect(state.leftTrigger == 255)
    #expect(state.rightTrigger == 128)
}

@Test func sticksScaleWithoutInvertingY() {
    var s = GamepadSnapshot()
    s.leftX = 1; s.leftY = 1; s.rightX = -1; s.rightY = -0.5
    let state = GamepadMapper.state(from: s)
    #expect(state.leftX == 32767 && state.leftY == 32767)
    #expect(state.rightX == -32767 && state.rightY == -16384)
}

@Test func outOfRangeInputIsClamped() {
    var s = GamepadSnapshot()
    s.leftX = 1.7; s.leftTrigger = -0.2
    let state = GamepadMapper.state(from: s)
    #expect(state.leftX == 32767 && state.leftTrigger == 0)
}

@Test func kindsAnnounceTheirFeatures() {
    #expect(ControllerKind.xbox.moonlightType == UInt8(LI_CTYPE_XBOX))
    #expect(ControllerKind.dualSense.moonlightType == UInt8(LI_CTYPE_PS))
    #expect(ControllerKind.dualSense.capabilities & UInt16(LI_CCAP_TOUCHPAD | LI_CCAP_GYRO | LI_CCAP_ACCEL | LI_CCAP_RGB_LED) != 0)
    #expect(ControllerKind.xbox.capabilities & UInt16(LI_CCAP_TRIGGER_RUMBLE) != 0)
    #expect(ControllerKind.xbox.capabilities & UInt16(LI_CCAP_TOUCHPAD) == 0)
}
