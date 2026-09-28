/// Controllers released on disconnect that `GCController.controllers()` may still list for a
/// while. A rescan must not re-add such a ghost (M1-A ledger, Task 9 minor). An entry is dropped
/// as soon as a rescan no longer lists the controller, or when a connect notification names it.
public struct DisconnectLedger: Sendable {
    private var released: Set<ObjectIdentifier> = []

    public init() {}

    public mutating func markReleased(_ id: ObjectIdentifier) {
        released.insert(id)
    }

    public mutating func markReconnected(_ id: ObjectIdentifier) {
        released.remove(id)
    }

    /// The live controllers to connect: not tracked yet and not a released ghost, in list order.
    public mutating func admissible(live: [ObjectIdentifier], tracked: Set<ObjectIdentifier>) -> [ObjectIdentifier] {
        released.formIntersection(Set(live))
        return live.filter { !tracked.contains($0) && !released.contains($0) }
    }
}
