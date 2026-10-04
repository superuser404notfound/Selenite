import CoreMedia
import Foundation
import HostKit
import InputKit
import StreamKit
import Testing
@testable import AppCore

/// A session whose start() waits until a stop cancels it, and whose events the test sends by hand.
private final class FakeSession: StreamSessionHandle, @unchecked Sendable {
    let events: AsyncStream<StreamEvent>
    let pacer = FramePacer<CMSampleBuffer>()
    private let eventSink: AsyncStream<StreamEvent>.Continuation
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, any Error>?
    private var stopped = false
    private var _stopCount = 0
    private var _presented = 0
    private var _volume: Float?

    init() {
        (events, eventSink) = AsyncStream.makeStream()
    }

    var stopCount: Int { lock.withLock { _stopCount } }
    var volume: Float? { lock.withLock { _volume } }

    func send(_ event: StreamEvent) { eventSink.yield(event) }
    func sendMouseMove(dx: Int16, dy: Int16) {}
    func sendScroll(amount: Int16) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) {}
    func setVolume(_ volume: Float) { lock.withLock { _volume = volume } }
    func presentFirstFrame() { lock.withLock { _presented = 1 } }

    func start() async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            let alreadyStopped = lock.withLock { () -> Bool in
                if stopped { return true }
                gate = waiter
                return false
            }
            if alreadyStopped { waiter.resume(throwing: StreamSessionError.cancelled) }
        }
    }

    func stop() async {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            stopped = true
            _stopCount += 1
            defer { gate = nil }
            return gate
        }
        waiter?.resume(throwing: StreamSessionError.cancelled)
        eventSink.finish()
    }

    func stats() -> StreamStats {
        var pacer = PacerStats()
        pacer.presented = lock.withLock { _presented }
        return StreamStats(pacer: pacer)
    }
}

@MainActor private final class FakeSideInput: StreamInput {
    var forwarding: [Bool] = []
    var sessions: [ObjectIdentifier] = []
    func begin(session: any StreamSessionHandle) { sessions.append(ObjectIdentifier(session)) }
    func sessionConnected() {}
    func setForwarding(_ forwarding: Bool) { self.forwarding.append(forwarding) }
    func end() {}
}

@MainActor private final class FakeSplitInput: SplitInputHandle {
    var onEvent: (@MainActor (PadID, LobbyEvent) -> Void)?
    var onPadsChanged: (@MainActor (Set<PadID>) -> Void)?
    let sides: [SplitSide: FakeSideInput] = [.first: FakeSideInput(), .second: FakeSideInput()]
    var applied: [SeatMap] = []
    var reassigning: [Bool] = []
    var started = 0, stopped = 0
    func input(for side: SplitSide) -> any StreamInput { sides[side]! }
    func apply(_ seats: SeatMap) { applied.append(seats) }
    func setReassigning(_ reassigning: Bool) { self.reassigning.append(reassigning) }
    func start() { started += 1 }
    func stop() { stopped += 1 }
}

private final class FakeCommands: HostCommands, @unchecked Sendable {
    let error: (any Error)?
    init(error: (any Error)?) { self.error = error }
    func quitApp(on host: PairedHost) async throws {
        if let error { throw error }
    }
}

private final class Pad {
    var id: PadID { ObjectIdentifier(self) }
}

private let appA = AppEntry(id: 1, title: "One", supportsHDR: false)
private let appB = AppEntry(id: 2, title: "Two", supportsHDR: false)
private let appX = AppEntry(id: 9, title: "Nine", supportsHDR: false)

private func host(_ id: String) -> PairedHost {
    PairedHost(id: id, name: "\(id)-name", address: "10.0.0.2", httpsPort: 47984, serverCertificateDER: Data([1]))
}

@MainActor private final class Rig {
    let hosts = ["A": host("A"), "B": host("B"), "C": host("C")]
    let plan: SplitPlan
    let input = FakeSplitInput()
    let store = SplitStore(defaults: UserDefaults(suiteName: "split-controller-\(UUID().uuidString)")!)
    var failures: [String: any Error] = [:]
    var wakeHosts: Set<String> = []
    var wakeWaiters: [String: CheckedContinuation<WakeOutcome, Never>] = [:]
    var wakeSawCancel: [String: Bool] = [:]
    var made: [String: [FakeSession]] = [:]
    var finished: [SplitFinish] = []
    var recents: [String] = []
    var idle = 0
    var chosen: [(SplitSide, SplitPlan)] = []
    var controller: SplitController!
    /// Pads stay alive for the whole test, so a new pad never reuses a released one's identity.
    var pads: [Pad] = []

