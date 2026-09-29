import Darwin
import Foundation
import Observation

public struct DiscoveredHost: Sendable, Equatable, Identifiable {
    /// The host's uniqueID.
    public let id: String
    public let name: String
    public let address: String

    public init(id: String, name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }
}

public enum BrowseEvent: Sendable, Equatable {
    case found(service: String, address: String)
    case lost(service: String)
}

public protocol ServiceBrowsing: Sendable {
    /// Ends, and stops browsing, when the consumer stops iterating.
    func events() -> AsyncStream<BrowseEvent>
}

public protocol PlainServerInfoProbe: Sendable {
    func serverInfo(at address: String) async throws -> ServerInfo
}

/// Plain-HTTP serverinfo: enough for the uniqueID and name of a host that is not paired yet.
public struct LivePlainServerInfoProbe: PlainServerInfoProbe {
    private let uniqueID: String
    private let clients: NvHTTPClientFactory

    public init(uniqueID: String, clients: NvHTTPClientFactory) {
        self.uniqueID = uniqueID
        self.clients = clients
    }

    public func serverInfo(at address: String) async throws -> ServerInfo {
        let client = clients.make(pinnedCertificate: nil)
        defer { client.invalidate() }
        let endpoints = NvEndpoints(address: address, uniqueID: uniqueID)
        return try ServerInfo(NvResponse.parse(try await client.get(endpoints.serverInfo(secure: false), timeout: 3)).requireOK())
    }
}

/// Sunshine hosts announced over Bonjour (M1-C spec, section 3). A paired host found at a new IP
/// gets that IP once its pinned certificate answers there; a host saved by name keeps the name.
/// Every other host that answers serverinfo is published in `discovered`.
@MainActor @Observable
public final class HostDiscovery {
    public private(set) var discovered: [DiscoveredHost] = []
    private let browser: any ServiceBrowsing
    private let probe: any PlainServerInfoProbe
    private let pinnedProbe: any ServerInfoProbe
    private let store: HostStore
    private let onKnownHostMoved: @MainActor () -> Void
    @ObservationIgnored private var byService: [String: DiscoveredHost] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var browseGeneration = 0

    public init(browser: any ServiceBrowsing, probe: any PlainServerInfoProbe, pinnedProbe: any ServerInfoProbe,
                store: HostStore, onKnownHostMoved: @escaping @MainActor () -> Void) {
        self.browser = browser
        self.probe = probe
        self.pinnedProbe = pinnedProbe
        self.store = store
        self.onKnownHostMoved = onKnownHostMoved
    }

    public var isRunning: Bool { task != nil }

    public func start() {
        guard task == nil else { return }
        browseGeneration += 1
        let generation = browseGeneration
        let events = browser.events()
        task = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
            self?.browseEnded(generation: generation)
        }
    }

    /// Paused hosts are forgotten: the browser reports every present service again on the next start.
    public func stop() {
        task?.cancel()
        task = nil
        byService = [:]
        publish()
    }

    /// The browser's stream ended on its own (a failed browse, missing entitlement, ...), not
    /// through `stop()`: clear `task` so a later `start()` tries again. A loop from an older
    /// generation ending after a `stop()`/`start()` cycle must never clear the new task.
    private func browseEnded(generation: Int) {
        guard generation == browseGeneration, task != nil else { return }
        task = nil
    }

    /// A host was paired or removed: a paired one leaves the list.
    public func storeChanged() {
        publish()
    }

    private func handle(_ event: BrowseEvent) async {
        switch event {
        case .lost(let service):
            byService[service] = nil
        case .found(let service, let address):
            guard let info = try? await probe.serverInfo(at: address), !info.uniqueID.isEmpty,
                  !Task.isCancelled, task != nil else { return }
            if let known = store.all().first(where: { $0.id == info.uniqueID }) {
                byService[service] = nil
                if known.address != address, Self.isIPLiteral(known.address) {
                    await moveIfPinned(known, to: address)
                }
            } else {
                byService[service] = DiscoveredHost(id: info.uniqueID, name: info.hostname.isEmpty ? service : info.hostname,
                                                    address: address)
            }
        }
        publish()
    }

    /// The plain answer is unauthenticated, so anyone on the LAN could claim the uniqueID: the host
    /// moves only when its pinned certificate answers at the new address with the same uniqueID.
    private func moveIfPinned(_ known: PairedHost, to address: String) async {
        var candidate = known
        candidate.address = address
        guard let pinned = try? await pinnedProbe.serverInfo(for: candidate), pinned.uniqueID == known.id,
              !Task.isCancelled, task != nil,
              var current = store.all().first(where: { $0.id == known.id }), Self.isIPLiteral(current.address),
              current.address != address else { return }
        current.address = address
        store.update(current)
        onKnownHostMoved()
    }

    private func publish() {
        let paired = Set(store.all().map(\.id))
        var seen = Set<String>()
        discovered = byService.values
            .filter { !paired.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func isIPLiteral(_ address: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1
    }
}
