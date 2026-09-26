#if os(tvOS)
import CoreHaptics
import GameController
import MoonlightCore
import QuartzCore

@MainActor
public final class ControllerFeedback {
    private let manager: ControllerManager
    private var motors: [UInt8: RumbleMotors] = [:]
    private var motionRates: [UInt8: [UInt8: UInt16]] = [:]
    private var lastMotionSend: [UInt8: Double] = [:]
    public weak var sink: (any ControllerEventSink)?

    public init(manager: ControllerManager) { self.manager = manager }

    nonisolated public func rumble(controller: UInt16, low: UInt16, high: UInt16) {
        Task { @MainActor in self.motorsFor(controller)?.set(low: low, high: high) }
    }
    nonisolated public func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {
        Task { @MainActor in self.motorsFor(controller)?.setTriggers(left: left, right: right) }
    }
    nonisolated public func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        Task { @MainActor in
            self.manager.controller(number: UInt8(truncatingIfNeeded: controller))?.light?.color =
                GCColor(red: Float(r) / 255, green: Float(g) / 255, blue: Float(b) / 255)
        }
    }
    nonisolated public func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {
        Task { @MainActor in
            guard let pad = self.manager.controller(number: UInt8(truncatingIfNeeded: controller))?.extendedGamepad as? GCDualSenseGamepad else { return }
            if eventFlags & UInt8(DS_EFFECT_LEFT_TRIGGER) != 0 { Self.apply(.decode(type: typeLeft, payload: left), to: pad.leftTrigger) }
            if eventFlags & UInt8(DS_EFFECT_RIGHT_TRIGGER) != 0 { Self.apply(.decode(type: typeRight, payload: right), to: pad.rightTrigger) }
        }
    }
    nonisolated public func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        Task { @MainActor in self.updateMotion(number: UInt8(truncatingIfNeeded: controller), type: motionType, rate: reportRateHz) }
    }

    private static func apply(_ effect: AdaptiveTriggerEffect, to trigger: GCDualSenseAdaptiveTrigger) {
        switch effect {
        case .off: trigger.setModeOff()
        case .feedback(let start, let strength): trigger.setModeFeedbackWithStartPosition(start, resistiveStrength: strength)
        case .weapon(let start, let end, let strength): trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case .vibration(let start, let amplitude, let frequency): trigger.setModeVibrationWithStartPosition(start, amplitude: amplitude, frequency: frequency)
        }
    }

    private func motorsFor(_ controller: UInt16) -> RumbleMotors? {
        let number = UInt8(truncatingIfNeeded: controller)
        if let existing = motors[number] { return existing }
        guard let device = manager.controller(number: number), let motors = RumbleMotors(controller: device) else { return nil }
        self.motors[number] = motors
        return motors
    }

    private func updateMotion(number: UInt8, type: UInt8, rate: UInt16) {
        guard let controller = manager.controller(number: number), let motion = controller.motion else { return }
        var rates = motionRates[number] ?? [:]
        rates[type] = rate == 0 ? nil : rate
        motionRates[number] = rates
        let active = !rates.isEmpty
        if motion.sensorsRequireManualActivation { motion.sensorsActive = active }
        guard active else { motion.valueChangedHandler = nil; return }
        let interval = 1 / Double(rates.values.max() ?? 100)
        motion.valueChangedHandler = { [weak self] m in
            MainActor.assumeIsolated {
                guard let self, let sink = self.sink else { return }
                let now = CACurrentMediaTime()
                guard now - (self.lastMotionSend[number] ?? 0) >= interval else { return }
                self.lastMotionSend[number] = now
                let degrees: Float = 180 / .pi
                if rates[UInt8(LI_MOTION_TYPE_GYRO)] != nil {
                    sink.controllerMotion(number: number, type: UInt8(LI_MOTION_TYPE_GYRO),
                                          x: Float(m.rotationRate.x) * degrees, y: Float(m.rotationRate.y) * degrees, z: Float(m.rotationRate.z) * degrees)
                }
                if rates[UInt8(LI_MOTION_TYPE_ACCEL)] != nil {
                    let g: Float = 9.80665
                    let a = m.hasGravityAndUserAcceleration
                        ? (Float(m.gravity.x + m.userAcceleration.x), Float(m.gravity.y + m.userAcceleration.y), Float(m.gravity.z + m.userAcceleration.z))
                        : (Float(m.acceleration.x), Float(m.acceleration.y), Float(m.acceleration.z))
                    sink.controllerMotion(number: number, type: UInt8(LI_MOTION_TYPE_ACCEL), x: a.0 * g, y: a.1 * g, z: a.2 * g)
                }
            }
        }
    }
}

/// Continuous haptic players per motor; Moonlight's low-frequency motor maps to the left handle,
/// the high-frequency motor to the right one, as in Moonlight iOS.
@MainActor
final class RumbleMotors {
    private let left: CHHapticEngine?, right: CHHapticEngine?, leftTrigger: CHHapticEngine?, rightTrigger: CHHapticEngine?
    private var players: [ObjectIdentifier: any CHHapticAdvancedPatternPlayer] = [:]

    init?(controller: GCController) {
        guard let haptics = controller.haptics else { return nil }
        left = haptics.createEngine(withLocality: .leftHandle) ?? haptics.createEngine(withLocality: .handles)
        right = haptics.createEngine(withLocality: .rightHandle)
        leftTrigger = haptics.supportedLocalities.contains(.leftTrigger) ? haptics.createEngine(withLocality: .leftTrigger) : nil
        rightTrigger = haptics.supportedLocalities.contains(.rightTrigger) ? haptics.createEngine(withLocality: .rightTrigger) : nil
        [left, right, leftTrigger, rightTrigger].compactMap { $0 }.forEach { try? $0.start() }
    }

    func set(low: UInt16, high: UInt16) { play(left, low); play(right, high) }
    func setTriggers(left l: UInt16, right r: UInt16) { play(leftTrigger, l); play(rightTrigger, r) }

    private func play(_ engine: CHHapticEngine?, _ value: UInt16) {
        guard let engine else { return }
        let key = ObjectIdentifier(engine)
        try? players[key]?.stop(atTime: CHHapticTimeImmediate)
        players[key] = nil
        guard value > 0 else { return }
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(value) / 65535)
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity], relativeTime: 0, duration: 30)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
        players[key] = player
    }
}
#endif