    init(volumes: [SplitSide: Float] = [:], quitError: (any Error)? = nil, layout: SplitLayout = .sideBySide) {
        plan = SplitPlan(first: SplitSideChoice(hostID: "A", app: appA),
                         second: SplitSideChoice(hostID: "B", app: appB),
                         layout: layout, format: .fillHalf)
        for (side, volume) in volumes { store.setVolume(volume, for: side) }
        let deps = SplitDependencies(
            host: { [unowned self] id in hosts[id] },
            needsWake: { [unowned self] id in wakeHosts.contains(id) },
            wake: { [unowned self] host in
                let outcome = await withCheckedContinuation { wakeWaiters[host.id] = $0 }
                wakeSawCancel[host.id] = Task.isCancelled
                return outcome
            },
            makeSession: { [unowned self] host, _, _, _ in
                if let error = failures[host.id] { throw error }
                let session = FakeSession()
                made[host.id, default: []].append(session)
                return (session, StreamSettings(width: 1920, height: 2160, fps: 60, bitrateKbps: 10_000, hdr: false))
            },
            input: input, commands: FakeCommands(error: quitError), store: store,
            recordRecent: { [unowned self] id, app in recents.append("\(id):\(app.id)") },
            onStreamsIdle: { [unowned self] in idle += 1 },
            chooseGame: { [unowned self] side, plan in chosen.append((side, plan)) })
        controller = SplitController(plan: plan, dependencies: deps,
                                     onFinished: { [unowned self] in finished.append($0) })
        controller.begin()
    }

    func send(_ pad: Pad, _ event: LobbyEvent) {
        if !pads.contains(where: { $0 === pad }) { pads.append(pad) }
        input.onEvent?(pad.id, event)
    }
    func session(_ id: String) -> FakeSession? { made[id]?.last }
    func state(_ side: SplitSide) -> SideState? { controller.states[side] }

    func resumeWake(_ id: String, _ outcome: WakeOutcome) {
        wakeWaiters.removeValue(forKey: id)?.resume(returning: outcome)
    }

    /// Seats one pad per side and presses Start on the first.
    func startBoth() -> (Pad, Pad) {
        let one = Pad(), two = Pad()
        send(one, .a(.left))
        send(two, .a(.right))
        send(one, .start)
        return (one, two)
    }

    func bothStreaming() async -> Bool {
        await eventually { self.state(.first) == .streaming && self.state(.second) == .streaming }
    }
}

@MainActor private func runningRig() async -> (Rig, Pad, Pad) {
    let rig = Rig()
    let (one, two) = rig.startBoth()
    _ = await rig.bothStreaming()
    return (rig, one, two)
}

@MainActor @Test func joinSeatsByDirectionAndFewerPlayers() {
    let rig = Rig()
    let one = Pad(), two = Pad()
    #expect(rig.input.started == 1)
    #expect(rig.controller.stage == .joining)
    #expect(rig.state(.first) == .idle && rig.state(.second) == .idle)
    rig.send(one, .a(.center))
    #expect(rig.controller.seats.side(of: one.id) == .first)
    #expect(rig.input.applied.count == 1)
    rig.send(two, .a(.center))
    #expect(rig.controller.seats.side(of: two.id) == .second)
    #expect(rig.input.applied.count == 2)
    rig.send(two, .a(.center))
    #expect(rig.controller.seats.side(of: two.id) == .second)
    #expect(rig.input.applied.count == 2)
    rig.send(two, .a(.left))
    #expect(rig.controller.seats.side(of: two.id) == .first)
    #expect(rig.input.applied.count == 3)
    rig.send(two, .b)
    #expect(rig.controller.seats.side(of: two.id) == nil)
    #expect(rig.input.applied.count == 4)
    #expect(rig.input.applied.last == rig.controller.seats)
}

@MainActor @Test func aDirectionPointsAtTheHalfOnScreenAfterASwap() {
    let rig = Rig()
    let one = Pad(), two = Pad()
    rig.send(one, .a(.left))
    #expect(rig.controller.seats.side(of: one.id) == .first)
    rig.controller.swapSides()
    rig.send(two, .a(.left))
    #expect(rig.controller.seats.side(of: two.id) == .second)
    rig.send(one, .a(.left))
    #expect(rig.controller.seats.side(of: one.id) == .second)
    rig.send(one, .a(.right))
    #expect(rig.controller.seats.side(of: one.id) == .first)
}

