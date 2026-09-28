import AppCore
import GameController
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Presents the stream screen with UIKit instead of SwiftUI's fullScreenCover. On device the
/// cover's own presentation dismissed itself on the Siri Remote's Menu before any handler inside it
/// ran (even a GCEventViewController around its content). Presented directly, the container is the
/// top view controller: Menu reaches nothing above it, and it swallows every Menu itself.
struct StreamPresenter: UIViewControllerRepresentable {
    let stream: StreamController?
    let model: AppModel

    func makeUIViewController(context: Context) -> StreamPresenterController {
        StreamPresenterController()
    }

    func updateUIViewController(_ presenter: StreamPresenterController, context: Context) {
        presenter.update(stream: stream, model: model)
    }
}

@MainActor
final class StreamPresenterController: UIViewController {
    private var shown: StreamController?
    private weak var container: StreamContainerController?
    private var pending: (StreamController, AppModel)?

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    func update(stream: StreamController?, model: AppModel) {
        if let stream {
            guard stream !== shown else { return }
            present(stream, model: model)
        } else if let container, shown != nil {
            shown = nil
            pending = nil
            container.dismissByApp { model.streamCoverDismissed() }
        } else {
            pending = nil
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let (stream, model) = pending { present(stream, model: model) }
    }

    private func present(_ stream: StreamController, model: AppModel) {
        guard view.window != nil else {
            pending = (stream, model)
            return
        }
        pending = nil
        shown = stream
        let content = AnyView(StreamCoverView(controller: stream).environment(model).tint(.cyan))
        let container = StreamContainerController(controller: stream, content: content)
        container.modalPresentationStyle = .fullScreen
        container.onDismissedBySystem = {
            DiagnosticLog.note("[menu] the system dismissed the stream screen; disconnecting")
            stream.disconnect()
        }
        self.container = container
        var top: UIViewController = view.window?.rootViewController ?? self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(container, animated: true)
    }
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
    private var dismissingByApp = false
    /// Called when tvOS takes the screen down without the app asking (should not happen now).
    var onDismissedBySystem: (() -> Void)?
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
        if isBeingDismissed, !dismissingByApp { onDismissedBySystem?() }
        teardown()
    }

    /// The app ends the stream screen once the session has stopped.
    func dismissByApp(completion: @escaping () -> Void) {
        dismissingByApp = true
        dismiss(animated: true, completion: completion)
    }

    /// Follows `isOverlayOpen` for as long as the container lives.
    private func observeOverlay() {
        guard !tornDown else { return }
        let open = withObservationTracking {
            controller.isOverlayOpen
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOverlay() }
        }
        let wasOpen = controllerUserInteractionEnabled
        controllerUserInteractionEnabled = open
        // After the overlay closes, pull focus back inside the stream screen. The request must come
        // from the container: UIKit ignores it from the surface, which does not hold the focused
        // Resume button, and a focus left nowhere let Menu bypass this controller before.
        if wasOpen, !open {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
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
