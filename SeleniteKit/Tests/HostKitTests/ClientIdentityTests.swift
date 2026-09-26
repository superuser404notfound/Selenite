import Foundation
import Testing
import X509
@testable import HostKit

@Test func hexRoundTrips() {
    let data = Data([0x00, 0x0f, 0xa0, 0xff])
    #expect(data.hexString == "000fa0ff")
    #expect(Data(hex: "000FA0ff") == data)
    #expect(Data(hex: "abc") == nil)
    #expect(Data(hex: "zz") == nil)
}

@Test func generatedIdentityIsSelfSignedGameStreamClient() throws {
    let identity = try ClientIdentity.generate()
    #expect(identity.uniqueID.count == 16)
    let cert = try Certificate(derEncoded: Array(identity.certificateDER))
    #expect(cert.subject.description.contains("NVIDIA GameStream Client"))
    #expect(cert.issuer == cert.subject)
    #expect(cert.signatureAlgorithm == .sha256WithRSAEncryption)
}

@Test func pemRoundTrips() throws {
    let identity = try ClientIdentity.generate()
    let pem = identity.certificatePEM
    #expect(String(decoding: pem, as: UTF8.self).hasPrefix("-----BEGIN CERTIFICATE-----\n"))
    #expect(try PEM.decodeCertificate(pem) == identity.certificateDER)
}
