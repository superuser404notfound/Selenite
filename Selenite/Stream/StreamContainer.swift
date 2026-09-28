import AppCore
import GameController
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// The stream cover's content: one `GCEventViewController` that hosts the whole stream screen, so
/// every focused item on it (the surface, the overlay's buttons) has this controller in its
/// responder chain and a Menu press can never travel up to the cover's presentation.
struct StreamContainer: UIViewControllerRepresentable {
    let controller: StreamController
    let model: AppModel

    func makeUIViewController(context: Context) -> StreamContainerController {
        StreamContainerController(controller: controller,
                                  content: AnyView(StreamCoverView(controller: controller).environment(model)))
    }

    func updateUIViewController(_ container: StreamContainerController, context: Context) {}
}

/// Controller user interaction is off while the overlay is closed, so every controller button and
/// the Siri Remote go to GameController only (B would otherwise arrive in UIKit as `.menu`). While
/// the overlay is open it is on, so gamepads and the remote navigate it.
///
/// Menu paths: the Siri Remote's Menu and a gamepad's B are acted on through GameController only.
/// Every `.menu` press that reaches UIKit is swallowed here; it is acted on only when no
/// GameController device reported Menu or B around the same moment, which leaves exactly the TV
/// remotes over HDMI-CEC, which are no GameController devices.
@MainActor
final class StreamContainerController: GCEventViewController {
    /// A UIKit Menu is decided this long after its release, so a GameController report of the same
    /// press has arrived whichever of the two paths tvOS delivers first.
    private static let pressSettleDelay: Duration = .milliseconds(150)

    private let controller: StreamController
    private let host: UIHostingController<AnyView>
    private var tornDown = false
    private var remoteObservers: [NSObjectProtocol] = []
    private var remotes: [ObjectIdentifier: GCController] = [:]
    /// Release time (CACurrentMediaTime) of the last Siri Remote Menu or gamepad B GameController saw.
    private var lastControllerMenu = -Double.infinity

    init(controller: StreamController, content: AnyView) {
        self.controller = controller
        self.host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        host.view.backgroundColor = .black
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        observeOverlay()
        startObservingRemotes()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        teardown()
    }

    /// Follows `isOverlayOpen` for as long as the container lives.
    private func observeOverlay() {
        guard !tornDown else { return }
        let open = withObservationTracking {
            controller.isOverlayOpen
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOverlay() }
        }
        controllerUserInteractionEnabled = open
    }

    // MARK: GameController

    /// With controller user interaction off, the Siri Remote does not reach UIKit either, so its Menu
    /// is read here: a controller with a micro profile and no extended one is a Siri Remote (an
    /// extended gamepad also reports a micro profile).
    private func startObservingRemotes() {
        guard remoteObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // Both notifications rescan rather than read `note.object`, which is not Sendable.
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            remoteObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRemotes() }
            })
        }
        refreshRemotes()
    }

    private func refreshRemotes() {
        let connected = GCController.controllers()
        let live = Set(connected.map(ObjectIdentifier.init))
        for id in remotes.keys where !live.contains(id) {
            if let gone = remotes.removeValue(forKey: id) { Self.clearHandlers(gone) }
        }
        for controller in connected where remotes[ObjectIdentifier(controller)] == nil {
            // Handlers run on the main queue.
            if let gamepad = controller.extendedGamepad {
                gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated { self?.gamepadBChanged(pressed: pressed) }
                }
            } else if let pad = controller.microGamepad {
                pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated { self?.remoteMenuChanged(pressed: pressed) }
                }
            } else {
                continue
            }
            remotes[ObjectIdentifier(controller)] = controller
        }
    }

    private static func clearHandlers(_ controller: GCController) {
        if let gamepad = controller.extendedGamepad {
            gamepad.buttonB.pressedChangedHandler = nil
        } else {
            controller.microGamepad?.buttonMenu.pressedChangedHandler = nil
        }
    }

    private func stopObservingRemotes() {
        remoteObservers.forEach(NotificationCenter.default.removeObserver)
        remoteObservers.removeAll()
        for controller in remotes.values { Self.clearHandlers(controller) }
        remotes.removeAll()
    }

    /// Siri Remote Menu, on release: opens the overlay, and with it open leaves the stream.
    private func remoteMenuChanged(pressed: Bool) {
        guard !pressed, !tornDown else { return }
        let now = CACurrentMediaTime()
        lastControllerMenu = now
        DiagnosticLog.note("[menu] remote, overlay open: \(controller.isOverlayOpen)")
        controller.menuPressed(now: now)
    }

    /// A gamepad's B closes the overlay. While the overlay is closed B belongs to the game; its time
    /// is recorded either way, so its UIKit `.menu` twin is never taken for a TV remote.
    private func gamepadBChanged(pressed: Bool) {
        guard !pressed, !tornDown else { return }
        lastControllerMenu = CACurrentMediaTime()
        guard controller.isOverlayOpen else { return }
        DiagnosticLog.note("[menu] gamepad B closes the overlay")
        controller.closeOverlay()
    }

    // MARK: UIKit presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { $0.type != .menu }
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { $0.type != .menu }
        if !others.isEmpty { super.pressesChanged(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { $0.type != .menu }
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { $0.type != .menu }
        if !others.isEmpty { super.pressesEnded(others, with: event) }
        guard others.count != presses.count else { return }
        let released = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pressSettleDelay)
            self?.uikitMenuReleased(at: released)
        }
    }

    private func uikitMenuReleased(at released: Double) {
        guard !tornDown else { return }
        if abs(released - lastControllerMenu) < StreamController.menuDebounceSeconds {
            DiagnosticLog.note("[menu] press swallowed, GameController already handled it")
            return
        }
        DiagnosticLog.note("[menu] TV remote press, overlay open: \(controller.isOverlayOpen)")
        controller.menuPressed(now: released)
    }

    /// Runs when the cover leaves the screen; only the first call acts.
    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stopObservingRemotes()
        controllerUserInteractionEnabled = true
    }
}