@MainActor @Test func upPointsAtTheLowerHalfAfterASwapInTopAndBottom() {
    let rig = Rig(layout: .topBottom)
    let one = Pad(), two = Pad()
    rig.send(one, .a(.up))
    #expect(rig.controller.seats.side(of: one.id) == .first)
    rig.controller.swapSides()
    rig.send(two, .a(.up))
    #expect(rig.controller.seats.side(of: two.id) == .second)
}

@MainActor @Test func theFewerPlayersFallbackIgnoresTheSwap() {
    let rig = Rig()
    rig.controller.swapSides()
    let one = Pad()
    rig.send(one, .a(.center))
    #expect(rig.controller.seats.side(of: one.id) == .first)
}

@MainActor @Test func reassignAndNewControllerFollowTheSwap() async {
    let (rig, one, _) = await runningRig()
    rig.controller.swapSides()
    let three = Pad()
    rig.send(three, .a(.center))
    rig.send(three, .a(.left))
    #expect(rig.controller.seats.side(of: three.id) == .second)
    rig.controller.reassignControllers()
    rig.send(one, .a(.right))
    #expect(rig.controller.seats.side(of: one.id) == .first)
}

@MainActor @Test func startNeedsASeatedPad() async {
    let rig = Rig()
    let one = Pad(), two = Pad()
    rig.send(two, .start)
    #expect(rig.controller.stage == .joining)
    rig.send(one, .a(.center))
    rig.send(two, .start)
    #expect(rig.controller.stage == .joining)
    #expect(rig.made.isEmpty)
    #expect(rig.store.plan == nil)
    rig.send(one, .start)
    #expect(rig.controller.stage == .running)
    #expect(rig.store.plan == rig.plan)
    let streaming = await rig.bothStreaming()
    #expect(streaming)
}

@MainActor @Test func oneControllerStartsBothSidesAndTheEmptySideCanBeJoinedLater() async {
    let rig = Rig()
    let one = Pad(), two = Pad()
    rig.send(one, .a(.left))
    rig.send(one, .start)
    #expect(rig.controller.stage == .running)
    let streaming = await rig.bothStreaming()
    #expect(streaming)
    #expect(rig.controller.seats.count(on: .second) == 0)
    rig.send(two, .a(.center))
    #expect(rig.controller.seatPrompt == ObjectIdentifier(two))
    rig.send(two, .a(.right))
    #expect(rig.controller.seats.count(on: .second) == 1)
}

@MainActor @Test func bothSidesStreamOnTheirOwnInput() async throws {
    let rig = Rig(volumes: [.first: 0.4, .second: 0.7])
    _ = rig.startBoth()
    let streaming = await rig.bothStreaming()
    #expect(streaming)
    let sessionA = try #require(rig.session("A"))
    let sessionB = try #require(rig.session("B"))
    #expect(rig.input.sides[.first]!.sessions == [ObjectIdentifier(sessionA)])
    #expect(rig.input.sides[.second]!.sessions == [ObjectIdentifier(sessionB)])
    #expect(rig.controller.streams[.first]?.session === sessionA)
    #expect(rig.controller.streams[.second]?.session === sessionB)
    #expect(abs((sessionA.volume ?? -1) - 0.4) < 1e-5)
    #expect(abs((sessionB.volume ?? -1) - 0.7) < 1e-5)
}

@MainActor @Test func oneSideFailureLeavesTheOtherRunning() async {
    let rig = Rig()
    rig.failures["B"] = StreamSessionError.noFreeSlot
    _ = rig.startBoth()
    let failed = await eventually { rig.state(.second) == .ended(.failed(.slotBusy)) }
    let first = await eventually { rig.state(.first) == .streaming }
    #expect(failed)
    #expect(first)
    #expect(rig.finished.isEmpty)
    #expect(rig.idle == 0)
}

@MainActor @Test func terminationEndsOnlyThatSide() async {
    let (rig, _, _) = await runningRig()
    rig.session("A")?.send(.terminated(-101))
    let ended = await eventually { rig.state(.first) == .ended(.failed(.unstableConnection)) }
    #expect(ended)
    #expect(rig.state(.second) == .streaming)
    #expect(rig.controller.streams[.first] == nil)
    #expect(rig.finished.isEmpty)
}

