import Foundation
import Testing
@testable import HostKit

private final class FakeProbe: ServerInfoProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: ServerInfo] = [:]
    private var _delay: Duration = .zero
    private var _calls = 0

    var calls: Int { lock.withLock { _calls } }
    func set(_ id: String, _ info: ServerInfo?) { lock.withLock { answers[id] = info } }
    func setDelay(_ delay: Duration) { lock.withLock { _delay = delay } }

    func serverInfo(for host: PairedHost) async throws -> ServerInfo {
        let delay = lock.withLock { () -> Duration in
            _calls += 1
            return _delay
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let info = lock.withLock({ answers[host.id] }) else { throw URLError(.cannotConnectToHost) }
        return info
    }
}

private func info(id: String, currentGame: Int = 0, mac: String? = nil) throws -> ServerInfo {
    let state = currentGame == 0 ? "SUNSHINE_SERVER_FREE" : "SUNSHINE_SERVER_BUSY"
    let xml = "<root status_code=\"200\"><hostname>PC</hostname><appversion>7.1.431.-1</appversion>"
        + "<uniqueid>\(id)</uniqueid><ServerCodecModeSupport>259</ServerCodecModeSupport>"
        + "<PairStatus>1</PairStatus><currentgame>\(currentGame)</currentgame><state>\(state)</state>"
        + (mac.map { "<mac>\($0)</mac>" } ?? "") + "</root>"
    return try ServerInfo(NvResponse.parse(Data(xml.utf8)).requireOK())
}

@MainActor private func makeDirectory(_ ids: [String]) -> (HostDirectory, FakeProbe, HostStore) {
    let store = HostStore(defaults: UserDefaults(suiteName: "HostDirectoryTests-\(UUID().uuidString)")!)
    for (index, id) in ids.enumerated() {
        store.save(PairedHost(id: id, name: "PC \(id)", address: "10.0.0.\(index + 2)", httpsPort: 47984,
                              serverCertificateDER: Data([1])))
    }
    let probe = FakeProbe()
    return (HostDirectory(store: store, probe: probe), probe, store)
}

@MainActor @Test func savedHostsStartUnknown() {
    let (directory, _, _) = makeDirectory(["A", "B"])
    let ids: [String] = directory.hosts.map(\.id)
    let statuses: [HostStatus] = directory.hosts.map(\.status)
    #expect(ids == ["A", "B"])
    #expect(statuses == [.unknown, .unknown])
}

@MainActor @Test func onlineThenOffline() async throws {
    let (directory, probe, _) = makeDirectory(["A"])
    probe.set("A", try info(id: "A"))
    await directory.refresh()
    let online: HostStatus? = directory.snapshot(id: "A")?.status
    let codecs: Int32? = directory.snapshot(id: "A")?.codecModeSupport
    #expect(online == .online)
    #expect(codecs == 259)
    probe.set("A", nil)
    await directory.refresh()
    let offline: HostStatus? = directory.snapshot(id: "A")?.status
    #expect(offline == .offline)
}

@MainActor @Test func aRunningGameMakesTheHostBusyAndNamesTheGame() async throws {
    let (directory, probe, _) = makeDirectory(["A"])
    probe.set("A", try info(id: "A", currentGame: 42))
    await directory.refresh()
    let status: HostStatus? = directory.snapshot(id: "A")?.status
    let game: Int? = directory.snapshot(id: "A")?.currentGame
    #expect(status == .busy)
    #expect(game == 42)
}

@MainActor @Test func currentGameChangesAreTracked() async throws {
    let (directory, probe, _) = makeDirectory(["A"])
    probe.set("A", try info(id: "A", currentGame: 42))
    await directory.refresh()
    probe.set("A", try info(id: "A", currentGame: 7))
    await directory.refresh()
    let seven: Int? = directory.snapshot(id: "A")?.currentGame
    #expect(seven == 7)
    probe.set("A", try info(id: "A"))
    await directory.refresh()
    let idle: Int? = directory.snapshot(id: "A")?.currentGame
    let status: HostStatus? = directory.snapshot(id: "A")?.status
    #expect(idle == 0)
    #expect(status == .online)
}

