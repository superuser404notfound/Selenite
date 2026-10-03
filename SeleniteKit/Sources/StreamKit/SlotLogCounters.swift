import Foundation

/// Counts the moonlight-common-c log lines that tell client-side drops from network loss, per slot.
/// The app's log sink feeds every line here (`DiagnosticLog`); counts only grow, so a session
/// reads them relative to its own start.
public final class SlotLogCounters: @unchecked Sendable {
    public static let shared = SlotLogCounters()
    static let overflowLine = "Video decode unit queue overflow"
    static let unrecoverableLine = "Unrecoverable frame"

    private let lock = NSLock()
    private var overflowCounts = [0, 0]
    private var unrecoverableCounts = [0, 0]

    init() {}

    public func observe(slot: Int32, line: String) {
        guard let index = Slot(rawValue: Int(slot))?.rawValue else { return }
        if line.hasPrefix(Self.overflowLine) {
            lock.withLock { overflowCounts[index] += 1 }
        } else if line.hasPrefix(Self.unrecoverableLine) {
            lock.withLock { unrecoverableCounts[index] += 1 }
        }
    }

    public func overflows(_ slot: Slot) -> Int { lock.withLock { overflowCounts[slot.rawValue] } }
    public func unrecoverable(_ slot: Slot) -> Int { lock.withLock { unrecoverableCounts[slot.rawValue] } }
}