@MainActor @Test func wakeTimeoutFailsThatSideOnly() async {
    let rig = Rig()
    rig.wakeHosts = ["B"]
    _ = rig.startBoth()
    #expect(rig.state(.second) == .waking)
    let waiting = await eventually { rig.wakeWaiters["B"] != nil }
    #expect(waiting)
    rig.resumeWake("B", .timedOut)
    let failed = await eventually { rig.state(.second) == .ended(.failed(.hostDidNotWake("B-name"))) }
    #expect(failed)
    #expect(rig.state(.first) == .streaming)
    #expect(rig.made["B"] == nil)
}

@MainActor @Test func aOnAnEndedSideReconnects() async {
    let (rig, one, _) = await runningRig()
    rig.session("A")?.send(.terminated(-101))
    _ = await eventually { rig.state(.first) == .ended(.failed(.unstableConnection)) }
    rig.send(one, .a(.center))
    #expect(rig.state(.first) == .idle)
    let again = await eventually { rig.made["A"]?.count == 2 && rig.state(.first) == .streaming }
    #expect(again)
    #expect(rig.controller.seats.side(of: one.id) == .first)
}

@MainActor @Test func recentsAreWrittenPerSideAtFirstFrame() async {
    let (rig, _, _) = await runningRig()
    rig.session("A")?.send(.started)
    rig.session("B")?.send(.started)
    _ = await eventually { rig.controller.streams[.first]?.phase == .waitingForPicture }
    #expect(rig.recents.isEmpty)
    rig.session("A")?.presentFirstFrame()
    let first = await eventually { rig.recents == ["A:1"] }
    #expect(first)
    rig.session("B")?.presentFirstFrame()
    let second = await eventually { rig.recents == ["A:1", "B:2"] }
    #expect(second)
}

@MainActor @Test func overlayTogglesOnMenuAndSelectRunsItems() async {
    let (rig, _, _) = await runningRig()
    rig.controller.menuPressed(now: 10)
    #expect(rig.controller.isOverlayOpen)
    #expect(rig.controller.cursor.item == .resume)
    rig.controller.menuPressed(now: 10.1)
    #expect(rig.controller.isOverlayOpen)
    for _ in 0..<3 { rig.controller.overlayMove(.up) }
    for _ in 0..<3 { rig.controller.overlayMove(.left) }
    #expect(rig.controller.cursor.item == .volumeDown(.first))
    rig.controller.overlaySelect()
    #expect(abs((rig.controller.volumes[.first] ?? -1) - 0.9) < 1e-5)
    #expect(abs(rig.store.volume(for: .first) - 0.9) < 1e-5)
    #expect(abs((rig.session("A")?.volume ?? -1) - 0.9) < 1e-5)
    #expect(abs((rig.session("B")?.volume ?? -1) - 1) < 1e-5)
    for _ in 0..<3 { rig.controller.overlayMove(.down) }
    #expect(rig.controller.cursor.item == .swap)
    rig.controller.overlaySelect()
    #expect(rig.controller.isSwapped)
    #expect(rig.controller.isOverlayOpen)
    rig.controller.closeOverlay()
    #expect(!rig.controller.isOverlayOpen)
}

@MainActor @Test func menuWithTheOverlayOpenClosesItAndKeepsBothSides() async {
    let (rig, _, _) = await runningRig()
    rig.controller.menuPressed(now: 10)
    #expect(rig.controller.isOverlayOpen)
    rig.controller.menuPressed(now: 11)
    #expect(!rig.controller.isOverlayOpen)
    #expect(rig.finished.isEmpty)
    #expect(rig.session("A")?.stopCount == 0)
    #expect(rig.session("B")?.stopCount == 0)
    rig.controller.menuPressed(now: 12)
    #expect(rig.controller.isOverlayOpen)
}

@MainActor @Test func menuBacksOutOfAnArmedQuitBeforeClosing() async {
    let (rig, _, _) = await runningRig()
    rig.session("A")?.presentFirstFrame()
    _ = await eventually { rig.controller.streams[.first]?.phase == .running }
    rig.controller.menuPressed(now: 10)
    rig.controller.secondaryAction(.first)
    #expect(rig.controller.quitArmed == .first)
    rig.controller.menuPressed(now: 11)
    #expect(rig.controller.quitArmed == nil)
    #expect(rig.controller.isOverlayOpen)
    #expect(rig.finished.isEmpty)
}

