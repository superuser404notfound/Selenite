import Foundation

public enum PairingFailure: Error, Equatable, Sendable {
    case unreachable
    case timedOut
    case incorrectPIN
    case alreadyInProgress
    case declined(String)
    case cancelled
    case failed(String)

    public static func from(_ error: any Error) -> PairingFailure {
        if let failure = error as? PairingFailure { return failure }
        if let pairing = error as? PairingError {
            switch pairing {
            case .incorrectPIN: return .incorrectPIN
            case .alreadyInProgress: return .alreadyInProgress
            case .declined(let message): return .declined(message)
            case .serverCertificateInvalid, .stageFailed: return .failed(String(describing: pairing))
            }
        }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            default: return .unreachable
            }
        }
        return .failed(String(describing: error))
    }
}

public enum PairingOutcome: Equatable, Sendable {
    case paired(PairedHost)
    case alreadyPaired(PairedHost)
}

/// Add host and pairing as one flow (M1-B spec, section 4.2): serverinfo at the address, then
/// either the already-paired shortcut (the host is saved under its uniqueID and still accepts our
/// certificate over HTTPS: update the entry) or the PIN handshake, then save.
public struct PairingFlow: Sendable {
    public typealias TransportFactory = @Sendable (_ pinnedCertificate: Data?) -> any NvHTTPTransport

    private let identity: ClientIdentity
    private let store: HostStore
    private let makeTransport: TransportFactory
    private let makePIN: @Sendable () -> String

    public init(identity: ClientIdentity, store: HostStore, makeTransport: @escaping TransportFactory,
                makePIN: @escaping @Sendable () -> String = { Pairing.makePIN() }) {
        self.identity = identity
        self.store = store
        self.makeTransport = makeTransport
        self.makePIN = makePIN
    }

    /// `forcePairing` is "Pair again": always run the PIN handshake. `onPIN` runs on the main actor
    /// before the handshake starts, so the UI can show the PIN while stage 1 blocks. Throws only
    /// `PairingFailure`.
    public func run(address: String, forcePairing: Bool = false,
                    onPIN: @escaping @MainActor @Sendable (String) -> Void) async throws -> PairingOutcome {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = makeTransport(nil)
        defer { transport.invalidate() }
        do {
            let endpoints = NvEndpoints(address: address, uniqueID: identity.uniqueID)
            let reply = try await transport.get(endpoints.serverInfo(secure: false), timeout: 5)
            let info = try ServerInfo(NvResponse.parse(reply).requireOK())
            if !forcePairing, let known = store.all().first(where: { $0.id == info.uniqueID }),
               await stillPaired(known, address: address) {
                var updated = known
                updated.address = address
                updated.name = info.hostname
                updated.httpsPort = info.httpsPort
                store.save(updated)
                return .alreadyPaired(updated)
            }
            let pin = makePIN()
            await onPIN(pin)
            let certificate = try await Pairing(transport: transport, endpoints: endpoints, identity: identity)
                .run(pin: pin, serverMajorVersion: info.majorVersion)
            let host = PairedHost(id: info.uniqueID, name: info.hostname, address: address,
                                  httpsPort: info.httpsPort, serverCertificateDER: certificate)
            store.save(host)
            return .paired(host)
        } catch {
            throw PairingFailure.from(error)
        }
    }

    /// The saved certificate still opens an HTTPS serverinfo at this address, for the same host.
    private func stillPaired(_ host: PairedHost, address: String) async -> Bool {
        let transport = makeTransport(host.serverCertificateDER)
        defer { transport.invalidate() }
        let endpoints = NvEndpoints(address: address, httpsPort: host.httpsPort, uniqueID: identity.uniqueID)
        guard let reply = try? await transport.get(endpoints.serverInfo(secure: true), timeout: 5),
              let info = try? ServerInfo(NvResponse.parse(reply).requireOK()) else { return false }
        return info.uniqueID == host.id && info.isPaired
    }
}
