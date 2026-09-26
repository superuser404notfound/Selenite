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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
