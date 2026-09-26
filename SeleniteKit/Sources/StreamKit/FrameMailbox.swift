import Foundation

public struct MailboxStats: Sendable, Equatable {
    public var delivered = 0
    public var dropped = 0
    public var emptyTicks = 0

    public init(delivered: Int = 0, dropped: Int = 0, emptyTicks: Int = 0) {
        self.delivered = delivered; self.dropped = dropped; self.emptyTicks = emptyTicks
    }
}

/// Single-slot hand-off between the decoder and the vsync tick. A newer frame replaces an
/// unshown one, so the display is never more than one frame behind the decoder.
public final class FrameMailbox<Frame>: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: Frame?
    private var counters = MailboxStats()

    public init() {}

    public func put(_ newFrame: Frame) {
        lock.lock(); defer { lock.unlock() }
        if frame != nil { counters.dropped += 1 }
        frame = newFrame
    }

    public func take() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let current = frame else {
            counters.emptyTicks += 1
            return nil
        }
        frame = nil
        counters.delivered += 1
        return current
    }

    public var stats: MailboxStats {
        lock.lock(); defer { lock.unlock() }
        return counters
    }
}
