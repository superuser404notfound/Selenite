import Foundation
import Observation
import StreamKit

/// The global stream settings (M1-B spec, section 4.3) and the last selected host, in UserDefaults.
/// A stored value that no longer parses falls back to its default.
@MainActor @Observable
public final class SettingsStore {
    public private(set) var preferences: StreamPreferences
    public private(set) var selectedHostID: String?
    private let defaults: UserDefaults

    enum Key {
        static let resolution = "settings.resolution"
        static let frameRate = "settings.frameRate"
        static let bitrate = "settings.bitrateMbps"
        static let codec = "settings.codec"
        static let audio = "settings.audio"
        static let stats = "settings.stats"
        static let pacing = "settings.pacing"
        static let directPresent = "settings.directPresent"
        static let recordPacerTraces = "settings.recordPacerTraces"
        static let selectedHost = "home.selectedHostID"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(from: defaults)
        self.selectedHostID = defaults.string(forKey: Key.selectedHost)
    }

    public func set<Value>(_ keyPath: WritableKeyPath<StreamPreferences, Value>, _ value: Value) {
        preferences[keyPath: keyPath] = value
        save()
    }

    public func setSelectedHostID(_ id: String?) {
        selectedHostID = id
        defaults.set(id, forKey: Key.selectedHost)
    }

    static func load(from defaults: UserDefaults) -> StreamPreferences {
        var preferences = StreamPreferences()
        if let value = defaults.string(forKey: Key.resolution).flatMap(ResolutionPreference.init(rawValue:)) {
            preferences.resolution = value
        }
        if let value = defaults.string(forKey: Key.frameRate).flatMap(FrameRatePreference.init(rawValue:)) {
            preferences.frameRate = value
        }
        let bitrate = defaults.integer(forKey: Key.bitrate)
        if StreamPreferences.bitrateChoicesMbps.contains(bitrate) {
            preferences.bitrateMbps = bitrate
        }
        if let value = defaults.string(forKey: Key.codec).flatMap(CodecPreference.init(rawValue:)) {
            preferences.codec = value
        }
        if let value = defaults.string(forKey: Key.audio).flatMap(AudioPreference.init(rawValue:)) {
            preferences.audio = value
        }
        if let value = defaults.string(forKey: Key.stats).flatMap(StatsPreference.init(rawValue:)) {
            preferences.stats = value
        }
        if let value = defaults.string(forKey: Key.pacing).flatMap(FramePacingMode.init(rawValue:)) {
            preferences.pacing = value
        }
        if let value = defaults.object(forKey: Key.directPresent) as? Bool {
            preferences.directPresent = value
        }
        if let value = defaults.object(forKey: Key.recordPacerTraces) as? Bool {
            preferences.recordPacerTraces = value
        }
        return preferences
    }

    private func save() {
        defaults.set(preferences.resolution.rawValue, forKey: Key.resolution)
        defaults.set(preferences.frameRate.rawValue, forKey: Key.frameRate)
        defaults.set(preferences.bitrateMbps, forKey: Key.bitrate)
        defaults.set(preferences.codec.rawValue, forKey: Key.codec)
        defaults.set(preferences.audio.rawValue, forKey: Key.audio)
        defaults.set(preferences.stats.rawValue, forKey: Key.stats)
        defaults.set(preferences.pacing.rawValue, forKey: Key.pacing)
        defaults.set(preferences.directPresent, forKey: Key.directPresent)
        defaults.set(preferences.recordPacerTraces, forKey: Key.recordPacerTraces)
    }
}
