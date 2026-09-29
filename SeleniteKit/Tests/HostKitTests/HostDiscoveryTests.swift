import Foundation
import Testing
@testable import HostKit

private final class FakeBrowser: ServiceBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<BrowseEvent>.Continuation?

    func events() -> AsyncStream<BrowseEvent> {
        AsyncStream { continuation in lock.withLock { self.continuation = continuation } }
    }

    func emit(_ event: BrowseEvent) { _ = lock.withLock { continuation }?.yield(event) }
}

private final class FakePlainProbe: PlainServerInfoProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: ServerInfo] = [:]

    func set(_ address: String, id: String, name: String) throws {
        let xml = "<root status_code=\"200\"><hostname>\(name)</hostname><appversion>7.1.431.-1</appversion>"
            + "<uniqueid>\(id)</uniqueid><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>"
        let info = try ServerInfo(NvResponse.parse(Data(xml.utf8)).requireOK())
        lock.withLock { answers[address] = info }
    }

    func serverInfo(at address: String) async throws -> ServerInfo {
        guard let info = lock.withLock({ answers[address] }) else { throw URLError(.cannotConnectToHost) }
        return info
    }
}

private final class MoveLog { var count = 0 }

@MainActor private func makeDiscovery(saved: [PairedHost] = []) -> (HostDiscovery, FakeBrowser, FakePlainProbe, HostStore, MoveLog) {
    let store = HostStore(defaults: UserDefaults(suiteName: "HostDiscoveryTests-\(UUID().uuidString)")!)
    saved.forEach(store.save)
    let browser = FakeBrowser()
    let probe = FakePlainProbe()
    let moves = MoveLog()
    let discovery = HostDiscovery(browser: browser, probe: probe, store: store, onKnownHostMoved: { moves.count += 1 })
    return (discovery, browser, probe, store, moves)
}

private func paired(_ id: String, at address: String) -> PairedHost {
    PairedHost(id: id, name: "PC \(id)", address: address, httpsPort: 47984, serverCertificateDER: Data([1]))
}

@MainActor @Test func anUnknownHostIsDiscoveredAndGoneWhenItsServiceGoes() async throws {
    let (discovery, browser, probe, _, _) = makeDiscovery()
    try probe.set("192.168.1.20", id: "NEW", name: "GAMING-PC")
    discovery.start()
    browser.emit(.found(service: "GAMING-PC", address: "192.168.1.20"))
    let found = await eventually { discovery.discovered == [DiscoveredHost(id: "NEW", name: "GAMING-PC", address: "192.168.1.20")] }
    #expect(found)
    browser.emit(.lost(service: "GAMING-PC"))
    let gone = await eventually { discovery.discovered.isEmpty }
    #expect(gone)
}

@MainActor @Test func aKnownHostAtANewIPIsMovedNotDiscovered() async throws {
    let (discovery, browser, probe, store, moves) = makeDiscovery(saved: [paired("A", at: "192.168.1.20")])
    try probe.set("192.168.1.33", id: "A", name: "PC A")
    discovery.start()
    browser.emit(.found(service: "PC A", address: "192.168.1.33"))
    let moved = await eventually { store.all().first?.address == "192.168.1.33" }
    #expect(moved)
    #expect(moves.count == 1)
    #expect(discovery.discovered.isEmpty)
}

@MainActor @Test func aKnownHostSavedByNameKeepsItsName() async throws {
    let (discovery, browser, probe, store, moves) = makeDiscovery(saved: [paired("A", at: "gaming-pc.local")])
    try probe.set("192.168.1.33", id: "A", name: "PC A")
    discovery.start()
    browser.emit(.found(service: "PC A", address: "192.168.1.33"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(store.all().first?.address == "gaming-pc.local")
    #expect(moves.count == 0)
    #expect(discovery.discovered.isEmpty)
}

@MainActor @Test func aServiceThatDoesNotAnswerIsNotShown() async throws {
    let (discovery, browser, probe, _, _) = makeDiscovery()
    try probe.set("192.168.1.21", id: "OTHER", name: "OTHER")
    discovery.start()
    browser.emit(.found(service: "SILENT", address: "192.168.1.20"))
    browser.emit(.found(service: "OTHER", address: "192.168.1.21"))
    let one = await eventually { discovery.discovered.map(\.id) == ["OTHER"] }
    #expect(one)
}

@MainActor @Test func aHostPairedMeanwhileLeavesTheList() async throws {
    let (discovery, browser, probe, store, _) = makeDiscovery()
    try probe.set("192.168.1.20", id: "NEW", name: "GAMING-PC")
    discovery.start()
    browser.emit(.found(service: "GAMING-PC", address: "192.168.1.20"))
    _ = await eventually { !discovery.discovered.isEmpty }
    store.save(paired("NEW", at: "192.168.1.20"))
    discovery.storeChanged()
    #expect(discovery.discovered.isEmpty)
}

@MainActor @Test func stopClearsTheList() async throws {
    let (discovery, browser, probe, _, _) = makeDiscovery()
    try probe.set("192.168.1.20", id: "NEW", name: "GAMING-PC")
    discovery.start()
    browser.emit(.found(service: "GAMING-PC", address: "192.168.1.20"))
    _ = await eventually { !discovery.discovered.isEmpty }
    discovery.stop()
    #expect(discovery.discovered.isEmpty)
    #expect(!discovery.isRunning)
}

/// Polls `condition` every 5 ms for up to 2 s; true as soon as it holds.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
