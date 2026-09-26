import Foundation

public protocol NvHTTPTransport: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> Data
    /// Called once the host certificate is known, before the first HTTPS request.
    func pinServerCertificate(_ der: Data)
}

public enum PairingError: Error, Equatable {
    case declined(String)
    case alreadyInProgress
    case incorrectPIN
    case serverCertificateInvalid
    case stageFailed(Int)
}

/// GameStream PIN pairing, step for step as in Moonlight's PairManager.m.
public struct Pairing: Sendable {
    let transport: any NvHTTPTransport
    let endpoints: NvEndpoints
    let identity: ClientIdentity

    public init(transport: any NvHTTPTransport, endpoints: NvEndpoints, identity: ClientIdentity) {
        self.transport = transport
        self.endpoints = endpoints
        self.identity = identity
    }

    public static func makePIN() -> String {
        (0..<4).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// Returns the host certificate (DER) to pin for all later HTTPS traffic.
    public func run(pin: String, serverMajorVersion: Int) async throws -> Data {
        do {
            return try await handshake(pin: pin, version: serverMajorVersion)
        } catch {
            // Runs as an unstructured task so a cancelled `run` (the user left the PIN
            // screen while stage 1 was blocked) still gets the best-effort unpair out:
            // an unstructured task does not inherit the enclosing task's cancellation.
            let transport = transport
            let unpairURL = endpoints.unpair()
            let unpairTask = Task {
                _ = try? await transport.get(unpairURL, timeout: 10)
            }
            await unpairTask.value
            throw error
        }
    }

    private func pairStep(_ url: URL, stage: Int, timeout: TimeInterval = 10) async throws -> NvResponse {
        let response = try NvResponse.parse(try await transport.get(url, timeout: timeout))
        guard response.statusCode == 200, response["paired"] == "1" else {
            if stage == 1 { throw PairingError.declined(response.statusMessage) }
            throw PairingError.stageFailed(stage)
        }
        return response
    }

    private func handshake(pin: String, version: Int) async throws -> Data {
        let salt = Data.random(16)
        // Blocks until the PIN is entered in the Sunshine web UI.
        let first = try await pairStep(endpoints.pairGetServerCert(salt: salt, clientCertPEM: identity.certificatePEM),
                                       stage: 1, timeout: 120)
        guard let plainCertHex = first["plaincert"], !plainCertHex.isEmpty,
              let serverPEM = Data(hex: plainCertHex) else { throw PairingError.alreadyInProgress }
        let serverCert = try PEM.decodeCertificate(serverPEM)
        transport.pinServerCertificate(serverCert)

        let key = PairingCrypto.aesKey(salt: salt, pin: pin, serverMajorVersion: version)
        let hashLength = version >= 7 ? 32 : 20

        let randomChallenge = Data.random(16)
        let second = try await pairStep(
            endpoints.pairClientChallenge(try PairingCrypto.ecbEncrypt(randomChallenge, key: key)), stage: 2)
        guard let encrypted = second["challengeresponse"].flatMap(Data.init(hex:)) else { throw PairingError.stageFailed(2) }
        let decrypted = try PairingCrypto.ecbDecrypt(encrypted, key: key)
        guard decrypted.count >= hashLength + 16 else { throw PairingError.stageFailed(2) }
        let serverResponse = decrypted.prefix(hashLength)
        let serverChallenge = decrypted.dropFirst(hashLength).prefix(16)

        let clientSecret = Data.random(16)
        let clientSignature = try PairingCrypto.certificateSignature(identity.certificateDER)
        var challengeHash = PairingCrypto.hash(serverChallenge + clientSignature + clientSecret, serverMajorVersion: version)
        challengeHash.append(Data(count: 32 - challengeHash.count))
        let third = try await pairStep(
            endpoints.pairServerChallengeResponse(try PairingCrypto.ecbEncrypt(challengeHash, key: key)), stage: 3)
        guard let secretReply = third["pairingsecret"].flatMap(Data.init(hex:)), secretReply.count > 16 else {
            throw PairingError.stageFailed(3)
        }
        let serverSecret = secretReply.prefix(16)
        let serverSecretSignature = secretReply.dropFirst(16)
        guard try PairingCrypto.verify(signature: Data(serverSecretSignature), data: Data(serverSecret),
                                       certificateDER: serverCert) else { throw PairingError.serverCertificateInvalid }

        let serverSignature = try PairingCrypto.certificateSignature(serverCert)
        let expected = PairingCrypto.hash(randomChallenge + serverSignature + serverSecret, serverMajorVersion: version)
        guard expected == serverResponse else { throw PairingError.incorrectPIN }

        let signedSecret = clientSecret + (try PairingCrypto.sign(clientSecret, privateKeyDER: identity.privateKeyDER))
        _ = try await pairStep(endpoints.pairClientPairingSecret(signedSecret), stage: 4)
        _ = try await pairStep(endpoints.pairChallenge(), stage: 5)
        return serverCert
    }
}

extension Data {
    static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
