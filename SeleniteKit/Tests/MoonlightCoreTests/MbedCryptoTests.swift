import Testing
import MbedCrypto

@Test func mbedCryptoPassesGCMKnownAnswer() {
    #expect(sel_mbedcrypto_gcm_selftest())
}
