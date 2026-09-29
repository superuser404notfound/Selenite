import Foundation
import HostKit
import Observation

public struct RecentEntry: Codable, Sendable, Equatable, Identifiable {
    public let hostID: String
    public let app: AppEntry
    public let lastPlayed: Date

    public var id: String { "\(hostID)/\(app.id)" }

    public init(hostID: String, app: AppEntry, lastPlayed: Date) {
        self.hostID = hostID
        self.app = app
        self.lastPlayed = lastPlayed
    }
}

/// "Recently played" across all hosts (M1-C spec, section 5): newest first, one entry per host
/// and app, at most `limit`, in UserDefaults.
@MainActor @Observable
public final class RecentsStore {
    public static let limit = 10
    static let key = "home.recents"

    public private(set) var entries: [RecentEntry]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([RecentEntry].self, from: $0) } ?? []
    }

    public func record(hostID: String, app: AppEntry, at date: Date = .now) {
        let entry = RecentEntry(hostID: hostID, app: app, lastPlayed: date)
        entries = Array(([entry] + entries.filter { $0.id != entry.id }).prefix(Self.limit))
        save()
    }

    public func remove(_ entry: RecentEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    public func removeAll(hostID: String) {
        entries.removeAll { $0.hostID == hostID }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}
