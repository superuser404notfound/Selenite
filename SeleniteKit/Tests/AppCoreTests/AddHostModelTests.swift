import Foundation
import HostKit
import Testing
@testable import AppCore

private struct UnreachableTransport: NvHTTPTransport {
    func get(_ url: URL, timeout: TimeInterval) async throws -> Data { throw URLError(.cannotConnectToHost) }
    func pinServerCertificate(_ der: Data) {}
}

@MainActor private func makeModel(pairAgainAddress: String? = nil, discoveredAddress: String? = nil) throws -> AddHostModel {
    let store = HostStore(defaults: UserDefaults(suiteName: "AddHostModelTests-\(UUID().uuidString)")!)
    let flow = PairingFlow(identity: try ClientIdentity.generate(), store: store,
                           makeTransport: { _ in UnreachableTransport() })
    return AddHostModel(flow: flow, pairAgainAddress: pairAgainAddress, discoveredAddress: discoveredAddress)
}

@MainActor @Test func aNewHostStartsAtTheAddressAndIgnoresABlankOne() throws {
    let model = try makeModel()
    #expect(model.phase == .enterAddress)
    model.address = "   "
    model.submit()
    #expect(model.phase == .enterAddress)
}

@MainActor @Test func anUnreachableAddressFailsAndTryAgainKeepsTheAddress() async throws {
    let model = try makeModel()
    model.address = "10.9.9.9"
    model.submit()
    let failed = await eventually { model.phase == .failed(.unreachable) }
    #expect(failed)
    model.retry()
    #expect(model.phase == .enterAddress)
    #expect(model.address == "10.9.9.9")
}

@MainActor @Test func pairAgainStartsWithoutTheAddressStep() async throws {
    let model = try makeModel(pairAgainAddress: "10.0.0.2")
    #expect(model.phase == .checking)
    #expect(model.isPairAgain)
    model.begin()
    let failed = await eventually { model.phase == .failed(.unreachable) }
    #expect(failed)
    model.retry()
    #expect(model.phase == .checking)
}

@MainActor @Test func aDiscoveredHostStartsRightAwayAndRetriesInPlace() async throws {
    let model = try makeModel(discoveredAddress: "192.168.1.20")
    #expect(model.phase == .checking)
    #expect(!model.isPairAgain)
    #expect(model.address == "192.168.1.20")
    model.begin()
    let failed = await eventually { model.phase == .failed(.unreachable) }
    #expect(failed)
    model.retry()
    #expect(model.phase == .checking)
}
