/// Destination for everything `ControllerManager` observes: arrival, per-frame state, touch,
/// motion and battery. `StreamSession` conforms to this to forward events into its slot.
public protocol ControllerEventSink: AnyObject, Sendable {
    func controllerArrived(number: UInt8, mask: UInt16, kind: ControllerKind)
    func controllerState(number: UInt8, mask: UInt16, state: GamepadState)
    func controllerTouch(number: UInt8, event: UInt8, pointer: UInt32, x: Float, y: Float, pressure: Float)
    func controllerMotion(number: UInt8, type: UInt8, x: Float, y: Float, z: Float)
    func controllerBattery(number: UInt8, state: UInt8, percent: UInt8)
}
