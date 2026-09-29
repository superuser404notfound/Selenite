import Foundation
import Testing
@testable import HostKit

@Test func storeUpsertsByHostID() {
    let defaults = UserDefaults(suiteName: "HostStoreTests-\(UUID().uuidString)")!
    let store = HostStore(defaults: defaults)
    let host = PairedHost(id: "A", name: "PC", address: "10.0.0.2", httpsPort: 47984, serverCertificateDER: Data([1]))
    store.save(host)
    var moved = host
    moved.address = "10.0.0.3"
    store.save(moved)
    #expect(store.all() == [moved])
    store.remove(id: "A")
    #expect(store.all().isEmpty)
}

@Test func updateKeepsOrderAndNeverResurrects() {
    let store = HostStore(defaults: UserDefaults(suiteName: "HostStoreTests-\(UUID().uuidString)")!)
    let first = PairedHost(id: "A", name: "PC A", address: "10.0.0.2", httpsPort: 47984, serverCertificateDER: Data([1]))
    let second = PairedHost(id: "B", name: "PC B", address: "10.0.0.3", httpsPort: 47984, serverCertificateDER: Data([1]))
    store.save(first)
    store.save(second)
    var moved = first
    moved.address = "10.0.0.9"
    store.update(moved)
    #expect(store.all().map(\.id) == ["A", "B"])
    #expect(store.all().first?.address == "10.0.0.9")
    store.remove(id: "A")
    store.update(moved)
    #expect(store.all().map(\.id) == ["B"])
}
