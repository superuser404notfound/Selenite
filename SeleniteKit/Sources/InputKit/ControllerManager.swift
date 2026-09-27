import MoonlightCore

/// Assigns each connected controller the lowest free number 0...15 and tracks the active mask,
/// independent of GameController so it is testable on every platform.
public struct ControllerRoster: Sendable {
    private var numbers: [ObjectIdentifier: UInt8] = [:]
    public init() {}
    public mutating func connect(id: ObjectIdentifier) -> UInt8 {
        if let existing = numbers[id] { return existing }
        let used = Set(numbers.values)
        let number = (0..<16).map(UInt8.init).first { !used.contains($0) } ?? 15
        numbers[id] = number
        return number
    }
    public mutating func disconnect(id: ObjectIdentifier) -> UInt8? { numbers.removeValue(forKey: id) }
    public func number(for id: ObjectIdentifier) -> UInt8? { numbers[id] }
    public var mask: UInt16 { numbers.values.reduce(0) { $0 | (1 << UInt16($1)) } }

    /// The two-step release for a controller that just disconnected: a neutral state while it is
    /// still advertised in the mask, so the host sees every button lift before the controller
    /// leaves it, then the same neutral state under the mask with its bit cleared.
    public static func releaseEvents(number: UInt8, remainingMask: UInt16) -> [(mask: UInt16, state: GamepadState)] {
        [(remainingMask | (1 << UInt16(number)), GamepadState()), (remainingMask, GamepadState())]
    }
}

#if os(tvOS)
import GameController

/// Observes GameController, numbers the pads and forwards their input through a
/// `ControllerForwarder`. Start+Select is an ordinary button pair here: only the Siri Remote
/// controls the stream (M1-B spec, section 2), and it never reaches this class.
@MainActor
public final class ControllerManager {
    private let forwarder: ControllerForwarder
    private var roster = ControllerRoster()
    private var ledger = DisconnectLedger()
    private var controllers: [UInt8: GCController] = [:]
    private var touching: [UInt8: Bool] = [:]
    private var observers: [NSObjectProtocol] = []

    public init(sink: any ControllerEventSink) {
        forwarder = ControllerForwarder(sink: sink)
    }

    /// False while the stream overlay owns the input. Pausing sends one neutral state per
    /// controller, resuming sends each controller's current state.
    public var isForwarding: Bool {
        get { forwarder.isForwarding }
        set { forwarder.setForwarding(newValue) }
    }

