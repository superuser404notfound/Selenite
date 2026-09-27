import Foundation
import Observation

public protocol AppCatalogSource: Sendable {
    func apps(on host: PairedHost) async throws -> [AppEntry]
    func boxArt(on host: PairedHost, appID: Int) async throws -> Data
}

/// /applist and /appasset over HTTPS with the host's pinned certificate.
public struct LiveAppCatalogSource: AppCatalogSource {
    private let uniqueID: String
    private let clients: NvHTTPClientFactory

    public init(uniqueID: String, clients: NvHTTPClientFactory) {
        self.uniqueID = uniqueID
        self.clients = clients
    }

    public func apps(on host: PairedHost) async throws -> [AppEntry] {
        let client = clients.make(pinnedCertificate: host.serverCertificateDER)
        defer { client.invalidate() }
        return AppEntry.list(try NvResponse.parse(try await client.get(endpoints(for: host).appList(), timeout: 10)).requireOK())
    }

    public func boxArt(on host: PairedHost, appID: Int) async throws -> Data {
        let client = clients.make(pinnedCertificate: host.serverCertificateDER)
        defer { client.invalidate() }
        return try await client.get(endpoints(for: host).appAsset(appID: appID), timeout: 10)
    }

    private func endpoints(for host: PairedHost) -> NvEndpoints {
        NvEndpoints(address: host.address, httpsPort: host.httpsPort, uniqueID: uniqueID)
    }
}

/// App lists per host and box art cached in memory and on disk
/// (`Library/Caches/boxart/<hostID>/<appID>.png`). Art that could not be fetched is remembered as
/// missing until the host's app list loads again, so an offline host is not asked on every redraw
/// and a host that comes back gets its art.
@MainActor @Observable
public final class AppCatalog {
    public private(set) var apps: [String: [AppEntry]] = [:]
    public private(set) var failedHosts: Set<String> = []
    private let source: any AppCatalogSource
    private let directory: URL
    @ObservationIgnored private var memory: [String: Data] = [:]
    @ObservationIgnored private var misses: Set<String> = []

    public init(source: any AppCatalogSource, cacheDirectory: URL) {
        self.source = source
        self.directory = cacheDirectory
    }

    public static func defaultCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boxart", isDirectory: true)
    }

    public func loadApps(for host: PairedHost) async {
        do {
            apps[host.id] = try await source.apps(on: host)
            failedHosts.remove(host.id)
            misses = misses.filter { !$0.hasPrefix(host.id + "/") }
        } catch {
            failedHosts.insert(host.id)
        }
    }

    public func boxArt(for host: PairedHost, appID: Int) async -> Data? {
        let key = "\(host.id)/\(appID)"
        if let data = memory[key] { return data }
        if misses.contains(key) { return nil }
        let file = fileURL(hostID: host.id, appID: appID)
        if let data = FileManager.default.contents(atPath: file.path), Self.looksLikeImage(data) {
            memory[key] = data
            return data
        }
        guard let data = try? await source.boxArt(on: host, appID: appID), Self.looksLikeImage(data) else {
            misses.insert(key)
            return nil
        }
        memory[key] = data
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    public func fileURL(hostID: String, appID: Int) -> URL {
        directory.appendingPathComponent(hostID, isDirectory: true).appendingPathComponent("\(appID).png")
    }

    /// PNG or JPEG signature. Sunshine answers a missing asset with an XML error body.
    nonisolated public static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 4, bytes == [0x89, 0x50, 0x4E, 0x47] { return true }
        return bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
    }
}
