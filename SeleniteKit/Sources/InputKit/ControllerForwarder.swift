/// Everything `ControllerManager` sends to the host passes through here, so pausing (the stream
/// overlay owns the input), releasing and stopping are decided in one place that runs without
/// GameController. Arrival events are not input and always go out.
@MainActor
public final class ControllerForwarder {
    private weak var sink: (any ControllerEventSink)?
    private var latest: [UInt8: GamepadState] = [:]
    private var mask: UInt16 = 0
    public private(set) var isForwarding = true

    public init(sink: any ControllerEventSink) {
        self.sink = sink
    }

    public func arrived(number: UInt8, mask: UInt16, kind: ControllerKind) {
        self.mask = mask
        if latest[number] == nil { latest[number] = GamepadState() }
        sink?.controllerArrived(number: number, mask: mask, kind: kind)
    }

    /// Always remembered, sent only while forwarding: resuming sends what the pad holds then.
    public func state(number: UInt8, mask: UInt16, state: GamepadState) {
        self.mask = mask
        latest[number] = state
        guard isForwarding else { return }
        sink?.controllerState(number: number, mask: mask, state: state)
    }

    public func touch(number: UInt8, event: UInt8, pointer: UInt32, x: Float, y: Float, pressure: Float) {
        guard isForwarding else { return }
        sink?.controllerTouch(number: number, event: event, pointer: pointer, x: x, y: y, pressure: pressure)
    }

    /// A disconnect: the two-step release from `ControllerRoster`, sent even while paused, because
    /// the mask update is what tells the host the controller left.
    public func released(number: UInt8, remainingMask: UInt16) {
        latest[number] = nil
        mask = remainingMask
        for event in ControllerRoster.releaseEvents(number: number, remainingMask: remainingMask) {
            sink?.controllerState(number: number, mask: event.mask, state: event.state)
        }
    }

    /// Pausing sends one neutral state per controller, so nothing stays held on the host while the
    /// overlay has the input; resuming sends each controller's current state.
    public func setForwarding(_ forwarding: Bool) {
        guard forwarding != isForwarding else { return }
        isForwarding = forwarding
        for number in latest.keys.sorted() {
            let state = forwarding ? (latest[number] ?? GamepadState()) : GamepadState()
            sink?.controllerState(number: number, mask: mask, state: state)
        }
    }

    /// Stop: every controller lifts its buttons and leaves the mask, lowest number first. Leaves
    /// the forwarder empty and forwarding, ready for a later start.
    public func releaseAll() {
        var remaining = mask
        for number in latest.keys.sorted() {
            remaining &= ~(UInt16(1) << UInt16(number))
            for event in ControllerRoster.releaseEvents(number: number, remainingMask: remaining) {
                sink?.controllerState(number: number, mask: event.mask, state: event.state)
            }
        }
        latest.removeAll()
        mask = 0
        isForwarding = true
    }
}
