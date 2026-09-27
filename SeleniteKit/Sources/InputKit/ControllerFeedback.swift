#if os(tvOS)
import CoreHaptics
import Foundation
import GameController
import MoonlightCore
import QuartzCore
import Synchronization

@MainActor
public final class ControllerFeedback {
    private let manager: ControllerManager
    private var motors: [UInt8: CachedMotors] = [:]
    private var motionRates: [UInt8: [UInt8: UInt16]] = [:]
    // Stores the actual controller a motion handler is bound to (not just its identity), so
    // `stopAll()` can tear the handler down on the object it was set on even if `manager.controller
    // (number:)` has since started reporting a different, newer controller for that number.
    private var motionControllers: [UInt8: GCController] = [:]
    private var lastMotionSend: [UInt8: Double] = [:]
    public weak var sink: (any ControllerEventSink)?

    // Set by `stopAll()`, cleared by `resume()`. Gates every drain's apply step (not the drain
    // itself, which always runs so a store's dirty bit never gets stuck) so a feedback call that
    // was already in flight, or one that arrives from a stray/late packet after the stream ended,
    // cannot rebuild an engine or start a player after teardown.
    private var stopped = false

    // Each queue coalesces the nonisolated writes moonlight-common-c's callback thread makes into a
    // single main-actor apply per key, always applying whatever is newest (see `LatestValueStore`).
    private nonisolated let rumbleQueue = LatestValueStore<UInt8, RumbleValue>()
    private nonisolated let triggerRumbleQueue = LatestValueStore<UInt8, TriggerRumbleValue>()
    private nonisolated let ledQueue = LatestValueStore<UInt8, LEDValue>()
    private nonisolated let adaptiveTriggerQueue = LatestValueStore<AdaptiveTriggerKey, AdaptiveTriggerCommand>()
    private nonisolated let motionQueue = LatestValueStore<MotionKey, UInt16>()

    public init(manager: ControllerManager) { self.manager = manager }

