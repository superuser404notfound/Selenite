import Foundation
import Testing
@testable import HostKit

/// Sunshine for the whole add-host flow: serverinfo over HTTP and HTTPS from the fixture, the
/// pairing handshake from FakeSunshine, with switches for the failure cases.
private final class ScriptedSunshine: NvHTTPTransport, @unchecked Sendable {
    let pairing: FakeSunshine
    private let lock = NSLock()
    private var _log: [String] = []
    private var _invalidations = 0
    var serverInfoError: URLError?
    var pairError: URLError?
    var secureServerInfoWorks = true
    var pairingInProgress = false

    init(pin: String) throws {
        pairing = try FakeSunshine(pin: pin)
    }

    var log: [String] { lock.withLock { _log } }
    var invalidations: Int { lock.withLock { _invalidations } }

    func pinServerCertificate(_ der: Data) {}
    func invalidate() { lock.withLock { _invalidations += 1 } }

    func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        let secure = url.scheme == "https"
        lock.withLock { _log.append((secure ? "https " : "http ") + url.path) }
        if url.path == "/serverinfo" {
            if secure {
                guard secureServerInfoWorks else { throw URLError(.secureConnectionFailed) }
                return try fixture("serverinfo")
            }
            if let serverInfoError { throw serverInfoError }
            return try fixture("serverinfo")
        }
        if url.path == "/pair" {
            if let pairError { throw pairError }
            if pairingInProgress, url.query?.contains("phrase=getservercert") == true {
                return Data("<root status_code=\"200\"><paired>1</paired><plaincert></plaincert></root>".utf8)
            }
        }
        return try await pairing.get(url, timeout: timeout)
    }
}

@MainActor private final class PINLog {
    var pins: [String] = []
}

private let fixtureHostID = "4D7BA7C5-1E1A-4E0B-9F2A-0C4C8E6B2B11"

private func freshStore() -> HostStore {
    HostStore(defaults: UserDefaults(suiteName: "PairingFlowTests-\(UUID().uuidString)")!)
}

private func makeFlow(_ sunshine: ScriptedSunshine, store: HostStore, pin: String) throws -> PairingFlow {
    PairingFlow(identity: try ClientIdentity.generate(), store: store,
                makeTransport: { _ in sunshine }, makePIN: { pin })
}

@MainActor @Test func pairsANewHostShowsThePINAndSavesIt() async throws {
    let sunshine = try ScriptedSunshine(pin: "4711")
    let store = freshStore()
    let log = PINLog()
    let outcome = try await makeFlow(sunshine, store: store, pin: "4711")
        .run(address: " 192.168.1.20 ") { pin in log.pins.append(pin) }
    let saved = store.all()
    #expect(saved.count == 1)
    #expect(saved.first?.id == fixtureHostID)
    #expect(saved.first?.name == "GAMING-PC")
    #expect(saved.first?.address == "192.168.1.20")
    #expect(saved.first?.serverCertificateDER == sunshine.pairing.serverIdentity.certificateDER)
    #expect(outcome == .paired(saved[0]))
    #expect(log.pins == ["4711"])
    #expect(sunshine.invalidations >= 1)
}

@MainActor @Test func aWrongPINFailsAndSavesNothing() async throws {
    let sunshine = try ScriptedSunshine(pin: "4711")
    let store = freshStore()
    let flow = try makeFlow(sunshine, store: store, pin: "0000")
    await #expect(throws: PairingFailure.incorrectPIN) {
        try await flow.run(address: "192.168.1.20") { _ in }
    }
    #expect(store.all().isEmpty)
}

@MainActor @Test func aPINNeverEnteredTimesOut() async throws {
    let sunshine = try ScriptedSunshine(pin: "4711")
    sunshine.pairError = URLError(.timedOut)
    let flow = try makeFlow(sunshine, store: freshStore(), pin: "4711")
    await #expect(throws: PairingFailure.timedOut) {
        try await flow.run(address: "192.168.1.20") { _ in }
    }
}

