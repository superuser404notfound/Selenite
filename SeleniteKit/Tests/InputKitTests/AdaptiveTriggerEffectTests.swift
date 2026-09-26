import Testing
@testable import InputKit

@Test func offAndUnknownDecodeToOff() {
    #expect(AdaptiveTriggerEffect.decode(type: 0x05, payload: Array(repeating: 0, count: 10)) == .off)
    #expect(AdaptiveTriggerEffect.decode(type: 0x99, payload: Array(repeating: 0, count: 10)) == .off)
    #expect(AdaptiveTriggerEffect.decode(type: 0x21, payload: []) == .off)
}

@Test func feedbackUsesFirstZoneAndPeakStrength() {
    // Zones 3...9 active (bits 3-9), strength 5 in every active zone (3 bits each).
    let zones: UInt16 = 0b11_1111_1000
    var strengths: UInt32 = 0
    for zone in 3...9 { strengths |= 5 << (3 * UInt32(zone)) }
    let payload = [UInt8(zones & 0xFF), UInt8(zones >> 8),
                   UInt8(strengths & 0xFF), UInt8((strengths >> 8) & 0xFF), UInt8((strengths >> 16) & 0xFF), UInt8(strengths >> 24),
                   0, 0, 0, 0]
    #expect(AdaptiveTriggerEffect.decode(type: 0x21, payload: payload) == .feedback(start: 3.0 / 9, strength: 6.0 / 8))
}

@Test func weaponUsesStartEndZones() {
    let zones: UInt16 = (1 << 2) | (1 << 6)
    let payload: [UInt8] = [UInt8(zones & 0xFF), UInt8(zones >> 8), 7, 0, 0, 0, 0, 0, 0, 0]
    #expect(AdaptiveTriggerEffect.decode(type: 0x25, payload: payload) == .weapon(start: 2.0 / 9, end: 6.0 / 9, strength: 1))
}

@Test func vibrationCarriesFrequency() {
    let zones: UInt16 = 1 << 4
    let amplitudes: UInt32 = 3 << 12
    let payload: [UInt8] = [UInt8(zones & 0xFF), UInt8(zones >> 8),
                            UInt8(amplitudes & 0xFF), UInt8((amplitudes >> 8) & 0xFF), UInt8((amplitudes >> 16) & 0xFF), UInt8(amplitudes >> 24),
                            0, 0, 40, 0]
    #expect(AdaptiveTriggerEffect.decode(type: 0x26, payload: payload) == .vibration(start: 4.0 / 9, amplitude: 4.0 / 8, frequency: 40.0 / 255))
}
