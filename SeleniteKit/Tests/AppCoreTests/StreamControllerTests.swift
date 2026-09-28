import CoreMedia
import Foundation
import HostKit
import StreamKit
import Testing
@testable import AppCore

/// A session whose start() waits until the test completes it (or a stop cancels it, as the real
/// one does) and whose events the test sends by hand.
private final class FakeSession: StreamSessionHandle, @unchecked Sendable {
    let events: AsyncStream<StreamEvent>
    let pacer = FramePacer<CMSampleBuffer>()
    private let eventSink: AsyncStream<StreamEvent>.Continuation
    private let startError: (any Error)?
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, any Error>?
    private var stopped = false
    private var _stopCount = 0
    private var _presented = 0
    private var _mouse: [String] = []

    init(startError: (any Error)? = nil) {
        (events, eventSink) = AsyncStream.makeStream()
        self.startError = startError
    }

    var stopCount: Int { lock.withLock { _stopCount } }
    var isWaitingInStart: Bool { lock.withLock { gate != nil } }

    var mouse: [String] { lock.withLock { _mouse } }

    func send(_ event: StreamEvent) { eventSink.yield(event) }

    func sendMouseMove(dx: Int16, dy: Int16) { lock.withLock { _mouse.append("move \(dx),\(dy)") } }

    func sendScroll(amount: Int16) { lock.withLock { _mouse.append("scroll \(amount)") } }

    func sendMouseButton(_ button: MouseButton, pressed: Bool) {
        lock.withLock { _mouse.append("\(button) \(pressed ? "down" : "up")") }
    }
    func presentFirstFrame() { lock.withLock { _presented = 1 } }

    func completeStart() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { gate = nil }
            return gate
        }
        waiter?.resume()
    }

    func start() async throws {
        if let startError { throw startError }
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

@MainActor private final class FakeInput: StreamInput {
    var began = 0
    var connected = 0
    var ended = 0
    var forwarding: [Bool] = []

    func begin(session: any StreamSessionHandle) { began += 1 }
    func sessionConnected() { connected += 1 }
    func setForwarding(_ forwarding: Bool) { self.forwarding.append(forwarding) }
    func end() { ended += 1 }
}

/// Records, for every quit, how often the session had been stopped by then.
private final class FakeCommands: HostCommands, @unchecked Sendable {
    let session: FakeSession
    let error: (any Error)?
    private let lock = NSLock()
    private var _stopsAtQuit: [Int] = []

    init(session: FakeSession, error: (any Error)?) {
        self.session = session
        self.error = error
    }

    var stopsAtQuit: [Int] { lock.withLock { _stopsAtQuit } }

    func quitApp(on host: PairedHost) async throws {
        let stops = session.stopCount
        lock.withLock { _stopsAtQuit.append(stops) }
        if let error { throw error }
    }
}

@MainActor private final class EndLog {
    var calls: [StreamFailure?] = []
}

@MainActor private struct Rig {
    let session: FakeSession
    let input: FakeInput
    let commands: FakeCommands
    let ended: EndLog
    let controller: StreamController
}

@MainActor private func makeRig(session: FakeSession = FakeSession(), quitError: (any Error)? = nil,
                                firstFrameTimeout: Duration = .seconds(20)) -> Rig {
    let input = FakeInput()
    let commands = FakeCommands(session: session, error: quitError)
    let ended = EndLog()
    let controller = StreamController(
        host: PairedHost(id: "H", name: "PC", address: "10.0.0.2", httpsPort: 47984, serverCertificateDER: Data([1])),
        app: AppEntry(id: 7, title: "Game", supportsHDR: false),
        settings: StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, hdr: false),
        session: session, input: input, commands: commands, firstFrameTimeout: firstFrameTimeout,
        onEnded: { failure in ended.calls.append(failure) })
    return Rig(session: session, input: input, commands: commands, ended: ended, controller: controller)
}

@MainActor private func runningRig(quitError: (any Error)? = nil) async -> Rig {
    let rig = makeRig(quitError: quitError)
    rig.controller.start()
    rig.session.send(.started)
    _ = await eventually { rig.controller.phase == .waitingForPicture }
    _ = await eventually { rig.session.isWaitingInStart }
    rig.session.completeStart()
    rig.session.presentFirstFrame()
    rig.controller.checkFirstFrame()
    return rig
}

@MainActor @Test func loadingFollowsTheSessionToRunning() async {
    let rig = makeRig()
    rig.controller.start()
    #expect(rig.controller.phase == .connecting)
    #expect(rig.input.began == 1)
    rig.session.send(.launching)
    let starting = await eventually { rig.controller.phase == .startingGame }
    #expect(starting)
    rig.session.send(.started)
    let waiting = await eventually { rig.controller.phase == .waitingForPicture }
    #expect(waiting)
    #expect(rig.input.connected == 1)
    rig.controller.checkFirstFrame()
    #expect(rig.controller.phase == .waitingForPicture)
    rig.session.presentFirstFrame()
    rig.controller.checkFirstFrame()
    #expect(rig.controller.phase == .running)
    #expect(rig.controller.liveStats != nil)
}

