import Foundation
import InputKit
import MoonlightCore

/// Every send runs inside `whileConnected`, so a stop cannot release the slot mid-send.
extension StreamSession: ControllerEventSink {
    public func controllerArrived(number: UInt8, mask: UInt16, kind: ControllerKind) {
        let result = lifecycle.whileConnected {
            slot.api.sendControllerArrivalEvent!(number, mask, kind.moonlightType, kind.supportedButtons, kind.capabilities)
        }
        if let result {
            NSLog("[Selenite] controller %d arrived as %@ on slot %@: send returned %d",
                  Int32(number), String(describing: kind), String(describing: slot), result)
        } else {
            NSLog("[Selenite] controller %d arrived as %@ on slot %@: not sent, session not connected",
                  Int32(number), String(describing: kind), String(describing: slot))
        }
    }

    public func controllerState(number: UInt8, mask: UInt16, state: GamepadState) {
        _ = lifecycle.whileConnected {
            slot.api.sendMultiControllerEvent!(Int16(number), Int16(bitPattern: mask), state.buttons,
                                               state.leftTrigger, state.rightTrigger,
                                               state.leftX, state.leftY, state.rightX, state.rightY)
        }
    }

    public func controllerTouch(number: UInt8, event: UInt8, pointer: UInt32, x: Float, y: Float, pressure: Float) {
        _ = lifecycle.whileConnected { slot.api.sendControllerTouchEvent!(number, event, pointer, x, y, pressure) }
    }

    public func controllerMotion(number: UInt8, type: UInt8, x: Float, y: Float, z: Float) {
        _ = lifecycle.whileConnected { slot.api.sendControllerMotionEvent!(number, type, x, y, z) }
    }

    public func controllerBattery(number: UInt8, state: UInt8, percent: UInt8) {
        _ = lifecycle.whileConnected { slot.api.sendControllerBatteryEvent!(number, state, percent) }
    }
}
