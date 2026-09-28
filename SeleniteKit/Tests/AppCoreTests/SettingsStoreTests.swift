import Foundation
import StreamKit
import Testing
@testable import AppCore

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "SettingsStoreTests-\(UUID().uuidString)")!
}

@MainActor @Test func aFreshStoreHasTheSpecDefaults() {
    let store = SettingsStore(defaults: freshDefaults())
    let preferences: StreamPreferences = store.preferences
    #expect(preferences == StreamPreferences())
    #expect(store.selectedHostID == nil)
}

@MainActor @Test func everySettingPersists() {
    let defaults = freshDefaults()
    let store = SettingsStore(defaults: defaults)
    store.set(\.resolution, .p1440)
    store.set(\.frameRate, .matchDisplay)
    store.set(\.bitrateMbps, 300)
    store.set(\.codec, .h264)
    store.set(\.audio, .stereo)
    store.set(\.stats, .compact)
    store.set(\.pacing, .smooth)
    store.set(\.directPresent, false)
    store.setSelectedHostID("HOST-1")
    var expected = StreamPreferences()
    expected.resolution = .p1440
    expected.frameRate = .matchDisplay
    expected.bitrateMbps = 300
    expected.codec = .h264
    expected.audio = .stereo
    expected.stats = .compact
    expected.pacing = .smooth
    expected.directPresent = false
    let reloaded = SettingsStore(defaults: defaults)
    let preferences: StreamPreferences = reloaded.preferences
    #expect(preferences == expected)
    #expect(reloaded.selectedHostID == "HOST-1")
}

@MainActor @Test func unknownStoredValuesFallBackToDefaults() {
    let defaults = freshDefaults()
    defaults.set("8K", forKey: "settings.resolution")
    defaults.set(123, forKey: "settings.bitrateMbps")
    defaults.set("vsync", forKey: "settings.pacing")
    defaults.set("yes", forKey: "settings.directPresent")
    let preferences: StreamPreferences = SettingsStore(defaults: defaults).preferences
    #expect(preferences == StreamPreferences())
}

@MainActor @Test func clearingTheSelectedHostPersists() {
    let defaults = freshDefaults()
    let store = SettingsStore(defaults: defaults)
    store.setSelectedHostID("HOST-1")
    store.setSelectedHostID(nil)
    #expect(SettingsStore(defaults: defaults).selectedHostID == nil)
}
