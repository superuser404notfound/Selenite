import AppCore
import GameController
import InputKit
import StreamKit

/// Controllers for a split: the lobby holds every unseated pad, each side's `ControllerManager`
/// holds the pads seated on it and forwards them to that side's session.
@MainActor
final class SplitInput: SplitInputHandle {
    private let lobby = ControllerLobby()
    private var sides: [SplitSide: SideInput] = [:]
    private(set) var seats = SeatMap()

    var onEvent: (@MainActor (PadID, LobbyEvent) -> Void)? {
        get { lobby.onEvent }
        set { lobby.onEvent = newValue }
    }

    var onPadsChanged: (@MainActor (Set<PadID>) -> Void)? {
        get { lobby.onPadsChanged }
        set { lobby.onPadsChanged = newValue }
    }

    init() {
        for side in SplitSide.allCases { sides[side] = SideInput(side: side, owner: self) }
        lobby.isClaimed = { [weak self] id in
            self?.sides.values.contains { $0.holds(id) } ?? false
        }
    }

    func input(for side: SplitSide) -> any StreamInput {
        sides[side]!
    }

    func apply(_ seats: SeatMap) {
        self.seats = seats
        for side in SplitSide.allCases { sides[side]?.refresh() }
        lobby.refresh()
        for controller in GCController.controllers() where controller.extendedGamepad != nil {
            controller.playerIndex = switch seats.side(of: ObjectIdentifier(controller)) {
            case .first: .index1
            case .second: .index2
            case nil: .indexUnset
            }
        }
    }

    func setReassigning(_ reassigning: Bool) {
        lobby.includesClaimed = reassigning
        for side in sides.values { side.setForwarding(!reassigning) }
    }

    func start() {
        lobby.start()
    }

    func stop() {
        for side in sides.values { side.end() }
        lobby.stop()
        for controller in GCController.controllers() where controller.extendedGamepad != nil {
            controller.playerIndex = .indexUnset
        }
    }

    fileprivate func lobbyIngest(_ id: PadID, _ pad: GCExtendedGamepad) {
        lobby.ingest(id, pad)
    }

    fileprivate func lobbyRefresh() {
        lobby.refresh()
    }
}

/// One side's controllers: only the pads seated on it, lit with the side's player light.
@MainActor
private final class SideInput: StreamInput {
    private let side: SplitSide
    private weak var owner: SplitInput?
    private var manager: ControllerManager?
    private var feedback: ControllerFeedback?

    init(side: SplitSide, owner: SplitInput) {
        self.side = side
        self.owner = owner
    }

    func holds(_ pad: PadID) -> Bool {
        manager?.holds(pad) == true
    }

    func refresh() {
        manager?.refresh()
    }

    func begin(session: any StreamSessionHandle) {
        guard manager == nil, let session = session as? StreamSession else { return }
        let side = self.side
        let manager = ControllerManager(
            sink: session,
            admits: { [weak owner] controller in owner?.seats.side(of: ObjectIdentifier(controller)) == side },
            lightIndex: side == .first ? .index1 : .index2)
        manager.onInput = { [weak owner] id, pad in owner?.lobbyIngest(id, pad) }
        let feedback = ControllerFeedback(manager: manager)
        feedback.sink = session
        session.feedbackHandler = feedback
        self.manager = manager
        self.feedback = feedback
        manager.start()
        feedback.resume()
        // The manager has taken its pads; the lobby lets go of them.
        owner?.lobbyRefresh()
    }

    func sessionConnected() {
        manager?.reannounce()
    }

    func setForwarding(_ forwarding: Bool) {
        manager?.isForwarding = forwarding
    }

    /// The side's pads return to the lobby, where A reconnects the side.
    func end() {
        manager?.stop()
        feedback?.stopAll()
        manager = nil
        feedback = nil
        owner?.lobbyRefresh()
    }
}
