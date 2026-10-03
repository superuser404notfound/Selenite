import Foundation
import StreamKit
import Testing
@testable import AppCore

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "HostSettingsStoreTests-\(UUID().uuidString)")!
}

@MainActor @Test func aHostWithoutOverridesHasEmptyOnes() {
    let store = HostSettingsStore(defaults: freshDefaults())
    #expect(store.overrides(for: "H1").isEmpty)
    #expect(!store.hasOverrides(hostID: "H1"))
}

@MainActor @Test func overridesPersistPerHost() {
    let defaults = freshDefaults()
    let store = HostSettingsStore(defaults: defaults)
    var overrides = HostOverrides()
    overrides.bitrateMbps = 50
    store.set(overrides, for: "H1")
    let reloaded = HostSettingsStore(defaults: defaults)
    #expect(reloaded.overrides(for: "H1") == overrides)
    #expect(reloaded.hasOverrides(hostID: "H1"))
    #expect(reloaded.overrides(for: "H2").isEmpty)
}

@MainActor @Test func settingEmptyOverridesRemovesTheEntry() {
    let defaults = freshDefaults()
    let store = HostSettingsStore(defaults: defaults)
    var overrides = HostOverrides()
    overrides.codec = .hevc
    store.set(overrides, for: "H1")
    store.set(HostOverrides(), for: "H1")
    #expect(!store.hasOverrides(hostID: "H1"))
    #expect(!HostSettingsStore(defaults: defaults).hasOverrides(hostID: "H1"))
}

@MainActor @Test func removingAHostClearsItsOverrides() {
    let defaults = freshDefaults()
    let store = HostSettingsStore(defaults: defaults)
    var overrides = HostOverrides()
    overrides.audio = .stereo
    store.set(overrides, for: "H1")
    store.set(overrides, for: "H2")
    store.remove(hostID: "H1")
    let reloaded = HostSettingsStore(defaults: defaults)
    #expect(!reloaded.hasOverrides(hostID: "H1"))
    #expect(reloaded.hasOverrides(hostID: "H2"))
}

@MainActor @Test func aCorruptStoreLoadsEmpty() {
    let defaults = freshDefaults()
    defaults.set(Data("not json".utf8), forKey: HostSettingsStore.key)
    #expect(HostSettingsStore(defaults: defaults).overrides(for: "H1").isEmpty)
}