@MainActor @Test func overlaySelectVolumeDownFollowsTheSwappedScreenPosition() async {
    let (rig, _, _) = await runningRig()
    rig.controller.menuPressed(now: 10)
    for _ in 0..<3 { rig.controller.overlayMove(.up) }
    for _ in 0..<3 { rig.controller.overlayMove(.left) }
    #expect(rig.controller.cursor.item == .volumeDown(.first))
    rig.controller.overlaySelect()
    #expect(abs((rig.controller.volumes[.first] ?? -1) - 0.9) < 1e-5)
    #expect(abs((rig.controller.volumes[.second] ?? -1) - 1) < 1e-5)

    rig.controller.closeOverlay()
    rig.controller.menuPressed(now: 10.8)
    rig.controller.swapSides()
    for _ in 0..<3 { rig.controller.overlayMove(.up) }
    for _ in 0..<3 { rig.controller.overlayMove(.left) }
    #expect(rig.controller.cursor.item == .volumeDown(.first))
    rig.controller.overlaySelect()
    #expect(abs((rig.controller.volumes[.second] ?? -1) - 0.9) < 1e-5)
    #expect(abs((rig.controller.volumes[.first] ?? -1) - 0.9) < 1e-5)
}

@MainActor @Test func overlaySelectPrimaryDisconnectsTheRealSide() async {
    let (rig, _, _) = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.overlayMove(.up)
    rig.controller.overlayMove(.up)
    rig.controller.overlayMove(.left)
    #expect(rig.controller.cursor.item == .primary(.first))
    rig.controller.overlaySelect()
    let ended = await eventually { rig.state(.first) == .ended(.disconnected) }
    #expect(ended)
    #expect(rig.state(.second) == .streaming)
}

@MainActor @Test func overlaySelectPrimaryFollowsTheSwappedScreenPosition() async {
    let (rig, _, _) = await runningRig()
    rig.controller.swapSides()
    rig.controller.menuPressed(now: 10)
    rig.controller.overlayMove(.up)
    rig.controller.overlayMove(.up)
    rig.controller.overlayMove(.left)
    #expect(rig.controller.cursor.item == .primary(.first))
    rig.controller.overlaySelect()
    let ended = await eventually { rig.state(.second) == .ended(.disconnected) }
    #expect(ended)
    #expect(rig.state(.first) == .streaming)
}

@MainActor @Test func quitNeedsTwoPressesAndMovingDisarms() async {
    let (rig, _, _) = await runningRig()
    rig.session("A")?.send(.started)
    _ = await eventually { rig.controller.streams[.first]?.phase == .waitingForPicture }
    rig.controller.menuPressed(now: 10)
    rig.controller.secondaryAction(.first)
    #expect(rig.controller.quitArmed == .first)
    rig.controller.overlayMove(.right)
    #expect(rig.controller.quitArmed == nil)
    rig.controller.secondaryAction(.first)
    #expect(rig.controller.quitArmed == .first)
    rig.controller.secondaryAction(.first)
    #expect(rig.controller.streams[.first]?.ending == .quittingGame)
    let quit = await eventually { rig.state(.first) == .ended(.quit) }
    #expect(quit)
    #expect(rig.state(.second) == .streaming)
}

@MainActor @Test func disconnectingASideEndsItAsDisconnected() async {
    let (rig, _, _) = await runningRig()
    rig.controller.primaryAction(.first)
    let ended = await eventually { rig.state(.first) == .ended(.disconnected) }
    #expect(ended)
    #expect(rig.session("A")?.stopCount == 1)
    #expect(rig.state(.second) == .streaming)
    #expect(rig.finished.isEmpty)
}

@MainActor @Test func endSplitDisconnectsBothAndFinishesOnce() async {
    let (rig, _, _) = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.endSplit()
    #expect(rig.finished.isEmpty)
    #expect(!rig.controller.isOverlayOpen)
    let done = await eventually { !rig.finished.isEmpty }
    #expect(done)
    rig.controller.endSplit()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(rig.finished == [.ended])
    #expect(rig.session("A")?.stopCount == 1)
    #expect(rig.session("B")?.stopCount == 1)
    #expect(rig.input.stopped == 1)
    #expect(rig.state(.first) == .ended(.disconnected))
    #expect(rig.state(.second) == .ended(.disconnected))
}

