import Foundation
import Observation

public enum HostStatus: Equatable, Sendable {
    /// Not asked yet.
    case unknown
    case offline
    case online
    /// A game is running on the host (`currentgame` is set). serverinfo cannot tell whether
    /// another client is watching it; Selenite resumes that game in one click either way.
    case busy
}

public struct HostSnapshot: Equatable, Sendable, Identifiable {
    public var host: PairedHost
    public var status: HostStatus
    /// The app id Sunshine reports as running, 0 when none or not known yet.
    public var currentGame: Int
    /// serverinfo's `ServerCodecModeSupport`, 0 until the host answered once.
    public var codecModeSupport: Int32

    public var id: String { host.id }

    public init(host: PairedHost, status: HostStatus = .unknown, currentGame: Int = 0, codecModeSupport: Int32 = 0) {
        self.host = host
        self.status = status
        self.currentGame = currentGame
        self.codecModeSupport = codecModeSupport
    }

    /// nil (no answer) or an answer from another PC at this address both read as offline.
    public mutating func apply(_ info: ServerInfo?) {
        guard let info, info.uniqueID.isEmpty || info.uniqueID == host.id else {
            status = .offline
            currentGame = 0
            return
        }
        currentGame = info.currentGame
        codecModeSupport = info.codecModeSupport
        status = info.currentGame != 0 || info.isBusy ? .busy : .online
    }
}

public protocol ServerInfoProbe: Sendable {
    func serverInfo(for host: PairedHost) async throws -> ServerInfo
}

/// serverinfo over HTTPS with the host's pinned certificate: the paired answer carries
/// `currentgame`, which the plain HTTP answer does not reliably do.
public struct LiveServerInfoProbe: ServerInfoProbe {
    private let uniqueID: String
    private let clients: NvHTTPClientFactory

    public init(uniqueID: String, clients: NvHTTPClientFactory) {
        self.uniqueID = uniqueID
        self.clients = clients
    }

    public func serverInfo(for host: PairedHost) async throws -> ServerInfo {
        let client = clients.make(pinnedCertificate: host.serverCertificateDER)
        defer { client.invalidate() }
        let endpoints = NvEndpoints(address: host.address, httpsPort: host.httpsPort, uniqueID: uniqueID)
        return try ServerInfo(NvResponse.parse(try await client.get(endpoints.serverInfo(secure: true), timeout: 3)).requireOK())
    }
}

/// The saved hosts plus their live status. Polls on demand; knows nothing about UI.
@MainActor @Observable
public final class HostDirectory {
    public private(set) var hosts: [HostSnapshot] = []
    private let store: HostStore
    private let probe: any ServerInfoProbe
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    public init(store: HostStore, probe: any ServerInfoProbe) {
        self.store = store
        self.probe = probe
        reload()
    }

    public var isPolling: Bool { pollTask != nil }

    public func snapshot(id: String) -> HostSnapshot? {
        hosts.first { $0.id == id }
    }

    /// Re-reads the saved hosts; a host that stays keeps its live status.
    public func reload() {
        let previous = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hosts = store.all().map { host in
            var snapshot = previous[host.id] ?? HostSnapshot(host: host)
            snapshot.host = host
            return snapshot
        }
    }

    /// Every status goes back to unknown (the app left, so what it saw may be stale); the codecs stay.
    public func forgetStatus() {
        for index in hosts.indices {
            hosts[index].status = .unknown
            hosts[index].currentGame = 0
        }
    }

    public func remove(id: String) {
        store.remove(id: id)
        reload()
    }

    /// Asks every host once, concurrently. A refresh cancelled on the way (polling stopped because
    /// a stream starts or the app leaves) changes nothing: its probes failed from the cancellation,
    /// not because the hosts went away.
    public func refresh() async {
        let probe = self.probe
        let targets = hosts.map(\.host)
        let answers = await withTaskGroup(of: (String, ServerInfo?).self) { group in
            for host in targets {
                group.addTask { (host.id, try? await probe.serverInfo(for: host)) }
            }
            var collected: [String: ServerInfo?] = [:]
            for await (id, info) in group { collected[id] = info }
            return collected
        }
        guard !Task.isCancelled else { return }
        for index in hosts.indices {
            guard let answer = answers[hosts[index].id] else { continue }
            hosts[index].apply(answer)
            if let info = answer, info.uniqueID == hosts[index].id,
               let mac = info.macAddress?.description, mac != hosts[index].host.macAddress {
                hosts[index].host.macAddress = mac
                store.update(hosts[index].host)
            }
        }
    }

    /// Refreshes now and then every `interval` until `stopPolling()`. Idempotent.
    public func startPolling(every interval: Duration = .seconds(5)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
