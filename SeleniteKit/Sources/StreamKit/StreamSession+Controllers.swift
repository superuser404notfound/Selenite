import InputKit
import MoonlightCore

extension StreamSession: ControllerEventSink {
    public func controllerArrived(number: UInt8, mask: UInt16, kind: ControllerKind) {
        guard lifecycle.isConnected else { return }
        _ = slot.api.sendControllerArrivalEvent!(number, mask, kind.moonlightType, kind.supportedButtons, kind.capabilities)
    }

    public func controllerState(number: UInt8, mask: UInt16, state: GamepadState) {
        guard lifecycle.isConnected else { return }
        _ = slot.api.sendMultiControllerEvent!(Int16(number), Int16(bitPattern: mask), state.buttons,
                                               state.leftTrigger, state.rightTrigger,
                                               state.leftX, state.leftY, state.rightX, state.rightY)
    }

    public func controllerTouch(number: UInt8, event: UInt8, pointer: UInt32, x: Float, y: Float, pressure: Float) {
        guard lifecycle.isConnected else { return }
        _ = slot.api.sendControllerTouchEvent!(number, event, pointer, x, y, pressure)
    }

    public func controllerMotion(number: UInt8, type: UInt8, x: Float, y: Float, z: Float) {
        guard lifecycle.isConnected else { return }
        _ = slot.api.sendControllerMotionEvent!(number, type, x, y, z)
    }

    public func controllerBattery(number: UInt8, state: UInt8, percent: UInt8) {
        guard lifecycle.isConnected else { return }
        _ = slot.api.sendControllerBatteryEvent!(number, state, percent)
    }
}
