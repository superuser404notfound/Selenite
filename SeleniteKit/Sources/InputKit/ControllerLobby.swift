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
    public var includesClaimed = false
    private var detector = LobbyEdgeDetector()
    private var adopted: [PadID: GCController] = [:]
    private var observers: [NSObjectProtocol] = []

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
