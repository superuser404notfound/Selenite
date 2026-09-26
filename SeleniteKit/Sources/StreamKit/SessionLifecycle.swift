import Foundation

/// Orders a session's start against its stop. LiStartConnection and LiStopConnection must never
/// run concurrently on one slot, and a start that is still awaiting the host must not reach the
/// slot's C state after a stop released it.
final class SessionLifecycle: @unchecked Sendable {
    enum State: Equatable { case idle, starting, connecting, connected, failed, stopped }

    private let lock = NSLock()
    private var current: State = .idle
    /// True from `beginConnect` until `endConnect`: LiStartConnection has not returned yet, even
    /// after `markStarted`, so a stop must still wait for the connect thread.
    private var connectPending = false
    private let connectReturned = DispatchSemaphore(value: 0)

    var state: State { lock.withLock { current } }

    /// True once the connection started (`markStarted`) or LiStartConnection succeeded, and no
    /// stop has run yet.
    var isConnected: Bool { state == .connected }

    /// Runs `body` only while connected, holding the lock throughout, so a stop cannot latch in the
    /// middle of it. Keep `body` short: controller sends are a cheap enqueue. Nil when not connected.
    func whileConnected<T>(_ body: () -> T) -> T? {
        lock.withLock { current == .connected ? body() : nil }
    }

    func beginStart() throws {
        try lock.withLock {
            switch current {
            case .idle: current = .starting
            case .stopped: throw StreamSessionError.cancelled
            default: throw StreamSessionError.alreadyStarted
            }
        }
    }

    /// Throws once a stop arrived. start() calls it after every await.
    func checkpoint() throws {
        if state == .stopped { throw StreamSessionError.cancelled }
    }

    /// The last check before LiStartConnection. Once it passed, a stop waits for the connect
    /// thread, so the caller must run startConnection and then call `endConnect`.
    func beginConnect() throws {
        try lock.withLock {
            guard current == .starting else { throw StreamSessionError.cancelled }
            current = .connecting
            connectPending = true
        }
    }

    /// moonlight's connectionStarted, which it calls from inside LiStartConnection before that
    /// returns. Input sent from here on reaches the host, so the session counts as connected.
    func markStarted() {
        lock.withLock {
            if current == .connecting { current = .connected }
        }
    }

    /// Called on the connect thread as soon as startConnection returned. False when a stop
    /// arrived meanwhile: that stop is waiting and owns the teardown.
    func endConnect(succeeded: Bool) -> Bool {
        lock.withLock {
            connectPending = false
            guard current == .connecting || current == .connected else {
                connectReturned.signal()
                return false
            }
            current = succeeded ? .connected : .failed
            return true
        }
    }

    /// Latches `stopped`. Returns the state the stop found, or nil when a stop already ran.
    /// Reports `.connecting` while the connect thread has not returned, even after `markStarted`,
    /// because the stop then has to wait for it.
    func requestStop() -> State? {
        lock.withLock {
            guard current != .stopped else { return nil }
            defer { current = .stopped }
            return connectPending ? .connecting : current
        }
    }

    /// Blocks until the connect thread returned, after `requestStop` found `.connecting`.
    /// LiStartConnection clears the interrupt flag early on, so an interrupt that lands before
    /// that is lost; it is repeated until the thread returns.
    func waitForConnectReturn(interrupt: () -> Void) {
        repeat { interrupt() } while connectReturned.wait(timeout: .now() + .milliseconds(100)) == .timedOut
    }
}
