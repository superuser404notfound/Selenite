/// Everything `ControllerManager` sends to the host passes through here, so pausing (the stream
/// overlay owns the input), releasing and stopping are decided in one place that runs without
/// GameController. Arrival events are not input and always go out.
@MainActor
public final class ControllerForwarder {
    private weak var sink: (any ControllerEventSink)?
    private var latest: [UInt8: GamepadState] = [:]
    private var mask: UInt16 = 0
    /// Buttons each controller held when forwarding resumed (the press that closed the overlay,
    /// for one). They stay off the host until that controller releases them.
    private var heldAtResume: [UInt8: Int32] = [:]
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
        sink?.controllerState(number: number, mask: mask, state: masked(number: number, state))
    }

    private func masked(number: UInt8, _ state: GamepadState) -> GamepadState {
        guard let held = heldAtResume[number] else { return state }
        let still = held & state.buttons
        heldAtResume[number] = still == 0 ? nil : still
        var out = state
        out.buttons &= ~still
        return out
    }

    /// Keeps `buttons` off the host until the controller releases them, as if they were held at a
    /// resume: a pad seated on a running split side arrives with the press that seated it.
    public func maskUntilReleased(number: UInt8, buttons: Int32) {
        guard buttons != 0 else { return }
        heldAtResume[number, default: 0] |= buttons
    }

    public func touch(number: UInt8, event: UInt8, pointer: UInt32, x: Float, y: Float, pressure: Float) {
        guard isForwarding else { return }
        sink?.controllerTouch(number: number, event: event, pointer: pointer, x: x, y: y, pressure: pressure)
    }

    /// A disconnect: the two-step release from `ControllerRoster`, sent even while paused, because
    /// the mask update is what tells the host the controller left.
    public func released(number: UInt8, remainingMask: UInt16) {
        latest[number] = nil
        heldAtResume[number] = nil
        mask = remainingMask
        for event in ControllerRoster.releaseEvents(number: number, remainingMask: remainingMask) {
            sink?.controllerState(number: number, mask: event.mask, state: event.state)
        }
    }

    /// Pausing sends one neutral state per controller, so nothing stays held on the host while the
    /// overlay has the input; resuming sends each controller's current axes and triggers, with
    /// every button it holds at that moment masked until released, so the press that closed the
    /// overlay never reaches the game.
    public func setForwarding(_ forwarding: Bool) {
        guard forwarding != isForwarding else { return }
        isForwarding = forwarding
        heldAtResume.removeAll()
        for number in latest.keys.sorted() {
            var state = GamepadState()
            if forwarding, let current = latest[number] {
                if current.buttons != 0 { heldAtResume[number] = current.buttons }
                state = masked(number: number, current)
            }
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
        heldAtResume.removeAll()
        mask = 0
        isForwarding = true
    }
}