    nonisolated public func rumble(controller: UInt16, low: UInt16, high: UInt16) {
        let number = UInt8(truncatingIfNeeded: controller)
        guard rumbleQueue.write(RumbleValue(low: low, high: high), for: number) else { return }
        Task { @MainActor in
            guard let value = self.rumbleQueue.drain(for: number) else { return }
            guard !self.stopped else { return }
            self.motorsFor(number)?.set(low: value.low, high: value.high)
        }
    }
    nonisolated public func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {
        let number = UInt8(truncatingIfNeeded: controller)
        guard triggerRumbleQueue.write(TriggerRumbleValue(left: left, right: right), for: number) else { return }
        Task { @MainActor in
            guard let value = self.triggerRumbleQueue.drain(for: number) else { return }
            guard !self.stopped else { return }
            self.motorsFor(number)?.setTriggers(left: value.left, right: value.right)
        }
    }
    nonisolated public func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        let number = UInt8(truncatingIfNeeded: controller)
        guard ledQueue.write(LEDValue(r: r, g: g, b: b), for: number) else { return }
        Task { @MainActor in
            guard let value = self.ledQueue.drain(for: number) else { return }
            guard !self.stopped else { return }
            self.manager.controller(number: number)?.light?.color =
                GCColor(red: Float(value.r) / 255, green: Float(value.g) / 255, blue: Float(value.b) / 255)
        }
    }
    // Each side coalesces independently, keyed by (number, side). A single shared "whole command"
    // slot (the previous design) let a left-only command and a right-only command that both landed
    // in the same drain window replace each other, so one side's request was silently lost even
    // though neither write was itself stale.
    nonisolated public func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {
        let number = UInt8(truncatingIfNeeded: controller)
        if eventFlags & UInt8(DS_EFFECT_LEFT_TRIGGER) != 0 {
            scheduleAdaptiveTrigger(number: number, side: .left, type: typeLeft, payload: left)
        }
        if eventFlags & UInt8(DS_EFFECT_RIGHT_TRIGGER) != 0 {
            scheduleAdaptiveTrigger(number: number, side: .right, type: typeRight, payload: right)
        }
    }
    nonisolated private func scheduleAdaptiveTrigger(number: UInt8, side: AdaptiveTriggerSide, type: UInt8, payload: [UInt8]) {
        let key = AdaptiveTriggerKey(number: number, side: side)
        guard adaptiveTriggerQueue.write(AdaptiveTriggerCommand(type: type, payload: payload), for: key) else { return }
        Task { @MainActor in
            guard let command = self.adaptiveTriggerQueue.drain(for: key) else { return }
            guard !self.stopped else { return }
            self.applyAdaptiveTrigger(number: number, side: side, command: command)
        }
    }
    nonisolated public func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        let number = UInt8(truncatingIfNeeded: controller)
        let key = MotionKey(number: number, type: motionType)
        guard motionQueue.write(reportRateHz, for: key) else { return }
        Task { @MainActor in
            guard let rate = self.motionQueue.drain(for: key) else { return }
            guard !self.stopped else { return }
            self.updateMotion(number: number, type: motionType, rate: rate)
        }
    }

    /// Stops every player and engine, drops every cached `RumbleMotors`, tears down every bound
    /// motion handler, and turns off any DualSense adaptive trigger effect, so nothing keeps
    /// buzzing, reporting motion, or resisting a trigger pull after the session that asked for it is
    /// gone. The lightbar is left alone: the host's last colour choice is harmless to leave showing.
    /// Also clears every coalescing queue and sets `stopped`, so a drain already scheduled before
    /// this call, or a stray feedback call that arrives after it, cannot undo the teardown; call
    /// `resume()` when a new stream starts to accept feedback again.
    public func stopAll() {
        stopped = true
        rumbleQueue.clear()
        triggerRumbleQueue.clear()
        ledQueue.clear()
        adaptiveTriggerQueue.clear()
        motionQueue.clear()
        for cached in motors.values { cached.motors.stopAll() }
        motors.removeAll()
        for controller in motionControllers.values {
            guard let motion = controller.motion else { continue }
            motion.valueChangedHandler = nil
            if motion.sensorsRequireManualActivation { motion.sensorsActive = false }
        }
        motionRates.removeAll()
        motionControllers.removeAll()
        lastMotionSend.removeAll()
        // Bounded by ControllerRoster's own 0..<16 slot range (ControllerRoster.swift), not by which
        // numbers this instance happens to have touched, so a trigger effect set before this
        // instance existed (or outside the coalescing queue entirely) still gets turned off.
        for number: UInt8 in 0..<16 {
            guard let pad = manager.controller(number: number)?.extendedGamepad as? GCDualSenseGamepad else { continue }
            pad.leftTrigger.setModeOff()
            pad.rightTrigger.setModeOff()
        }
    }

    /// Re-arms feedback after `stopAll()`. An explicit call, made by the harness when a new stream
    /// starts, rather than an implicit reset on the first feedback call after a stop: whether this
    /// instance is currently accepting feedback is then a deliberate, observable transition instead
    /// of something inferred from traffic timing.
    public func resume() {
        stopped = false
    }

    private static func apply(_ effect: AdaptiveTriggerEffect, to trigger: GCDualSenseAdaptiveTrigger) {
        switch effect {
        case .off: trigger.setModeOff()
        case .feedback(let start, let strength): trigger.setModeFeedbackWithStartPosition(start, resistiveStrength: strength)
        case .weapon(let start, let end, let strength): trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case .vibration(let start, let amplitude, let frequency): trigger.setModeVibrationWithStartPosition(start, amplitude: amplitude, frequency: frequency)
        }
    }

    private func applyAdaptiveTrigger(number: UInt8, side: AdaptiveTriggerSide, command: AdaptiveTriggerCommand) {
        guard let pad = manager.controller(number: number)?.extendedGamepad as? GCDualSenseGamepad else { return }
        let trigger = side == .left ? pad.leftTrigger : pad.rightTrigger
        Self.apply(.decode(type: command.type, payload: command.payload), to: trigger)
    }

    /// `ControllerRoster` hands a disconnected controller's number to the next one that connects, so
    /// a cache keyed only by number can silently keep serving a dead controller's haptic engines
    /// forever. Rebuilding whenever the tracked identity no longer matches `manager.controller(number:)`
    /// (instead of trusting a number-only cache hit) is what makes a swap rebuild fresh engines for
    /// the controller that is actually there now.
    private func motorsFor(_ number: UInt8) -> RumbleMotors? {
        guard let device = manager.controller(number: number) else {
            motors[number] = nil
            return nil
        }
        let identity = ObjectIdentifier(device)
        if let cached = motors[number], cached.controllerID == identity { return cached.motors }
        guard let built = RumbleMotors(controller: device, onStopped: { [weak self] in
            guard let self, self.motors[number]?.controllerID == identity else { return }
            self.motors[number] = nil
        }) else {
            motors[number] = nil
            return nil
        }
        motors[number] = CachedMotors(controllerID: identity, motors: built)
        return built
    }

    private func updateMotion(number: UInt8, type: UInt8, rate: UInt16) {
        guard let controller = manager.controller(number: number), let motion = controller.motion else { return }
        var rates = motionRates[number] ?? [:]
        rates[type] = rate == 0 ? nil : rate
        motionRates[number] = rates
        let active = !rates.isEmpty
        if motion.sensorsRequireManualActivation { motion.sensorsActive = active }
        guard active else {
            motion.valueChangedHandler = nil
            motionControllers[number] = nil
            lastMotionSend[number] = nil
            return
        }
        // ControllerRoster reuses a freed slot number for the next controller that connects, so the
        // physical controller behind `number` can change between two setMotionEventState calls.
        // `controller` above is always re-derived from `manager.controller(number:)`, never cached,
        // so binding on it here already rebinds onto whichever controller currently owns the slot.
        // The closure below additionally re-checks the identity at fire time, so a value delivered
        // late from an already-replaced controller's GCMotion (the old object lingering briefly
        // after disconnect) is dropped instead of being reported under the new controller's number.
        // Checked lazily here, on each setMotionEventState, rather than via a push from
        // ControllerManager on connect/disconnect: a new physical controller always gets a fresh
        // `controllerArrived` (`ControllerManager.connect` sends it unconditionally, even when the
        // number is reused), so a host that reacts to arrivals already re-issues setMotionEventState
        // for the new occupant of the slot, which is the simpler of the two correct options.
        let identity = ObjectIdentifier(controller)
        motionControllers[number] = controller
        let interval = 1 / Double(rates.values.max() ?? 100)
        motion.valueChangedHandler = { [weak self] m in
            MainActor.assumeIsolated {
                guard let self, self.motionControllers[number].map(ObjectIdentifier.init) == identity, let sink = self.sink else { return }
                let now = CACurrentMediaTime()
                // 10% slack: a strict >= interval throttle halves the effective rate whenever two
                // deliveries land a hair under one interval apart, which real sensor jitter does
                // constantly.
                guard now - (self.lastMotionSend[number] ?? 0) >= interval * 0.9 else { return }
                self.lastMotionSend[number] = now
                if rates[UInt8(LI_MOTION_TYPE_GYRO)] != nil {
                    let r = m.rotationRate
                    // Moonlight iOS (ControllerSupport.m): rad/s -> deg/s with a y/z swap and a sign
                    // flip on the mapped z axis. That is the SDL gyro convention Limelight.h requires
                    // from every client, not an arbitrary remapping.
                    sink.controllerMotion(number: number, type: UInt8(LI_MOTION_TYPE_GYRO),
                                          x: Float(r.x) * 57.2957795, y: Float(r.z) * 57.2957795, z: Float(r.y) * -57.2957795)
                }
                if rates[UInt8(LI_MOTION_TYPE_ACCEL)] != nil {
                    let a = m.acceleration
                    // Moonlight iOS reports the controller's total acceleration (gravity included),
                    // negated, in m/s^2: the same SDL convention, not a gravity/userAcceleration split.
                    sink.controllerMotion(number: number, type: UInt8(LI_MOTION_TYPE_ACCEL),
                                          x: Float(a.x) * -9.80665, y: Float(a.y) * -9.80665, z: Float(a.z) * -9.80665)
                }
            }
        }
    }
}

