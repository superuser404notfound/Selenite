import Foundation
import Observation
import StreamKit

/// Per-host stream setting overrides (M3-A spec, section 3), one JSON map in UserDefaults.
@MainActor @Observable
public final class HostSettingsStore {
    static let key = "hostSettings.overrides"

    private var all: [String: HostOverrides]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: HostOverrides].self, from: $0) } ?? [:]
    }

    public func overrides(for hostID: String) -> HostOverrides {
        all[hostID] ?? HostOverrides()
    }

    public func hasOverrides(hostID: String) -> Bool {
        !(all[hostID]?.isEmpty ?? true)
    }

    public func set(_ overrides: HostOverrides, for hostID: String) {
        all[hostID] = overrides.isEmpty ? nil : overrides
        save()
    }

    public func remove(hostID: String) {
        guard all.removeValue(forKey: hostID) != nil else { return }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }
}
