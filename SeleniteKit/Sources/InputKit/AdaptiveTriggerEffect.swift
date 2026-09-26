/// DualSense raw trigger effect, decoded from the payload Sunshine forwards over the control
/// stream. Zones 0...9 map to normalized positions 0...1 as zone/9.
public enum AdaptiveTriggerEffect: Equatable, Sendable {
    case off
    case feedback(start: Float, strength: Float)
    case weapon(start: Float, end: Float, strength: Float)
    case vibration(start: Float, amplitude: Float, frequency: Float)

    public static func decode(type: UInt8, payload: [UInt8]) -> AdaptiveTriggerEffect {
        guard payload.count >= 10 else { return .off }
        let zones = UInt16(payload[0]) | UInt16(payload[1]) << 8
        let packed = UInt32(payload[2]) | UInt32(payload[3]) << 8 | UInt32(payload[4]) << 16 | UInt32(payload[5]) << 24
        let active = (0..<10).filter { zones & (1 << UInt16($0)) != 0 }
        func peak() -> UInt32 { active.map { (packed >> (3 * UInt32($0))) & 0x7 }.max() ?? 0 }
        guard let first = active.first else { return .off }
        switch type {
        case 0x21: return .feedback(start: Float(first) / 9, strength: Float(peak() + 1) / 8)
        case 0x25:
            guard let last = active.last, last > first else { return .off }
            return .weapon(start: Float(first) / 9, end: Float(last) / 9, strength: Float(min(payload[2], 7) + 1) / 8)
        case 0x26: return .vibration(start: Float(first) / 9, amplitude: Float(peak() + 1) / 8, frequency: Float(payload[8]) / 255)
        default: return .off
        }
    }
}