private struct CachedMotors {
    let controllerID: ObjectIdentifier
    let motors: RumbleMotors
}

private struct RumbleValue: Sendable { var low: UInt16; var high: UInt16 }
private struct TriggerRumbleValue: Sendable { var left: UInt16; var right: UInt16 }
private struct LEDValue: Sendable { var r: UInt8; var g: UInt8; var b: UInt8 }
private enum AdaptiveTriggerSide: Hashable, Sendable { case left, right }
private struct AdaptiveTriggerKey: Hashable, Sendable { let number: UInt8; let side: AdaptiveTriggerSide }
private struct AdaptiveTriggerCommand: Sendable { var type: UInt8; var payload: [UInt8] }
private struct MotionKey: Hashable, Sendable { let number: UInt8; let type: UInt8 }

/// Coalesces bursts of nonisolated writes (moonlight-common-c's callback thread) into a single
/// main-actor apply per key. `write` stores the newest value and reports whether THIS call must
/// schedule a drain, true only on the clean -> dirty transition, so N rapid writes for the same key
/// spawn a single `Task` instead of stacking one per write. `drain` always reads whatever is newest
/// at the moment it runs and clears the dirty bit, so the value that gets applied can never be older
/// than the last write that happened before the drain executes, regardless of how the unstructured
/// `Task`s that scheduled earlier drains are themselves ordered by the scheduler. That is what makes
/// the newest value win instead of an arbitrary one.
private final class LatestValueStore<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Slot { var value: Value; var dirty: Bool }
    private let state = Mutex<[Key: Slot]>([:])

    func write(_ value: Value, for key: Key) -> Bool {
        state.withLock { dict in
            let scheduleNeeded = !(dict[key]?.dirty ?? false)
            dict[key] = Slot(value: value, dirty: true)
            return scheduleNeeded
        }
    }

    func drain(for key: Key) -> Value? {
        state.withLock { dict in
            guard let slot = dict[key], slot.dirty else { return nil }
            dict[key] = Slot(value: slot.value, dirty: false)
            return slot.value
        }
    }

    /// Discards every pending value. `stopAll()` calls this on every queue so a drain `Task`
    /// scheduled before it, but not yet run, finds nothing to apply.
    func clear() {
        state.withLock { $0.removeAll() }
    }
}

