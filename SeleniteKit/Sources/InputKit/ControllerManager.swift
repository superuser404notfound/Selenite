import MoonlightCore
import QuartzCore

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

@MainActor
public final class ControllerManager {
    private weak var sink: (any ControllerEventSink)?
    private let onOverlay: @MainActor () -> Void
    private var roster = ControllerRoster()
    private var controllers: [UInt8: GCController] = [:]
    private var combos: [UInt8: ComboHoldDetector] = [:]
    private var comboTimers: [UInt8: Task<Void, Never>] = [:]
    private var touching: [UInt8: Bool] = [:]
    private var observers: [NSObjectProtocol] = []

    public init(sink: any ControllerEventSink, onOverlay: @escaping @MainActor () -> Void) {
        self.sink = sink
        self.onOverlay = onOverlay
    }

    /// Idempotent: a second call while already observing is a no-op.
    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Connect re-scans rather than reads `note.object`: a Notification is not Sendable, so
        // reaching into it from the main-actor hop is a data race the compiler rightly refuses.
        // The controller list is the same answer and costs nothing at this frequency (matches the
        // pattern already established in Sodalite's SiriRemoteSurfaceTracker for the same reason).
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
        })
        // Disconnect cannot rely on the same rescan: whether GCController.controllers() still lists
        // the controller by the time this notification is delivered is undocumented, so a rescan-based
        // release can miss it. The identity is read synchronously here, before the hop (ObjectIdentifier
        // is Sendable even though the Notification and the GCController it wraps are not), and release
        // is driven directly from it regardless of what the live list says.
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? GCController).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let id else { return }
                self?.disconnect(id: id)
            }
        })
        refreshControllers()
    }

    /// Diffs `GCController.controllers()` against what is currently tracked and connects anything new.
    /// Also releases anything that vanished without a disconnect notification, as a defensive backstop;
    /// the disconnect notification itself never depends on this rescan (see `start()`).
    private func refreshControllers() {
        let connected = GCController.controllers()
        let liveIDs = Set(connected.map(ObjectIdentifier.init))
        for controller in Array(controllers.values) where !liveIDs.contains(ObjectIdentifier(controller)) {
            disconnect(id: ObjectIdentifier(controller))
        }
        let trackedIDs = Set(controllers.values.map(ObjectIdentifier.init))
        for controller in connected where !trackedIDs.contains(ObjectIdentifier(controller)) {
            connect(controller)
        }
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in controllers.values { controller.extendedGamepad?.valueChangedHandler = nil }
        for timer in comboTimers.values { timer.cancel() }
        comboTimers.removeAll()
        controllers.removeAll()
        combos.removeAll()
        touching.removeAll()
        roster = ControllerRoster()
    }

    public func controller(number: UInt8) -> GCController? { controllers[number] }

    /// Re-sends `controllerArrived` for every tracked controller with the current mask. Arrival
    /// events sent before the session reports connected are dropped by the host, so the caller
    /// (Task 13) calls this once the session is actually connected.
    public func reannounce() {
        for (number, controller) in controllers {
            sink?.controllerArrived(number: number, mask: roster.mask, kind: Self.kind(of: controller))
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
        let kind = Self.kind(of: controller)
        sink?.controllerArrived(number: number, mask: roster.mask, kind: kind)
        gamepad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated { self?.send(pad, number: number) }
        }
        send(gamepad, number: number)
    }

    private func disconnect(id: ObjectIdentifier) {
        guard let number = roster.disconnect(id: id) else { return }
        // A departed controller object can outlive this call; its handler must not keep sending.
        controllers[number]?.extendedGamepad?.valueChangedHandler = nil
        controllers[number] = nil
        combos[number] = nil
        touching[number] = nil
        cancelComboTimer(number: number)
        for event in ControllerRoster.releaseEvents(number: number, remainingMask: roster.mask) {
            sink?.controllerState(number: number, mask: event.mask, state: event.state)
        }
    }

    private func send(_ pad: GCExtendedGamepad, number: UInt8) {
        let snapshot = Self.snapshot(of: pad)
        let pressed = snapshot.menu && snapshot.options
        var combo = combos[number] ?? ComboHoldDetector()
        let overlay = combo.update(pressed: pressed, now: CACurrentMediaTime())
        combos[number] = combo
        if pressed {
            scheduleComboTimer(number: number, holdSeconds: combo.holdSeconds)
        } else {
            cancelComboTimer(number: number)
        }
        if overlay {
            onOverlay()
            // The combo held Start+Select down in the stream's view of the pad; without this the
            // game keeps seeing them held after the overlay takes the input.
            sink?.controllerState(number: number, mask: roster.mask, state: GamepadState())
            return
        }
        sink?.controllerState(number: number, mask: roster.mask, state: GamepadMapper.state(from: snapshot))
        if let touchpad = Self.touchpad(of: pad) {
            sendTouch(touchpad, number: number)
        }
    }

    /// `valueChangedHandler` only fires on an input change, so holding the combo perfectly still
    /// never re-checks the hold threshold. This one-shot timer, (re)armed whenever the combo becomes
    /// pressed and cancelled on release/disconnect/stop, re-evaluates it directly off the pad's
    /// current button state instead of waiting for another event.
    private func scheduleComboTimer(number: UInt8, holdSeconds: Double) {
        guard comboTimers[number] == nil else { return }
        comboTimers[number] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(holdSeconds))
            guard !Task.isCancelled else { return }
            self?.checkComboTimeout(number: number)
        }
    }

    private func cancelComboTimer(number: UInt8) {
        comboTimers[number]?.cancel()
        comboTimers[number] = nil
    }

    private func checkComboTimeout(number: UInt8) {
        comboTimers[number] = nil
        guard let pad = controllers[number]?.extendedGamepad else { return }
        let pressed = pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed ?? false)
        var combo = combos[number] ?? ComboHoldDetector()
        let overlay = combo.update(pressed: pressed, now: CACurrentMediaTime())
        combos[number] = combo
        guard overlay else { return }
        onOverlay()
        sink?.controllerState(number: number, mask: roster.mask, state: GamepadState())
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
    /// position as a finger on the pad. Device-verified in Task 14.
    private func sendTouch(_ pad: GCControllerDirectionPad, number: UInt8) {
        let x = pad.xAxis.value, y = pad.yAxis.value
        let down = x != 0 || y != 0
        let was = touching[number] ?? false
        guard down || was else { return }
        let event = down ? (was ? UInt8(LI_TOUCH_EVENT_MOVE) : UInt8(LI_TOUCH_EVENT_DOWN)) : UInt8(LI_TOUCH_EVENT_UP)
        touching[number] = down
        sink?.controllerTouch(number: number, event: event, pointer: 0, x: (x + 1) / 2, y: (1 - y) / 2, pressure: down ? 1 : 0)
    }
}
#endif
