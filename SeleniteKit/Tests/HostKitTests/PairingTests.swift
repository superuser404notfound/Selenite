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
