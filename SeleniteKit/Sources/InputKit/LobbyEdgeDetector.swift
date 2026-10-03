/// A press from a controller that is not playing on a host (join screen, "Left or right?",
/// reconnect). Start is the gamepad's Menu button.
public enum LobbyEvent: Sendable, Equatable {
    case a(StickDirection)
    case b
    case start
}

/// Turns a pad's successive snapshots into presses. Without a baseline a pad counts as holding
/// nothing, because GameController reports a pad's first change, which may be the press itself.
public struct LobbyEdgeDetector: Sendable {
    private var previous: [PadID: GamepadSnapshot] = [:]

    public init() {}

    public mutating func baseline(pad: PadID, snapshot: GamepadSnapshot) {
        previous[pad] = snapshot
    }

    public mutating func events(pad: PadID, snapshot: GamepadSnapshot) -> [LobbyEvent] {
        let before = previous[pad] ?? GamepadSnapshot()
        previous[pad] = snapshot
        var events: [LobbyEvent] = []
        if snapshot.a && !before.a { events.append(.a(StickDirection.from(snapshot))) }
        if snapshot.b && !before.b { events.append(.b) }
        if snapshot.menu && !before.menu { events.append(.start) }
        return events
    }

    public mutating func forget(_ pad: PadID) {
        previous[pad] = nil
    }
}
