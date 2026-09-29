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
    let file = AppCatalog(source: online, cacheDirectory: directory).fileURL(hostID: "HOST-1", appID: 7)
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

@MainActor @Test func theHostIDNeverReachesThePathAsIs() {
    // The uniqueID comes from an unauthenticated reply: "../" must not climb out of the cache.
    let directory = temporaryDirectory()
    let catalog = AppCatalog(source: FakeCatalogSource(), cacheDirectory: directory)
    let file = catalog.fileURL(hostID: "../../escape", appID: 7)
    let folder: String = file.deletingLastPathComponent().lastPathComponent
    let parent: String = file.deletingLastPathComponent().deletingLastPathComponent().path
    #expect(parent == directory.path)
    #expect(folder.count == 64)
    #expect(!folder.contains("."))
}

@MainActor @Test func forgettingAHostDropsItsAppsAndArt() async {
    let directory = temporaryDirectory()
    let source = FakeCatalogSource()
    source.setArt(png)
    source.setApps([desktop])
    let catalog = AppCatalog(source: source, cacheDirectory: directory)
    await catalog.loadApps(for: host)
    _ = await catalog.boxArt(for: host, appID: 7)
    let folder = catalog.fileURL(hostID: host.id, appID: 7).deletingLastPathComponent()
    catalog.forget(hostID: host.id)
    let apps: [AppEntry]? = catalog.apps[host.id]
    let folderExists: Bool = FileManager.default.fileExists(atPath: folder.path)
    #expect(apps == nil)
    #expect(!folderExists)
    source.setArt(nil)
    let art = await catalog.boxArt(for: host, appID: 7)
    #expect(art == nil)
}

@MainActor @Test func appListsPersistAcrossLaunches() async {
    let source = FakeCatalogSource()
    source.setApps([desktop])
    let directory = temporaryDirectory()
    await AppCatalog(source: source, cacheDirectory: directory).loadApps(for: host)
    let relaunched = AppCatalog(source: FakeCatalogSource(), cacheDirectory: directory)
    relaunched.restoreApps(for: host.id)
    #expect(relaunched.apps[host.id] == [desktop])
}

@MainActor @Test func aRestoredListNeverReplacesALoadedOne() async {
    let directory = temporaryDirectory()
    let old = FakeCatalogSource()
    old.setApps([desktop])
    await AppCatalog(source: old, cacheDirectory: directory).loadApps(for: host)
    let fresh = FakeCatalogSource()
    let steam = AppEntry(id: 2, title: "Steam Big Picture", supportsHDR: false)
    fresh.setApps([steam])
    let catalog = AppCatalog(source: fresh, cacheDirectory: directory)
    await catalog.loadApps(for: host)
    catalog.restoreApps(for: host.id)
    #expect(catalog.apps[host.id] == [steam])
}

@MainActor @Test func forgettingAHostDropsItsSavedList() async {
    let source = FakeCatalogSource()
    source.setApps([desktop])
    let directory = temporaryDirectory()
    let catalog = AppCatalog(source: source, cacheDirectory: directory)
    await catalog.loadApps(for: host)
    catalog.forget(hostID: host.id)
    let relaunched = AppCatalog(source: source, cacheDirectory: directory)
    relaunched.restoreApps(for: host.id)
    #expect(relaunched.apps[host.id] == nil)
}

@Test func imageSignatures() {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    #expect(AppCatalog.looksLikeImage(png))
    #expect(AppCatalog.looksLikeImage(jpeg))
    #expect(!AppCatalog.looksLikeImage(Data("<root/>".utf8)))
    #expect(!AppCatalog.looksLikeImage(Data()))
}
