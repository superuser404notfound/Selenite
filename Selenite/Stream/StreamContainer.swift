import AppCore
import GameController
import InputKit
import Observation
import QuartzCore
import StreamKit
import SwiftUI
import UIKit

/// The stream screen, placed in the view hierarchy in place of Home rather than presented. Every
/// presentation tried on device (a SwiftUI fullScreenCover, then a UIKit modal) was dismissed by
/// tvOS itself on the Siri Remote's Menu, whatever the handlers inside did. Nothing presented means
/// nothing to dismiss; the M1-A harness streamed this way and never had the problem.
struct StreamContainer: UIViewControllerRepresentable {
    let controller: StreamController
    let model: AppModel

    func makeUIViewController(context: Context) -> StreamContainerController {
        StreamContainerController(controller: controller,
                                  content: AnyView(StreamCoverView(controller: controller).environment(model).tint(.cyan)))
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
    /// One per Siri Remote, keyed like `remotes`.
    private var pointers: [ObjectIdentifier: RemotePointer] = [:]

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
            pointers.removeValue(forKey: id)
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
                observePointer(pad, id: ObjectIdentifier(controller))
            } else {
                continue
            }
            remotes[ObjectIdentifier(controller)] = controller
        }
    }

    private static func clearHandlers(_ controller: GCController) {
        if let gamepad = controller.extendedGamepad {
            gamepad.buttonB.pressedChangedHandler = nil
        } else if let pad = controller.microGamepad {
            pad.buttonMenu.pressedChangedHandler = nil
            pad.dpad.valueChangedHandler = nil
            pad.buttonA.pressedChangedHandler = nil
            pad.buttonX.pressedChangedHandler = nil
            pad.reportsAbsoluteDpadValues = false
        }
    }

    private func stopObservingRemotes() {
        remoteObservers.forEach(NotificationCenter.default.removeObserver)
        remoteObservers.removeAll()
        for controller in remotes.values { Self.clearHandlers(controller) }
        remotes.removeAll()
        pointers.removeAll()
    }

    /// The Siri Remote as a trackpad for the host's mouse: the touch surface moves the pointer, its
    /// click is the left button and Play/Pause the right one. `StreamController` drops all of it
    /// while the overlay is open or the stream is not running.
    private func observePointer(_ pad: GCMicroGamepad, id: ObjectIdentifier) {
        pointers[id] = RemotePointer()
        pad.reportsAbsoluteDpadValues = true
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.pointerTouched(id: id, x: x, y: y) }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.pointerClicked(id: id, pressed: pressed) }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.pointerButton(.right, pressed: pressed) }
        }
    }

    private func pointerTouched(id: ObjectIdentifier, x: Float, y: Float) {
        guard !tornDown, var pointer = pointers[id] else { return }
        let move = pointer.touch(x: x, y: y, time: CACurrentMediaTime())
        pointers[id] = pointer
        controller.pointerMoved(dx: move.dx, dy: move.dy)
    }

    private func pointerClicked(id: ObjectIdentifier, pressed: Bool) {
        pointers[id]?.setClick(pressed: pressed)
        pointerButton(.left, pressed: pressed)
    }

    private func pointerButton(_ button: MouseButton, pressed: Bool) {
        guard !tornDown else { return }
        controller.pointerButton(button, pressed: pressed)
    }

    /// Siri Remote Menu, on release: opens the overlay, and with it open leaves the stream.
    private func remoteMenuChanged(pressed: Bool) {
        guard !pressed, !tornDown else { return }
        let now = CACurrentMediaTime()
        lastControllerMenu = now
        controller.menuPressed(now: now)
    }

    /// A gamepad's B closes the overlay. While the overlay is closed B belongs to the game; its time
    /// is recorded either way, so its UIKit `.menu` twin is never taken for a TV remote.
    private func gamepadBChanged(pressed: Bool) {
        guard !pressed, !tornDown else { return }
        lastControllerMenu = CACurrentMediaTime()
        guard controller.isOverlayOpen else { return }
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
            return
        }
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
