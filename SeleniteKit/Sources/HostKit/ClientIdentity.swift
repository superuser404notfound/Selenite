import Foundation
import SwiftASN1
import X509
import _CryptoExtras

/// The client certificate and key Sunshine pins at pairing. Mirrors Moonlight's mkcert.c:
/// RSA 2048, SHA-256, CN "NVIDIA GameStream Client", 20 years.
public struct ClientIdentity: Codable, Sendable, Equatable {
    public let uniqueID: String
    public let privateKeyDER: Data
    public let certificateDER: Data

    public var certificatePEM: Data { PEM.encodeCertificate(certificateDER) }

    public static func generate(commonName: String = "NVIDIA GameStream Client", now: Date = Date()) throws -> ClientIdentity {
        let rsaKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let key = Certificate.PrivateKey(rsaKey)
        let name = try DistinguishedName { CommonName(commonName) }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(20 * 365 * 24 * 3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: key
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        var idBytes = [UInt8](repeating: 0, count: 8)
        for i in idBytes.indices { idBytes[i] = UInt8.random(in: 0...255) }
        return ClientIdentity(
            uniqueID: Data(idBytes).hexString,
            privateKeyDER: Data(rsaKey.derRepresentation),
            certificateDER: Data(serializer.serializedBytes)
        )
    }
}