@MainActor @Test func endSplitWhileWakingFinishesOnce() async {
    let rig = Rig()
    rig.wakeHosts = ["B"]
    _ = rig.startBoth()
    _ = await eventually { rig.state(.first) == .streaming && rig.wakeWaiters["B"] != nil }
    #expect(rig.state(.second) == .waking)
    rig.controller.endSplit()
    let done = await eventually { !rig.finished.isEmpty }
    #expect(done)
    #expect(rig.state(.second) == .ended(.disconnected))
    rig.resumeWake("B", .awake)
    let sawCancel = await eventually { rig.wakeSawCancel["B"] != nil }
    #expect(sawCancel)
    #expect(rig.wakeSawCancel["B"] == true)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(rig.finished == [.ended])
    #expect(rig.input.stopped == 1)
    #expect(rig.made["B"] == nil)
}

@MainActor @Test func backgroundSuspendsBothSides() async {
    let (rig, _, _) = await runningRig()
    rig.controller.suspend()
    let suspended = await eventually {
        rig.state(.first) == .ended(.suspended) && rig.state(.second) == .ended(.suspended)
    }
    #expect(suspended)
    #expect(rig.idle == 1)
    #expect(rig.finished.isEmpty)
    #expect(rig.input.stopped == 0)
}

@MainActor @Test func backgroundKeepsAPendingQuit() async {
    let rig = await startedRig()
    rig.controller.secondaryAction(.first)
    rig.controller.secondaryAction(.first)
    #expect(rig.controller.streams[.first]?.ending == .quittingGame)
    rig.controller.suspend()
    let settled = await eventually {
        rig.state(.first) != .streaming && rig.state(.second) == .ended(.suspended)
    }
    #expect(settled)
    #expect(rig.state(.first) == .ended(.quit))
}

@MainActor @Test func menuWhileJoiningCancelsBackToTheWizard() {
    let rig = Rig()
    rig.send(Pad(), .a(.center))
    rig.controller.menuPressed(now: 10)
    #expect(rig.input.stopped == 1)
    #expect(rig.finished == [.cancelledJoin])
    #expect(rig.made.isEmpty)
}

@MainActor @Test func hotplugPromptSeatsOnTheSecondA() async {
    let (rig, _, _) = await runningRig()
    let three = Pad(), four = Pad()
    rig.send(three, .a(.center))
    #expect(rig.controller.seatPrompt == three.id)
    #expect(rig.controller.seats.side(of: three.id) == nil)
    rig.send(three, .a(.right))
    #expect(rig.controller.seats.side(of: three.id) == .second)
    #expect(rig.controller.seatPrompt == nil)
    #expect(rig.input.applied.last == rig.controller.seats)
    rig.send(four, .a(.center))
    #expect(rig.controller.seatPrompt == four.id)
    rig.send(four, .b)
    #expect(rig.controller.seatPrompt == nil)
    #expect(rig.controller.seats.side(of: four.id) == nil)
}

@MainActor @Test func padsLeavingAreUnseated() async {
    let (rig, one, two) = await runningRig()
    let three = Pad()
    rig.send(three, .a(.center))
    #expect(rig.controller.seatPrompt == three.id)
    rig.input.onPadsChanged?([two.id])
    #expect(rig.controller.seats.side(of: one.id) == nil)
    #expect(rig.controller.seats.side(of: two.id) == .second)
    #expect(rig.controller.seatPrompt == nil)
    #expect(rig.input.applied.last == rig.controller.seats)
}

@MainActor @Test func reassignPausesAndStartFinishes() async {
    let (rig, one, two) = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.reassignControllers()
    #expect(!rig.controller.isOverlayOpen)
    #expect(rig.controller.isReassigning)
    #expect(rig.input.reassigning == [true])
    let applied = rig.input.applied.count
    rig.send(one, .a(.right))
    #expect(rig.controller.seats.side(of: one.id) == .second)
    #expect(rig.input.applied.count == applied + 1)
    rig.send(two, .a(.left))
    #expect(rig.controller.seats.side(of: two.id) == .first)
    rig.send(Pad(), .start)
    #expect(rig.controller.isReassigning)
    rig.send(two, .start)
    #expect(!rig.controller.isReassigning)
    #expect(rig.input.reassigning == [true, false])
    #expect(rig.input.applied.last == rig.controller.seats)
    #expect(rig.state(.first) == .streaming && rig.state(.second) == .streaming)
}