@MainActor @Test func menuDuringStartCancelsWithoutAnError() async {
    let rig = makeRig()
    rig.controller.start()
    let waitingInStart = await eventually { rig.session.isWaitingInStart }
    #expect(waitingInStart)
    rig.controller.menuPressed(now: 10)
    await rig.controller.endTask?.value
    let calls: [StreamFailure?] = rig.ended.calls
    #expect(rig.controller.phase == .ended)
    #expect(rig.controller.failure == nil)
    #expect(calls == [nil])
    #expect(rig.session.stopCount == 1)
    #expect(rig.input.ended == 1)
    let quits: [Int] = rig.commands.stopsAtQuit
    #expect(quits.isEmpty)
}

@MainActor @Test func menuOpensTheOverlayAndPausesForwarding() async {
    let rig = await runningRig()
    #expect(rig.controller.phase == .running)
    rig.controller.menuPressed(now: 10)
    #expect(rig.controller.isOverlayOpen)
    let forwarding: [Bool] = rig.input.forwarding
    #expect(forwarding == [false])
}

@MainActor @Test func menuWithTheOverlayOpenDisconnectsAndLeavesTheGameRunning() async {
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.menuPressed(now: 11)
    let during: StreamEnding? = rig.controller.ending
    #expect(during == .disconnecting)
    await rig.controller.endTask?.value
    let calls: [StreamFailure?] = rig.ended.calls
    let quits: [Int] = rig.commands.stopsAtQuit
    #expect(rig.controller.phase == .ended)
    #expect(calls == [nil])
    #expect(quits.isEmpty)
    #expect(rig.session.stopCount == 1)
    #expect(rig.input.ended == 1)
}

@MainActor @Test func menuAfterResumeOpensTheOverlayAgain() async {
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.closeOverlay()
    rig.controller.menuPressed(now: 11)
    #expect(rig.controller.isOverlayOpen)
    let ending: StreamEnding? = rig.controller.ending
    #expect(ending == nil)
    let forwarding: [Bool] = rig.input.forwarding
    #expect(forwarding == [false, true, false])
}

@MainActor @Test func aDoubleReportWithTheOverlayOpenDoesNotDisconnect() async {
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.menuPressed(now: 10.2)
    let ending: StreamEnding? = rig.controller.ending
    #expect(ending == nil)
    #expect(rig.controller.isOverlayOpen)
}

@MainActor @Test func aSecondReportOfTheSameMenuPressIsIgnored() async {
    // Review Focus 1: GameController and UIKit both report one press.
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.menuPressed(now: 10.1)
    #expect(rig.controller.isOverlayOpen)
    let forwarding: [Bool] = rig.input.forwarding
    #expect(forwarding == [false])
}

@MainActor @Test func resumeClosesTheOverlay() async {
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.closeOverlay()
    #expect(!rig.controller.isOverlayOpen)
    let forwarding: [Bool] = rig.input.forwarding
    #expect(forwarding == [false, true])
}

@MainActor @Test func disconnectEndsWithoutErrorAndLeavesTheGameRunning() async {
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.disconnect()
    await rig.controller.endTask?.value
    let calls: [StreamFailure?] = rig.ended.calls
    let quits: [Int] = rig.commands.stopsAtQuit
    #expect(rig.controller.phase == .ended)
    #expect(calls == [nil])
    #expect(quits.isEmpty)
    #expect(!rig.controller.isOverlayOpen)
}

@MainActor @Test func quitAsksFirstThenStopsAndCancelsOnTheHost() async {
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.requestQuit()
    #expect(rig.controller.isConfirmingQuit)
    rig.controller.menuPressed(now: 11)
    #expect(!rig.controller.isConfirmingQuit)
    #expect(rig.controller.isOverlayOpen)
    let afterBackOut: StreamEnding? = rig.controller.ending
    #expect(afterBackOut == nil)
    rig.controller.requestQuit()
    rig.controller.confirmQuit()
    await rig.controller.endTask?.value
    let quits: [Int] = rig.commands.stopsAtQuit
    let calls: [StreamFailure?] = rig.ended.calls
    #expect(quits == [1])
    #expect(calls == [nil])
}

@MainActor @Test func aFailedQuitIsReported() async {
    let rig = await runningRig(quitError: URLError(.timedOut))
    rig.controller.menuPressed(now: 10)
    rig.controller.requestQuit()
    rig.controller.confirmQuit()
    await rig.controller.endTask?.value
    let calls: [StreamFailure?] = rig.ended.calls
    #expect(calls == [.quitFailed])
}

