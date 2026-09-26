import Foundation

public final class SlotAllocator: @unchecked Sendable {
    public static let shared = SlotAllocator()
    private let lock = NSLock()
    private var inUse: Set<Slot> = []

    public init() {}

    public func acquire() -> Slot? {
        lock.lock(); defer { lock.unlock() }
        guard let free = Slot.allCases.first(where: { !inUse.contains($0) }) else { return nil }
        inUse.insert(free)
        return free
    }

    public func release(_ slot: Slot) {
        lock.lock(); inUse.remove(slot); lock.unlock()
    }
}