/// Continuous haptic players per motor; Moonlight's low-frequency motor maps to the left handle,
/// the high-frequency motor to the right one, as in Moonlight iOS.
@MainActor
final class RumbleMotors {
    private let left: CHHapticEngine?, right: CHHapticEngine?, leftTrigger: CHHapticEngine?, rightTrigger: CHHapticEngine?
    private var players: [ObjectIdentifier: any CHHapticAdvancedPatternPlayer] = [:]

    /// `onStopped` drops this instance from `ControllerFeedback.motors` so the next rumble call
    /// rebuilds fresh engines; CoreHaptics gives no way to bring an engine back once it has stopped
    /// for reasons like a game controller disconnect or a system error (as opposed to a reset, which
    /// `resetHandler` recovers from in place).
    init?(controller: GCController, onStopped: @escaping @MainActor () -> Void) {
        guard let haptics = controller.haptics else { return nil }
        left = haptics.createEngine(withLocality: .leftHandle) ?? haptics.createEngine(withLocality: .handles)
        right = haptics.createEngine(withLocality: .rightHandle)
        leftTrigger = haptics.supportedLocalities.contains(.leftTrigger) ? haptics.createEngine(withLocality: .leftTrigger) : nil
        rightTrigger = haptics.supportedLocalities.contains(.rightTrigger) ? haptics.createEngine(withLocality: .rightTrigger) : nil
        for engine in [left, right, leftTrigger, rightTrigger].compactMap({ $0 }) {
            // Weak: `engine` owns `resetHandler`, so a strong capture here would be a self-retain
            // cycle that keeps the engine alive (and buzzing memory, never CPU) even after this
            // RumbleMotors and every other strong reference to it is gone.
            engine.resetHandler = { [weak engine] in
                Task { @MainActor in
                    guard let engine else { return }
                    do { try engine.start() } catch {
                        NSLog("ControllerFeedback: haptic engine restart after reset failed: %@", String(describing: error))
                    }
                }
            }
            engine.stoppedHandler = { reason in
                NSLog("ControllerFeedback: haptic engine stopped: %@", String(describing: reason))
                Task { @MainActor in onStopped() }
            }
            do {
                try engine.start()
            } catch {
                NSLog("ControllerFeedback: haptic engine start failed: %@", String(describing: error))
            }
        }
    }

    func set(low: UInt16, high: UInt16) { play(left, low); play(right, high) }
    func setTriggers(left l: UInt16, right r: UInt16) { play(leftTrigger, l); play(rightTrigger, r) }

    func stopAll() {
        for player in players.values { try? player.stop(atTime: CHHapticTimeImmediate) }
        players.removeAll()
        for engine in [left, right, leftTrigger, rightTrigger].compactMap({ $0 }) {
            engine.stop { error in
                if let error { NSLog("ControllerFeedback: haptic engine stop failed: %@", String(describing: error)) }
            }
        }
    }

    private func play(_ engine: CHHapticEngine?, _ value: UInt16) {
        guard let engine else { return }
        let key = ObjectIdentifier(engine)
        try? players[key]?.stop(atTime: CHHapticTimeImmediate)
        players[key] = nil
        guard value > 0 else { return }
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(value) / 65535)
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity], relativeTime: 0, duration: 30)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            players[key] = player
        } catch {
            NSLog("ControllerFeedback: haptic playback failed: %@", String(describing: error))
        }
    }
}
#endif