@MainActor @Test func anUnreachableHostFailsBeforeAnyPIN() async throws {
    let sunshine = try ScriptedSunshine(pin: "4711")
    sunshine.serverInfoError = URLError(.cannotConnectToHost)
    let log = PINLog()
    let flow = try makeFlow(sunshine, store: freshStore(), pin: "4711")
    await #expect(throws: PairingFailure.unreachable) {
        try await flow.run(address: "10.9.9.9") { pin in log.pins.append(pin) }
    }
    #expect(log.pins.isEmpty)
}

@MainActor @Test func pairingAlreadyInProgressOnTheHostIsReported() async throws {
    let sunshine = try ScriptedSunshine(pin: "4711")
    sunshine.pairingInProgress = true
    let flow = try makeFlow(sunshine, store: freshStore(), pin: "4711")
    await #expect(throws: PairingFailure.alreadyInProgress) {
        try await flow.run(address: "192.168.1.20") { _ in }
    }
}

@MainActor @Test func aKnownHostAtANewAddressIsUpdatedNotDuplicated() async throws {
    // Review Focus 4.
    let sunshine = try ScriptedSunshine(pin: "4711")
    let store = freshStore()
    store.save(PairedHost(id: fixtureHostID, name: "OLD NAME", address: "10.0.0.9", httpsPort: 47984,
                          serverCertificateDER: Data([1])))
    let log = PINLog()
    let outcome = try await makeFlow(sunshine, store: store, pin: "4711")
        .run(address: "192.168.1.20") { pin in log.pins.append(pin) }
    let saved = store.all()
    #expect(saved.count == 1)
    #expect(saved.first?.address == "192.168.1.20")
    #expect(saved.first?.name == "GAMING-PC")
    #expect(saved.first?.serverCertificateDER == Data([1]))
    #expect(outcome == .alreadyPaired(saved[0]))
    #expect(log.pins.isEmpty)
    let pairRequests = sunshine.log.filter { $0.hasSuffix("/pair") }
    #expect(pairRequests.isEmpty)
}

@MainActor @Test func aKnownHostThatNoLongerTrustsUsIsPairedAgain() async throws {
    let sunshine = try ScriptedSunshine(pin: "4711")
    sunshine.secureServerInfoWorks = false
    let store = freshStore()
    store.save(PairedHost(id: fixtureHostID, name: "GAMING-PC", address: "192.168.1.20", httpsPort: 47984,
                          serverCertificateDER: Data([1])))
    let outcome = try await makeFlow(sunshine, store: store, pin: "4711").run(address: "192.168.1.20") { _ in }
    let saved = store.all()
    #expect(saved.count == 1)
    #expect(saved.first?.serverCertificateDER == sunshine.pairing.serverIdentity.certificateDER)
    #expect(outcome == .paired(saved[0]))
}

@MainActor @Test func pairAgainSkipsTheAlreadyPairedShortcut() async throws {
    let sunshine = try ScriptedSunshine(pin: "4711")
    let store = freshStore()
    store.save(PairedHost(id: fixtureHostID, name: "GAMING-PC", address: "192.168.1.20", httpsPort: 47984,
                          serverCertificateDER: Data([1])))
    let log = PINLog()
    let outcome = try await makeFlow(sunshine, store: store, pin: "4711")
        .run(address: "192.168.1.20", forcePairing: true) { pin in log.pins.append(pin) }
    let saved = store.all()
    #expect(log.pins == ["4711"])
    #expect(outcome == .paired(saved[0]))
    let secureChecks = sunshine.log.filter { $0 == "https /serverinfo" }
    #expect(secureChecks.isEmpty)
}

@Test func failuresMapFromTheirSources() {
    let timedOut: PairingFailure = PairingFailure.from(URLError(.timedOut))
    let refused: PairingFailure = PairingFailure.from(URLError(.cannotConnectToHost))
    let cancelled: PairingFailure = PairingFailure.from(CancellationError())
    let declined: PairingFailure = PairingFailure.from(PairingError.declined("busy"))
    #expect(timedOut == .timedOut)
    #expect(refused == .unreachable)
    #expect(cancelled == .cancelled)
    #expect(declined == .declined("busy"))
}
