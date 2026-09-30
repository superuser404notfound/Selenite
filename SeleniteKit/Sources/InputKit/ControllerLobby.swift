#if os(tvOS)
import Foundation
import GameController

/// Presses from gamepads that play on no host (M2 spec, section 4): joining a side, the "Left or
/// right?" prompt, reconnecting a side. A gamepad a side's `ControllerManager` holds is left to
/// that manager; while `includesClaimed` is on (reassigning), the managers pass its input in
/// through `ingest`.
@MainActor
public final class ControllerLobby {
    public var onEvent: (@MainActor (PadID, LobbyEvent) -> Void)?
    public var onPadsChanged: (@MainActor (Set<PadID>) -> Void)?
    public var isClaimed: @MainActor (PadID) -> Bool = { _ in false }
    /// Off between seat changes: a claimed pad's presses reach `ingest` only through the reassign
    /// flow, not on every report. On the rising edge, every connected pad the lobby has not adopted
    /// (the claimed ones) gets a fresh baseline, so a button already held in game is not read back
    /// as a new press the moment reassigning starts; the falling edge forgets those baselines again.
    public var includesClaimed = false {
        didSet {
            guard includesClaimed != oldValue else { return }
            for controller in GCController.controllers() {
                let id = ObjectIdentifier(controller)
                guard adopted[id] == nil, let pad = controller.extendedGamepad else { continue }
                if includesClaimed {
                    detector.baseline(pad: id, snapshot: ControllerManager.snapshot(of: pad))
                } else {
                    detector.forget(id)
                }
            }
        }
    }
    private var detector = LobbyEdgeDetector()
    private var adopted: [PadID: GCController] = [:]
    private var observers: [NSObjectProtocol] = []
    /// The connected set last reported: a refresh reports only a change, so a caller that
    /// refreshes from inside `onPadsChanged` does not recurse.
    private var reportedLive: Set<PadID>?

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in adopted.values { controller.extendedGamepad?.valueChangedHandler = nil }
        adopted.removeAll()
        detector = LobbyEdgeDetector()
        reportedLive = nil
    }

    /// Adopts every connected gamepad no manager holds, lets go of the ones a manager took over,
    /// and reports the connected set.
    public func refresh() {
        guard !observers.isEmpty else { return }
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }
        let live = Set(connected.map(ObjectIdentifier.init))
        for (id, controller) in adopted where !live.contains(id) || isClaimed(id) {
            // A claimed pad's handler already belongs to its manager.
            if !live.contains(id) { controller.extendedGamepad?.valueChangedHandler = nil }
            adopted[id] = nil
            detector.forget(id)
        }
        for controller in connected {
            let id = ObjectIdentifier(controller)
            guard adopted[id] == nil, !isClaimed(id), let pad = controller.extendedGamepad else { continue }
            adopted[id] = controller
            detector.baseline(pad: id, snapshot: ControllerManager.snapshot(of: pad))
            pad.valueChangedHandler = { [weak self] pad, _ in
                MainActor.assumeIsolated { self?.ingest(id, pad) }
            }
        }
        guard live != reportedLive else { return }
        reportedLive = live
        onPadsChanged?(live)
    }

    public func ingest(_ id: PadID, _ pad: GCExtendedGamepad) {
        guard adopted[id] != nil || includesClaimed else { return }
        for event in detector.events(pad: id, snapshot: ControllerManager.snapshot(of: pad)) {
            onEvent?(id, event)
        }
    }
}
#endif
