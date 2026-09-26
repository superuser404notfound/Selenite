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
