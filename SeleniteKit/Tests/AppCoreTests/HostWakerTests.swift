import Foundation
import HostKit
import Testing
@testable import AppCore

private final class WakeProbe: ServerInfoProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let answerFrom: Int
    private let reply: ServerInfo

    init(answerFrom: Int, id: String) throws {
        self.answerFrom = answerFrom
        let xml = "<root status_code=\"200\"><appversion>7.1.431.-1</appversion><uniqueid>\(id)</uniqueid>"
            + "<PairStatus>1</PairStatus><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>"
        self.reply = try ServerInfo(NvResponse.parse(Data(xml.utf8)).requireOK())
    }

    var calls: Int { lock.withLock { _calls } }

    func serverInfo(for host: PairedHost) async throws -> ServerInfo {
        let call = lock.withLock { () -> Int in _calls += 1; return _calls }
        guard call >= answerFrom else { throw URLError(.cannotConnectToHost) }
        return reply
    }
}

/// Holds the first serverinfo until `release()`, then answers it: the answer arrives after a cancel.
private final class GateProbe: ServerInfoProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var _answered = false
    private let reply: ServerInfo

    init(id: String) throws {
        let xml = "<root status_code=\"200\"><appversion>7.1.431.-1</appversion><uniqueid>\(id)</uniqueid>"
            + "<PairStatus>1</PairStatus><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>"
        self.reply = try ServerInfo(NvResponse.parse(Data(xml.utf8)).requireOK())
    }

    var isWaiting: Bool { lock.withLock { continuation != nil } }
    var hasAnswered: Bool { lock.withLock { _answered } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }

    func serverInfo(for host: PairedHost) async throws -> ServerInfo {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        lock.withLock { _answered = true }
        return reply
    }
}

private final class SendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    var hosts: [String] { lock.withLock { _hosts } }
    func add(_ id: String) { lock.withLock { _hosts.append(id) } }
}

private let sleeper = PairedHost(id: "H", name: "PC", address: "10.0.0.2", httpsPort: 47984,
                                 serverCertificateDER: Data([1]), macAddress: "00:11:22:33:44:55")

@MainActor private func makeWaker(_ probe: WakeProbe, _ log: SendLog, timeout: Duration = .seconds(2)) -> HostWaker {
    HostWaker(send: { log.add($0.id) }, probe: probe, interval: .milliseconds(10), timeout: timeout)
}

@MainActor @Test func wakingSendsOnceAndEndsAwakeWhenTheHostAnswers() async throws {
    let probe = try WakeProbe(answerFrom: 3, id: "H")
    let log = SendLog()
    let waker = makeWaker(probe, log)
    var outcomes: [WakeOutcome] = []
    waker.wake(sleeper) { outcomes.append($0) }
    #expect(waker.wakingHostID == "H")
    let ended = await eventually { !outcomes.isEmpty }
    #expect(ended)
    #expect(outcomes == [.awake])
    #expect(log.hosts == ["H"])
    #expect(probe.calls == 3)
    #expect(waker.wakingHostID == nil)
}

@MainActor @Test func wakingTimesOut() async throws {
    let probe = try WakeProbe(answerFrom: .max, id: "H")
    let waker = makeWaker(probe, SendLog(), timeout: .milliseconds(80))
    var outcomes: [WakeOutcome] = []
    waker.wake(sleeper) { outcomes.append($0) }
    let ended = await eventually { !outcomes.isEmpty }
    #expect(ended)
    #expect(outcomes == [.timedOut])
    #expect(waker.wakingHostID == nil)
}

@MainActor @Test func cancelEndsOnceAndALateAnswerIsIgnored() async throws {
    let probe = try GateProbe(id: "H")
    let waker = HostWaker(send: { _ in }, probe: probe, interval: .milliseconds(10), timeout: .seconds(2))
    var outcomes: [WakeOutcome] = []
    waker.wake(sleeper) { outcomes.append($0) }
    let asking = await eventually { probe.isWaiting }
    #expect(asking)
    waker.cancel()
    #expect(outcomes == [.cancelled])
    #expect(waker.wakingHostID == nil)
    probe.release()
    let answered = await eventually { probe.hasAnswered }
    #expect(answered)
    try await Task.sleep(for: .milliseconds(50))
    #expect(outcomes == [.cancelled])
}

@MainActor @Test func aSecondWakeCancelsTheFirst() async throws {
    let probe = try WakeProbe(answerFrom: .max, id: "H")
    let waker = makeWaker(probe, SendLog())
    var first: [WakeOutcome] = []
    waker.wake(sleeper) { first.append($0) }
    waker.wake(sleeper) { _ in }
    #expect(first == [.cancelled])
    waker.cancel()
}

@Test func onlyAHostWithAUsableMACCanBeWoken() {
    #expect(HostWaker.canWake(sleeper))
    var noMAC = sleeper
    noMAC.macAddress = nil
    #expect(!HostWaker.canWake(noMAC))
    noMAC.macAddress = "00:00:00:00:00:00"
    #expect(!HostWaker.canWake(noMAC))
}
