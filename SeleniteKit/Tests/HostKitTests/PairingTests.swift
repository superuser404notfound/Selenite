import Foundation
import Testing
@testable import HostKit

private let endpoints = NvEndpoints(address: "192.168.1.20", uniqueID: "0123456789abcdef")

@Test func pairsWithMatchingPIN() async throws {
    let host = try FakeSunshine(pin: "4711")
    let pairing = Pairing(transport: host, endpoints: endpoints, identity: try ClientIdentity.generate())
    let serverCert = try await pairing.run(pin: "4711", serverMajorVersion: 7)
    #expect(serverCert == host.serverIdentity.certificateDER)
    #expect(host.requests.last == "/pair:pairchallenge")
    #expect(!host.requests.contains("/unpair"))
}

@Test func wrongPINFailsAndUnpairs() async throws {
    let host = try FakeSunshine(pin: "4711")
    let pairing = Pairing(transport: host, endpoints: endpoints, identity: try ClientIdentity.generate())
    await #expect(throws: PairingError.incorrectPIN) {
        try await pairing.run(pin: "0000", serverMajorVersion: 7)
    }
    #expect(host.requests.last == "/unpair")
}

@Test func pinIsFourDigits() {
    for _ in 0..<50 {
        let pin = Pairing.makePIN()
        #expect(pin.count == 4)
        #expect(pin.allSatisfy { $0.isNumber })
    }
}

@Test func unpairsEvenWhenCancelledDuringStageOne() async throws {
    let transport = StageOneSuspendingTransport()
    let pairing = Pairing(transport: transport, endpoints: endpoints, identity: try ClientIdentity.generate())
    let task = Task {
        try await pairing.run(pin: "4711", serverMajorVersion: 7)
    }
    // Deterministic: wait for confirmation that stage 1's request actually landed
    // (and is suspended) before cancelling, instead of racing a fixed sleep against it.
    await transport.waitUntilStageOneStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(transport.requests.contains("/unpair"))
}

/// Suspends indefinitely on the stage-1 (getservercert) request, honoring cancellation like
/// a real network call would, but answers /unpair immediately.
private final class StageOneSuspendingTransport: NvHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    private var stageOneReached = false
    private var stageOneWaiter: CheckedContinuation<Void, Never>?

    var requests: [String] { lock.withLock { _requests } }

    func pinServerCertificate(_ der: Data) {}

    /// Suspends until the stage-1 request has been recorded (already recorded resolves immediately).
    func waitUntilStageOneStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if stageOneReached {
                lock.unlock()
                continuation.resume()
            } else {
                stageOneWaiter = continuation
                lock.unlock()
            }
        }
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        if recordRequestAndCheckIfStageOne(url) {
            try await Task.sleep(for: .seconds(60))
        }
        if url.path == "/unpair" {
            return Data("<root status_code=\"200\"></root>".utf8)
        }
        return Data("<root status_code=\"200\"><paired>0</paired></root>".utf8)
    }

    /// Records the request and, if it is the stage-1 request, wakes `waitUntilStageOneStarted`.
    /// Returns whether the caller should now suspend as stage 1 would.
    private func recordRequestAndCheckIfStageOne(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        lock.lock()
        _requests.append(url.path + (value("phrase").map { ":\($0)" } ?? ""))
        let isStageOne = value("phrase") == "getservercert"
        var waiter: CheckedContinuation<Void, Never>?
        if isStageOne {
            stageOneReached = true
            waiter = stageOneWaiter
            stageOneWaiter = nil
        }
        lock.unlock()
        waiter?.resume()
        return isStageOne
    }
}