@MainActor @Test func aLostConnectionEndsWithItsReason() async {
    let rig = await runningRig()
    rig.session.send(.terminated(-101))
    let ended = await eventually { rig.controller.phase == .ended }
    let calls: [StreamFailure?] = rig.ended.calls
    #expect(ended)
    #expect(rig.controller.failure == .unstableConnection)
    #expect(calls == [.unstableConnection])
    #expect(rig.session.stopCount == 1)
}

@MainActor @Test func aFailedStartEndsWithItsReason() async {
    let rig = makeRig(session: FakeSession(startError: StreamSessionError.launchFailed("busy")))
    rig.controller.start()
    let ended = await eventually { rig.controller.phase == .ended }
    let calls: [StreamFailure?] = rig.ended.calls
    #expect(ended)
    #expect(calls == [.hostRefused("busy")])
}

@MainActor @Test func poorConnectionIsShownWhileItLasts() async {
    let rig = await runningRig()
    rig.session.send(.poorConnection(true))
    let poor = await eventually { rig.controller.isPoorConnection }
    #expect(poor)
    rig.session.send(.poorConnection(false))
    let recovered = await eventually { !rig.controller.isPoorConnection }
    #expect(recovered)
}

@MainActor @Test func disconnectShowsItsEndingUntilTheSessionStops() async {
    let rig = await runningRig()
    let before: StreamEnding? = rig.controller.ending
    #expect(before == nil)
    rig.controller.menuPressed(now: 10)
    rig.controller.disconnect()
    let during: StreamEnding? = rig.controller.ending
    #expect(during == .disconnecting)
    #expect(rig.controller.phase == .running)
    await rig.controller.endTask?.value
    #expect(rig.controller.phase == .ended)
}

@MainActor @Test func quitShowsItsEndingUntilTheHostAnswers() async {
    let rig = await runningRig()
    rig.controller.menuPressed(now: 10)
    rig.controller.requestQuit()
    rig.controller.confirmQuit()
    let during: StreamEnding? = rig.controller.ending
    #expect(during == .quittingGame)
    #expect(!rig.controller.isOverlayOpen)
    await rig.controller.endTask?.value
    let calls: [StreamFailure?] = rig.ended.calls
    #expect(calls == [nil])
}

@MainActor @Test func noFirstFrameInTimeEndsWithNoVideoTraffic() async {
    let rig = makeRig(firstFrameTimeout: .milliseconds(100))
    rig.controller.start()
    rig.session.send(.started)
    let ended = await eventually { rig.controller.phase == .ended }
    let calls: [StreamFailure?] = rig.ended.calls
    #expect(ended)
    #expect(calls == [.noVideoTraffic])
    #expect(rig.session.stopCount == 1)
}

@MainActor @Test func pointerForwardsWhileRunningWithTheOverlayClosed() async {
    let rig = await runningRig()
    rig.controller.pointerMoved(dx: 3, dy: -2)
    rig.controller.pointerScrolled(amount: -120)
    rig.controller.pointerButton(.left, pressed: true)
    rig.controller.pointerButton(.left, pressed: false)
    rig.controller.pointerButton(.right, pressed: true)
    rig.controller.pointerButton(.right, pressed: false)
    #expect(rig.session.mouse == ["move 3,-2", "scroll -120", "left down", "left up", "right down", "right up"])
}

@MainActor @Test func pointerIsDroppedWhileLoading() {
    let rig = makeRig()
    rig.controller.start()
    rig.controller.pointerMoved(dx: 3, dy: 3)
    rig.controller.pointerScrolled(amount: 120)
    rig.controller.pointerButton(.left, pressed: true)
    rig.controller.pointerButton(.left, pressed: false)
    #expect(rig.session.mouse.isEmpty)
}

@MainActor @Test func openingTheOverlayReleasesHeldButtonsAndDropsThePointer() async {
    let rig = await runningRig()
    rig.controller.pointerButton(.left, pressed: true)
    rig.controller.menuPressed(now: 10)
    rig.controller.pointerMoved(dx: 5, dy: 5)
    rig.controller.pointerScrolled(amount: 120)
    rig.controller.pointerButton(.right, pressed: true)
    rig.controller.pointerButton(.left, pressed: false)
    #expect(rig.session.mouse == ["left down", "left up"])
}

@MainActor @Test func endingReleasesHeldButtonsBeforeTheSessionStops() async {
    let rig = await runningRig()
    rig.controller.pointerButton(.right, pressed: true)
    rig.controller.disconnect()
    #expect(rig.session.mouse == ["right down", "right up"])
    #expect(rig.session.stopCount == 0)
    rig.controller.pointerButton(.right, pressed: false)
    #expect(rig.session.mouse == ["right down", "right up"])
}