@MainActor @Test func chooseGameReplacesOnlyThatSide() async {
    let (rig, _, _) = await runningRig()
    rig.session("B")?.send(.started)
    _ = await eventually { rig.controller.streams[.second]?.phase == .waitingForPicture }
    rig.controller.secondaryAction(.second)
    rig.controller.secondaryAction(.second)
    _ = await eventually { rig.state(.second) == .ended(.quit) }
    rig.controller.secondaryAction(.second)
    #expect(rig.controller.isChoosingGame)
    #expect(rig.chosen.count == 1 && rig.chosen.first?.0 == .second && rig.chosen.first?.1 == rig.plan)
    rig.controller.replaceSide(.second, with: SplitSideChoice(hostID: "A", app: appX))
    #expect(!rig.controller.isChoosingGame)
    #expect(rig.controller.plan == rig.plan)
    #expect(rig.state(.second) == .ended(.quit))
    rig.controller.secondaryAction(.second)
    rig.controller.replaceSide(.second, with: SplitSideChoice(hostID: "C", app: appX))
    #expect(rig.controller.plan.second == SplitSideChoice(hostID: "C", app: appX))
    #expect(rig.controller.plan.first == rig.plan.first)
    #expect(rig.store.plan == rig.controller.plan)
    let started = await eventually { rig.made["C"]?.count == 1 && rig.state(.second) == .streaming }
    #expect(started)
    #expect(rig.made["A"]?.count == 1)
    #expect(rig.state(.first) == .streaming)
}

@MainActor private func startedRig(quitError: (any Error)? = nil) async -> Rig {
    let rig = Rig(quitError: quitError)
    _ = rig.startBoth()
    _ = await rig.bothStreaming()
    rig.session("A")?.send(.started)
    _ = await eventually { rig.controller.streams[.first]?.phase == .waitingForPicture }
    return rig
}

@MainActor @Test func aFailedHostQuitEndsAsFailed() async {
    let rig = await startedRig(quitError: URLError(.timedOut))
    rig.controller.secondaryAction(.first)
    rig.controller.secondaryAction(.first)
    let failed = await eventually { rig.state(.first) == .ended(.failed(.quitFailed)) }
    #expect(failed)
    #expect(rig.state(.second) == .streaming)
}

@MainActor @Test func aFailureRacingADisconnectKeepsTheFailure() async {
    let rig = await startedRig()
    rig.controller.streams[.first]?.handle(.terminated(-101))
    #expect(rig.state(.first) == .streaming)
    rig.controller.primaryAction(.first)
    let failed = await eventually { rig.state(.first) == .ended(.failed(.unstableConnection)) }
    #expect(failed)
}

@MainActor @Test func quitBeforeThePictureLeavesNoPendingQuit() async {
    let (rig, _, _) = await runningRig()
    #expect(rig.controller.streams[.first]?.phase == .connecting)
    rig.controller.secondaryAction(.first)
    rig.controller.secondaryAction(.first)
    #expect(rig.controller.streams[.first]?.ending == nil)
    #expect(rig.state(.first) == .streaming)
    rig.controller.primaryAction(.first)
    let ended = await eventually { rig.state(.first) == .ended(.disconnected) }
    #expect(ended)
}

@MainActor @Test func suspendWithNoLiveSideStillReportsIdle() async {
    let joining = Rig()
    joining.controller.suspend()
    #expect(joining.idle == 1)
    #expect(joining.finished.isEmpty)

    let (rig, _, _) = await runningRig()
    rig.controller.primaryAction(.first)
    rig.controller.primaryAction(.second)
    _ = await eventually { rig.state(.first) == .ended(.disconnected) && rig.state(.second) == .ended(.disconnected) }
    #expect(rig.idle == 1)
    rig.controller.suspend()
    #expect(rig.idle == 2)
    #expect(rig.state(.first) == .ended(.disconnected))
}

@MainActor @Test func menuWhileEndingDoesNotOpenTheOverlay() async {
    let (rig, _, _) = await runningRig()
    rig.controller.endSplit()
    rig.controller.menuPressed(now: 10)
    #expect(!rig.controller.isOverlayOpen)
    let done = await eventually { rig.finished == [.ended] }
    #expect(done)
}
