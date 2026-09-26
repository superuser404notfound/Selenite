import CommonCrypto
import Crypto
import Foundation
import SwiftASN1
import X509
import _CryptoExtras

/// Primitives of the GameStream PIN pairing handshake (see Moonlight's PairManager.m).
public enum PairingCrypto {
    public enum Error: Swift.Error { case cipher(Int32), malformedCertificate }

    public static func hash(_ data: Data, serverMajorVersion: Int) -> Data {
        serverMajorVersion >= 7 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
    }

    public static func aesKey(salt: Data, pin: String, serverMajorVersion: Int) -> Data {
        Data(hash(salt + Data(pin.utf8), serverMajorVersion: serverMajorVersion).prefix(16))
    }

    public static func ecbEncrypt(_ data: Data, key: Data) throws -> Data {
        try ecb(CCOperation(kCCEncrypt), data, key)
    }

    public static func ecbDecrypt(_ data: Data, key: Data) throws -> Data {
        try ecb(CCOperation(kCCDecrypt), data, key)
    }

    private static func ecb(_ operation: CCOperation, _ data: Data, _ key: Data) throws -> Data {
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil,
                            input.baseAddress, data.count, out.baseAddress, data.count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw Error.cipher(status) }
        return output
    }

    /// The raw signature BIT STRING of an X.509 certificate (third element of the outer SEQUENCE).
    public static func certificateSignature(_ certificateDER: Data) throws -> Data {
        let root = try DER.parse(Array(certificateDER))
        guard case .constructed(let children) = root.content else { throw Error.malformedCertificate }
        var iterator = children.makeIterator()
        _ = iterator.next()
        _ = iterator.next()
        guard let signatureNode = iterator.next() else { throw Error.malformedCertificate }
        return Data(try ASN1BitString(derEncoded: signatureNode).bytes)
    }

    public static func sign(_ data: Data, privateKeyDER: Data) throws -> Data {
        let key = try _RSA.Signing.PrivateKey(derRepresentation: privateKeyDER)
        return try key.signature(for: data, padding: .insecurePKCS1v1_5).rawRepresentation
    }

    public static func verify(signature: Data, data: Data, certificateDER: Data) throws -> Bool {
        let certificate = try Certificate(derEncoded: Array(certificateDER))
        let publicKey = try _RSA.Signing.PublicKey(derRepresentation: certificate.publicKey.subjectPublicKeyInfoBytes)
        return publicKey.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature),
                                          for: data, padding: .insecurePKCS1v1_5)
    }
}