    /// Idempotent: a second call while already observing is a no-op.
    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Both observers read the controller's identity synchronously, before the main-actor hop:
        // a Notification and the GCController it wraps are not Sendable, ObjectIdentifier is.
        // A connect clears a ledger entry for that controller, then rescans.
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? GCController).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if let id { self?.ledger.markReconnected(id) }
                self?.refreshControllers()
            }
        })
        // Disconnect cannot rely on a rescan: whether GCController.controllers() still lists the
        // controller when this notification arrives is undocumented, so release is driven directly
        // from the notification's identity.
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? GCController).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let id else { return }
                self?.disconnect(id: id)
            }
        })
        refreshControllers()
    }

    /// Diffs `GCController.controllers()` against what is tracked: releases anything that vanished
    /// without a notification, connects anything new that the ledger does not mark as a ghost.
    private func refreshControllers() {
        let connected = GCController.controllers()
        let liveIDs = Set(connected.map(ObjectIdentifier.init))
        for controller in Array(controllers.values) where !liveIDs.contains(ObjectIdentifier(controller)) {
            disconnect(id: ObjectIdentifier(controller))
        }
        let tracked = Set(controllers.values.map(ObjectIdentifier.init))
        let admitted = Set(ledger.admissible(live: connected.map(ObjectIdentifier.init), tracked: tracked))
        for controller in connected where admitted.contains(ObjectIdentifier(controller)) {
            connect(controller)
        }
    }

    /// Releases every controller on the host (M1-A ledger minor: stop() used to send nothing), then
    /// forgets them.
    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in controllers.values { controller.extendedGamepad?.valueChangedHandler = nil }
        forwarder.releaseAll()
        controllers.removeAll()
        touching.removeAll()
        roster = ControllerRoster()
        ledger = DisconnectLedger()
    }

    public func controller(number: UInt8) -> GCController? { controllers[number] }

    /// Re-sends `controllerArrived` and the current state for every tracked controller. Arrival
    /// events sent before the session reports connected are dropped by the host, so the caller
    /// calls this once the session is connected.
    public func reannounce() {
        for (number, controller) in controllers.sorted(by: { $0.key < $1.key }) {
            forwarder.arrived(number: number, mask: roster.mask, kind: Self.kind(of: controller))
            if let pad = controller.extendedGamepad {
                forwarder.state(number: number, mask: roster.mask, state: GamepadMapper.state(from: Self.snapshot(of: pad)))
            }
        }
    }

    static func kind(of controller: GCController) -> ControllerKind {
        switch controller.extendedGamepad {
        case is GCDualSenseGamepad: .dualSense
        case is GCDualShockGamepad: .dualShock4
        case is GCXboxGamepad: .xbox
        default: .generic
        }
    }

    private func connect(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }   // Siri Remote stays with the UI
        let number = roster.connect(id: ObjectIdentifier(controller))
        controllers[number] = controller
        controller.playerIndex = GCControllerPlayerIndex(rawValue: Int(number)) ?? .indexUnset
        forwarder.arrived(number: number, mask: roster.mask, kind: Self.kind(of: controller))
        gamepad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated { self?.send(pad, number: number) }
        }
        send(gamepad, number: number)
    }

    private func disconnect(id: ObjectIdentifier) {
        guard let number = roster.disconnect(id: id) else { return }
        ledger.markReleased(id)
        // A departed controller object can outlive this call; its handler must not keep sending.
        controllers[number]?.extendedGamepad?.valueChangedHandler = nil
        controllers[number] = nil
        touching[number] = nil
        forwarder.released(number: number, remainingMask: roster.mask)
    }

    private func send(_ pad: GCExtendedGamepad, number: UInt8) {
        forwarder.state(number: number, mask: roster.mask, state: GamepadMapper.state(from: Self.snapshot(of: pad)))
        if let touchpad = Self.touchpad(of: pad) {
            sendTouch(touchpad, number: number)
        }
    }

    static func snapshot(of pad: GCExtendedGamepad) -> GamepadSnapshot {
        var s = GamepadSnapshot()
        s.a = pad.buttonA.isPressed; s.b = pad.buttonB.isPressed; s.x = pad.buttonX.isPressed; s.y = pad.buttonY.isPressed
        s.leftShoulder = pad.leftShoulder.isPressed; s.rightShoulder = pad.rightShoulder.isPressed
        s.leftThumb = pad.leftThumbstickButton?.isPressed ?? false; s.rightThumb = pad.rightThumbstickButton?.isPressed ?? false
        s.menu = pad.buttonMenu.isPressed; s.options = pad.buttonOptions?.isPressed ?? false; s.home = pad.buttonHome?.isPressed ?? false
        s.up = pad.dpad.up.isPressed; s.down = pad.dpad.down.isPressed; s.left = pad.dpad.left.isPressed; s.right = pad.dpad.right.isPressed
        s.leftTrigger = pad.leftTrigger.value; s.rightTrigger = pad.rightTrigger.value
        s.leftX = pad.leftThumbstick.xAxis.value; s.leftY = pad.leftThumbstick.yAxis.value
        s.rightX = pad.rightThumbstick.xAxis.value; s.rightY = pad.rightThumbstick.yAxis.value
        switch pad {
        case let ds as GCDualSenseGamepad: s.touchpadButton = ds.touchpadButton.isPressed
        case let ds4 as GCDualShockGamepad: s.touchpadButton = ds4.touchpadButton.isPressed
        case let xbox as GCXboxGamepad:
            s.misc = xbox.buttonShare?.isPressed ?? false
            s.paddle1 = xbox.paddleButton1?.isPressed ?? false; s.paddle2 = xbox.paddleButton2?.isPressed ?? false
            s.paddle3 = xbox.paddleButton3?.isPressed ?? false; s.paddle4 = xbox.paddleButton4?.isPressed ?? false
        default: break
        }
        return s
    }

    static func touchpad(of pad: GCExtendedGamepad) -> GCControllerDirectionPad? {
        (pad as? GCDualSenseGamepad)?.touchpadPrimary ?? (pad as? GCDualShockGamepad)?.touchpadPrimary
    }

    /// GameController reports no touch state, only a position that rests at (0, 0): treat any other
    /// position as a finger on the pad (M1-A device round).
    private func sendTouch(_ pad: GCControllerDirectionPad, number: UInt8) {
        let x = pad.xAxis.value, y = pad.yAxis.value
        let down = x != 0 || y != 0
        let was = touching[number] ?? false
        guard down || was else { return }
        let event = down ? (was ? UInt8(LI_TOUCH_EVENT_MOVE) : UInt8(LI_TOUCH_EVENT_DOWN)) : UInt8(LI_TOUCH_EVENT_UP)
        touching[number] = down
        forwarder.touch(number: number, event: event, pointer: 0, x: (x + 1) / 2, y: (1 - y) / 2, pressure: down ? 1 : 0)
    }
}
#endif
