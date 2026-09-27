import Foundation
import Testing
@testable import StreamKit

@Test func stopBeforeConnectMakesTheNextCheckpointThrow() throws {
    let lifecycle = SessionLifecycle()
    try lifecycle.beginStart()
    #expect(lifecycle.requestStop() == .starting)
    #expect(throws: StreamSessionError.self) { try lifecycle.checkpoint() }
    #expect(throws: StreamSessionError.self) { try lifecycle.beginConnect() }
}

@Test func secondStartThrows() throws {
    let lifecycle = SessionLifecycle()
    try lifecycle.beginStart()
    #expect(throws: StreamSessionError.self) { try lifecycle.beginStart() }
}

@Test func startAfterStopThrows() {
    let lifecycle = SessionLifecycle()
    #expect(lifecycle.requestStop() == .idle)
    #expect(throws: StreamSessionError.self) { try lifecycle.beginStart() }
}

@Test func onlyTheFirstStopReportsAState() throws {
    let lifecycle = SessionLifecycle()
    try lifecycle.beginStart()
    try lifecycle.beginConnect()
    #expect(lifecycle.endConnect(succeeded: true))
    #expect(lifecycle.requestStop() == .connected)
    #expect(lifecycle.requestStop() == nil)
}

@Test func stopWhileConnectingInterruptsAndWaitsForTheConnectReturn() throws {
    let lifecycle = SessionLifecycle()
    try lifecycle.beginStart()
    try lifecycle.beginConnect()
    #expect(lifecycle.requestStop() == .connecting)

    let interrupted = DispatchSemaphore(value: 0)
    let returned = Flag()
    let connectOwnedTeardown = Flag()
    Thread {
        // The fake LiStartConnection only returns once it was interrupted, and takes a while to unwind.
        interrupted.wait()
        Thread.sleep(forTimeInterval: 0.2)
        returned.set()
        if lifecycle.endConnect(succeeded: false) { connectOwnedTeardown.set() }
    }.start()

    lifecycle.waitForConnectReturn { interrupted.signal() }
    #expect(returned.value)
    #expect(!connectOwnedTeardown.value)
}

/// moonlight calls connectionStarted inside LiStartConnection, before endConnect runs.
@Test func markStartedWhileConnectingConnectsAndTheConnectThreadStillOwnsTheSession() throws {
    let lifecycle = SessionLifecycle()
    try lifecycle.beginStart()
    try lifecycle.beginConnect()
    lifecycle.markStarted()
    let connected: Bool = lifecycle.isConnected
    #expect(connected)
    let owned: Bool = lifecycle.endConnect(succeeded: true)
    #expect(owned)
    let state: SessionLifecycle.State = lifecycle.state
    #expect(state == .connected)
}

/// The connect thread has not returned yet, so a stop must still wait for it.
@Test func stopAfterMarkStartedButBeforeTheConnectReturnWaitsForIt() throws {
    let lifecycle = SessionLifecycle()
    try lifecycle.beginStart()
    try lifecycle.beginConnect()
    lifecycle.markStarted()
    let found: SessionLifecycle.State? = lifecycle.requestStop()
    #expect(found == .connecting)
    let owned: Bool = lifecycle.endConnect(succeeded: true)
    #expect(!owned)
}

@Test func whileConnectedRunsOnlyWhileConnected() throws {
    let lifecycle = SessionLifecycle()
    try lifecycle.beginStart()
    try lifecycle.beginConnect()
    var runs = 0
    let beforeStart: Int? = lifecycle.whileConnected { runs += 1; return runs }
    lifecycle.markStarted()
    let afterStart: Int? = lifecycle.whileConnected { runs += 1; return runs }
    _ = lifecycle.requestStop()
    let afterStop: Int? = lifecycle.whileConnected { runs += 1; return runs }
    #expect(beforeStart == nil)
    #expect(afterStart == 1)
    #expect(afterStop == nil)
    #expect(runs == 1)
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
