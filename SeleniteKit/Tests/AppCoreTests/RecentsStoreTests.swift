import Foundation
import HostKit
import Testing
@testable import AppCore

private func app(_ id: Int) -> AppEntry { AppEntry(id: id, title: "Game \(id)", supportsHDR: false) }

@MainActor private func makeStore(_ defaults: UserDefaults = UserDefaults(suiteName: "RecentsStoreTests-\(UUID().uuidString)")!) -> RecentsStore {
    RecentsStore(defaults: defaults)
}

@MainActor @Test func newestFirstAndReplayMovesToTheFront() {
    let store = makeStore()
    store.record(hostID: "A", app: app(1), at: Date(timeIntervalSince1970: 1))
    store.record(hostID: "A", app: app(2), at: Date(timeIntervalSince1970: 2))
    store.record(hostID: "A", app: app(1), at: Date(timeIntervalSince1970: 3))
    #expect(store.entries.map(\.id) == ["A/1", "A/2"])
    #expect(store.entries.first?.lastPlayed == Date(timeIntervalSince1970: 3))
}

@MainActor @Test func theSameGameOnTwoHostsIsTwoEntries() {
    let store = makeStore()
    store.record(hostID: "A", app: app(1))
    store.record(hostID: "B", app: app(1))
    #expect(store.entries.map(\.id) == ["B/1", "A/1"])
}

@MainActor @Test func atMostTenEntries() {
    let store = makeStore()
    for id in 1...12 { store.record(hostID: "A", app: app(id)) }
    #expect(store.entries.count == RecentsStore.limit)
    #expect(store.entries.first?.id == "A/12")
    #expect(store.entries.last?.id == "A/3")
}

@MainActor @Test func removalAndHostCleanupPersist() {
    let defaults = UserDefaults(suiteName: "RecentsStoreTests-\(UUID().uuidString)")!
    let store = makeStore(defaults)
    store.record(hostID: "A", app: app(1))
    store.record(hostID: "B", app: app(2))
    store.record(hostID: "A", app: app(3))
    store.remove(store.entries[0])
    store.removeAll(hostID: "B")
    #expect(store.entries.map(\.id) == ["A/1"])
    #expect(makeStore(defaults).entries.map(\.id) == ["A/1"])
}

@MainActor @Test func unreadableStoredDataStartsEmpty() {
    let defaults = UserDefaults(suiteName: "RecentsStoreTests-\(UUID().uuidString)")!
    defaults.set(Data("nope".utf8), forKey: RecentsStore.key)
    #expect(makeStore(defaults).entries.isEmpty)
}
