import Foundation
@testable import HostKit

/// The server half of the GameStream pairing handshake, driven through the transport protocol.
final class FakeSunshine: NvHTTPTransport, @unchecked Sendable {
    let serverIdentity: ClientIdentity
    let pin: String
    private let lock = NSLock()
    private var _requests: [String] = []
    private var salt = Data(), clientCert = Data(), serverSecret = Data(), serverChallenge = Data()
    private var clientHash = Data()

    var requests: [String] { lock.withLock { _requests } }

    init(pin: String) throws {
        self.pin = pin
        self.serverIdentity = try ClientIdentity.generate(commonName: "Sunshine Gamestream Host")
    }

    func pinServerCertificate(_ der: Data) {}

    func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        try handle(url)
    }

    private func handle(_ url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        _requests.append(url.path + (value("phrase").map { ":\($0)" } ?? ""))
        let key = PairingCrypto.aesKey(salt: salt, pin: pin, serverMajorVersion: 7)

        if url.path == "/unpair" { return ok([:]) }
        if value("phrase") == "getservercert" {
            salt = Data(hex: value("salt")!)!
            clientCert = try PEM.decodeCertificate(Data(hex: value("clientcert")!)!)
            return ok(["paired": "1", "plaincert": serverIdentity.certificatePEM.hexString])
        }
        if let challenge = value("clientchallenge") {
            let clientChallenge = try PairingCrypto.ecbDecrypt(Data(hex: challenge)!, key: PairingCrypto.aesKey(salt: salt, pin: pin, serverMajorVersion: 7))
            serverSecret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            serverChallenge = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let serverSig = try PairingCrypto.certificateSignature(serverIdentity.certificateDER)
            let hash = PairingCrypto.hash(clientChallenge + serverSig + serverSecret, serverMajorVersion: 7)
            let reply = try PairingCrypto.ecbEncrypt(hash + serverChallenge, key: PairingCrypto.aesKey(salt: salt, pin: pin, serverMajorVersion: 7))
            return ok(["paired": "1", "challengeresponse": reply.hexString])
        }
        if let response = value("serverchallengeresp") {
            clientHash = try PairingCrypto.ecbDecrypt(Data(hex: response)!, key: key)
            let signature = try PairingCrypto.sign(serverSecret, privateKeyDER: serverIdentity.privateKeyDER)
            return ok(["paired": "1", "pairingsecret": (serverSecret + signature).hexString])
        }
        if let secret = value("clientpairingsecret").flatMap(Data.init(hex:)) {
            let clientSecret = secret.prefix(16)
            let signature = secret.dropFirst(16)
            let clientSig = try PairingCrypto.certificateSignature(clientCert)
            let expected = PairingCrypto.hash(serverChallenge + clientSig + clientSecret, serverMajorVersion: 7)
            let valid = try PairingCrypto.verify(signature: Data(signature), data: Data(clientSecret), certificateDER: clientCert)
            return ok(["paired": (valid && clientHash.prefix(32) == expected) ? "1" : "0"])
        }
        if value("phrase") == "pairchallenge" { return ok(["paired": "1"]) }
        return ok(["paired": "0"])
    }

    private func ok(_ fields: [String: String]) -> Data {
        let body = fields.map { "<\($0.key)>\($0.value)</\($0.key)>" }.joined()
        return Data("<root status_code=\"200\">\(body)</root>".utf8)
    }
}
