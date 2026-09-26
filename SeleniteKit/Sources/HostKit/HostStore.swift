import Foundation

public final class HostStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "pairedHosts"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all() -> [PairedHost] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    public func save(_ host: PairedHost) {
        var hosts = all().filter { $0.id != host.id }
        hosts.append(host)
        write(hosts)
    }

    public func remove(id: String) {
        write(all().filter { $0.id != id })
    }

    private func write(_ hosts: [PairedHost]) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(try? JSONEncoder().encode(hosts), forKey: key)
    }
}
