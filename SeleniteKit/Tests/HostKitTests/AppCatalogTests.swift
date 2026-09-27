import Foundation
import Testing
@testable import HostKit

private final class FakeCatalogSource: AppCatalogSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _art: Data?
    private var _apps: [AppEntry]?
    private var _artRequests = 0

    var artRequests: Int { lock.withLock { _artRequests } }
    func setArt(_ data: Data?) { lock.withLock { _art = data } }
    func setApps(_ apps: [AppEntry]?) { lock.withLock { _apps = apps } }

    func apps(on host: PairedHost) async throws -> [AppEntry] {
        guard let apps = lock.withLock({ _apps }) else { throw URLError(.cannotConnectToHost) }
        return apps
    }

    func boxArt(on host: PairedHost, appID: Int) async throws -> Data {
        let art = lock.withLock { () -> Data? in
            _artRequests += 1
            return _art
        }
        guard let art else { throw URLError(.cannotConnectToHost) }
        return art
    }
}

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
private let host = PairedHost(id: "HOST-1", name: "PC", address: "10.0.0.2", httpsPort: 47984, serverCertificateDER: Data([1]))
private let desktop = AppEntry(id: 881448767, title: "Desktop", supportsHDR: false)

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("AppCatalogTests-\(UUID().uuidString)", isDirectory: true)
}

@MainActor @Test func aMemoryHitDoesNotAskTheHostAgain() async {
    let source = FakeCatalogSource()
    source.setArt(png)
    let catalog = AppCatalog(source: source, cacheDirectory: temporaryDirectory())
    let first = await catalog.boxArt(for: host, appID: 7)
    let second = await catalog.boxArt(for: host, appID: 7)
    let requests: Int = source.artRequests
    #expect(first == png)
    #expect(second == png)
    #expect(requests == 1)
}

@MainActor @Test func boxArtPersistsOnDiskAcrossLaunches() async {
    let directory = temporaryDirectory()
    let online = FakeCatalogSource()
    online.setArt(png)
    _ = await AppCatalog(source: online, cacheDirectory: directory).boxArt(for: host, appID: 7)
    let file = directory.appendingPathComponent("HOST-1").appendingPathComponent("7.png")
    let onDisk = FileManager.default.contents(atPath: file.path)
    #expect(onDisk == png)

    let offline = FakeCatalogSource()
    let relaunched = AppCatalog(source: offline, cacheDirectory: directory)
    let cached = await relaunched.boxArt(for: host, appID: 7)
    let requests: Int = offline.artRequests
    #expect(cached == png)
    #expect(requests == 0)
}

@MainActor @Test func missingArtIsNilAndNotAskedForAgain() async {
    let source = FakeCatalogSource()
    let catalog = AppCatalog(source: source, cacheDirectory: temporaryDirectory())
    let first = await catalog.boxArt(for: host, appID: 7)
    let second = await catalog.boxArt(for: host, appID: 7)
    let requests: Int = source.artRequests
    #expect(first == nil)
    #expect(second == nil)
    #expect(requests == 1)
}

@MainActor @Test func aReplyThatIsNotAnImageCountsAsMissing() async {
    let source = FakeCatalogSource()
    source.setArt(Data("<root status_code=\"404\"/>".utf8))
    let catalog = AppCatalog(source: source, cacheDirectory: temporaryDirectory())
    let art = await catalog.boxArt(for: host, appID: 7)
    #expect(art == nil)
}

@MainActor @Test func aSuccessfulAppListClearsRememberedMisses() async {
    // Review Focus 5: art asked for while the host was offline loads once it is back.
    let source = FakeCatalogSource()
    let catalog = AppCatalog(source: source, cacheDirectory: temporaryDirectory())
    let whileOffline = await catalog.boxArt(for: host, appID: 7)
    #expect(whileOffline == nil)
    source.setArt(png)
    source.setApps([desktop])
    await catalog.loadApps(for: host)
    let afterReturn = await catalog.boxArt(for: host, appID: 7)
    #expect(afterReturn == png)
}

@MainActor @Test func appListsLoadPerHostAndFailuresAreRemembered() async {
    let source = FakeCatalogSource()
    let catalog = AppCatalog(source: source, cacheDirectory: temporaryDirectory())
    await catalog.loadApps(for: host)
    #expect(catalog.failedHosts.contains("HOST-1"))
    #expect(catalog.apps["HOST-1"] == nil)
    source.setApps([desktop])
    await catalog.loadApps(for: host)
    let apps: [AppEntry]? = catalog.apps["HOST-1"]
    #expect(apps == [desktop])
    #expect(!catalog.failedHosts.contains("HOST-1"))
}

@Test func imageSignatures() {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    #expect(AppCatalog.looksLikeImage(png))
    #expect(AppCatalog.looksLikeImage(jpeg))
    #expect(!AppCatalog.looksLikeImage(Data("<root/>".utf8)))
    #expect(!AppCatalog.looksLikeImage(Data()))
}
