import Foundation
import Testing
@testable import HostKit

@Test func ecbMatchesFIPS197() throws {
    let key = Data(hex: "000102030405060708090a0b0c0d0e0f")!
    let plain = Data(hex: "00112233445566778899aabbccddeeff")!
    let cipher = try PairingCrypto.ecbEncrypt(plain, key: key)
    #expect(cipher.hexString == "69c4e0d86a7b0430d8cdb78070b4c55a")
    #expect(try PairingCrypto.ecbDecrypt(cipher, key: key) == plain)
}

@Test func aesKeyIsTruncatedSaltedPinHash() {
    let salt = Data(repeating: 1, count: 16)
    let v7 = PairingCrypto.aesKey(salt: salt, pin: "1234", serverMajorVersion: 7)
    let v6 = PairingCrypto.aesKey(salt: salt, pin: "1234", serverMajorVersion: 6)
    #expect(v7.count == 16)
    #expect(v7 == PairingCrypto.hash(salt + Data("1234".utf8), serverMajorVersion: 7).prefix(16))
    #expect(v6 != v7)
    #expect(PairingCrypto.hash(Data(), serverMajorVersion: 7).count == 32)
    #expect(PairingCrypto.hash(Data(), serverMajorVersion: 6).count == 20)
}

@Test func signatureVerifiesAgainstOwnCertificateOnly() throws {
    let a = try ClientIdentity.generate()
    let b = try ClientIdentity.generate()
    let message = Data("secret".utf8)
    let signature = try PairingCrypto.sign(message, privateKeyDER: a.privateKeyDER)
    #expect(try PairingCrypto.verify(signature: signature, data: message, certificateDER: a.certificateDER))
    #expect(try !PairingCrypto.verify(signature: signature, data: message, certificateDER: b.certificateDER))
}

@Test func certificateSignatureIsTheRSASignature() throws {
    let identity = try ClientIdentity.generate()
    #expect(try PairingCrypto.certificateSignature(identity.certificateDER).count == 256)
}