@MainActor @Test func anotherPCAnsweringAtTheAddressCountsAsOffline() async throws {
    let (directory, probe, _) = makeDirectory(["A"])
    probe.set("A", try info(id: "SOMEONE-ELSE"))
    await directory.refresh()
    let status: HostStatus? = directory.snapshot(id: "A")?.status
    #expect(status == .offline)
}

@MainActor @Test func reloadKeepsTheStatusOfHostsThatStay() async throws {
    let (directory, probe, store) = makeDirectory(["A"])
    probe.set("A", try info(id: "A"))
    await directory.refresh()
    store.save(PairedHost(id: "B", name: "PC B", address: "10.0.0.9", httpsPort: 47984, serverCertificateDER: Data([2])))
    directory.reload()
    let statuses: [HostStatus] = directory.hosts.map(\.status)
    #expect(statuses == [.online, .unknown])
}

@MainActor @Test func removeForgetsTheHost() {
    let (directory, _, store) = makeDirectory(["A", "B"])
    directory.remove(id: "A")
    let ids: [String] = directory.hosts.map(\.id)
    let saved: [String] = store.all().map(\.id)
    #expect(ids == ["B"])
    #expect(saved == ["B"])
}

@MainActor @Test func aCancelledRefreshLeavesTheStatusAlone() async throws {
    // Review Focus 2: stopping the poll mid-refresh must not mark the host offline.
    let (directory, probe, _) = makeDirectory(["A"])
    probe.set("A", try info(id: "A"))
    await directory.refresh()
    probe.setDelay(.milliseconds(300))
    let refresh = Task { await directory.refresh() }
    try await Task.sleep(for: .milliseconds(30))
    refresh.cancel()
    await refresh.value
    let status: HostStatus? = directory.snapshot(id: "A")?.status
    #expect(status == .online)
}

@MainActor @Test func pollingRefreshesUntilStopped() async throws {
    let (directory, probe, _) = makeDirectory(["A"])
    probe.set("A", try info(id: "A"))
    directory.startPolling(every: .milliseconds(10))
    #expect(directory.isPolling)
    for _ in 0..<200 where probe.calls < 3 {
        try await Task.sleep(for: .milliseconds(5))
    }
    directory.stopPolling()
    let calls: Int = probe.calls
    #expect(calls >= 3)
    #expect(!directory.isPolling)
}

@MainActor @Test func aPollKeepsTheHostsMAC() async throws {
    let (directory, probe, store) = makeDirectory(["A", "B"])
    probe.set("A", try info(id: "A", mac: "00:11:22:33:44:55"))
    await directory.refresh()
    #expect(directory.snapshot(id: "A")?.host.macAddress == "00:11:22:33:44:55")
    #expect(store.all().map(\.id) == ["A", "B"])
    #expect(store.all().first?.macAddress == "00:11:22:33:44:55")
}

@MainActor @Test func aZeroMACNeverReplacesAKnownOne() async throws {
    let (directory, probe, store) = makeDirectory(["A"])
    probe.set("A", try info(id: "A", mac: "00:11:22:33:44:55"))
    await directory.refresh()
    probe.set("A", try info(id: "A", mac: "00:00:00:00:00:00"))
    await directory.refresh()
    #expect(store.all().first?.macAddress == "00:11:22:33:44:55")
}

@MainActor @Test func aHostRemovedDuringARefreshStaysRemoved() async throws {
    let (directory, probe, store) = makeDirectory(["A"])
    probe.set("A", try info(id: "A", mac: "00:11:22:33:44:55"))
    probe.setDelay(.milliseconds(100))
    let refresh = Task { await directory.refresh() }
    try await Task.sleep(for: .milliseconds(20))
    store.remove(id: "A")
    await refresh.value
    #expect(store.all().isEmpty)
}
