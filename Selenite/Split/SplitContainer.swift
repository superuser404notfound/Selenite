import AppCore
import AVFoundation
import GameController
import InputKit
import Observation
import QuartzCore
import StreamKit
import SwiftUI
import UIKit

/// The split screen, in place of Home like `StreamContainer` and for the same reason: nothing
/// presented means nothing tvOS can dismiss on Menu.
struct SplitContainer: UIViewControllerRepresentable {
    let split: SplitController
    let model: AppModel

    func makeUIViewController(context: Context) -> SplitContainerController {
        SplitContainerController(split: split,
                                 content: AnyView(SplitScreenView(split: split).environment(model).tint(.cyan)))
    }

    func updateUIViewController(_ container: SplitContainerController, context: Context) {}
}

/// Which half a side shows in: `first` left or top, swapped when `isSwapped`.
enum SplitGeometry {
    static func frame(of side: SplitSide, in bounds: CGRect, layout: SplitLayout, swapped: Bool) -> CGRect {
        let leading = (side == .first) != swapped
        switch layout {
        case .sideBySide:
            let width = bounds.width / 2
            return CGRect(x: bounds.minX + (leading ? 0 : width), y: bounds.minY, width: width, height: bounds.height)
        case .topBottom:
            let height = bounds.height / 2
            return CGRect(x: bounds.minX, y: bounds.minY + (leading ? 0 : height), width: bounds.width, height: height)
        }
    }
}

/// Controller user interaction stays off, so every gamepad button goes to GameController only; it
/// is on only while the one-side game wizard is up. The Siri Remote is never forwarded in split:
/// its Menu, touch surface and click drive the split overlay here. Gamepad B belongs to the game.
///
/// Every `.menu` press that reaches UIKit is swallowed; it is acted on only when no Siri Remote
/// reported Menu around the same moment, which leaves the TV remotes over HDMI-CEC.
@MainActor
final class SplitContainerController: GCEventViewController {
    private static let pressSettleDelay: Duration = .milliseconds(150)
    private static let dpadThreshold: Float = 0.5

    private let split: SplitController
    private let surface: SplitSurfaceController
    private let host: UIHostingController<AnyView>
    private var tornDown = false
    private var remoteObservers: [NSObjectProtocol] = []
    private var remotes: [ObjectIdentifier: GCController] = [:]
    /// The direction each Siri Remote's touch surface last pointed past the threshold.
    private var dpadDirections: [ObjectIdentifier: OverlayDirection] = [:]
    private var lastRemoteMenu = -Double.infinity

    init(split: SplitController, content: AnyView) {
        self.split = split
        self.surface = SplitSurfaceController(split: split)
        self.host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [surface] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for child in [surface, host] as [UIViewController] {
            addChild(child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(child.view)
            child.didMove(toParent: self)
        }
        host.view.backgroundColor = .clear
        observeChoosingGame()
        startObservingRemotes()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        teardown()
    }

    /// The one-side game wizard is a focus panel: controllers navigate it through UIKit while it is up.
    private func observeChoosingGame() {
        guard !tornDown else { return }
        let choosing = withObservationTracking {
            split.isChoosingGame
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeChoosingGame() }
        }
        let wasChoosing = controllerUserInteractionEnabled
        controllerUserInteractionEnabled = choosing
        surface.setAcceptsFocus(!choosing)
        if wasChoosing, !choosing {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    // MARK: Siri Remote

    private func startObservingRemotes() {
        guard remoteObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            remoteObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRemotes() }
            })
        }
        refreshRemotes()
    }

    /// A micro profile without an extended one is a Siri Remote; gamepads are left to `SplitInput`.
    private func refreshRemotes() {
        let connected = GCController.controllers()
        let live = Set(connected.map(ObjectIdentifier.init))
        for id in remotes.keys where !live.contains(id) {
            if let gone = remotes.removeValue(forKey: id) { Self.clearHandlers(gone) }
            dpadDirections.removeValue(forKey: id)
        }
        for controller in connected where remotes[ObjectIdentifier(controller)] == nil {
            guard controller.extendedGamepad == nil, let pad = controller.microGamepad else { continue }
            let id = ObjectIdentifier(controller)
            pad.reportsAbsoluteDpadValues = false
            pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.remoteMenuChanged(pressed: pressed) }
            }
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.remoteDpadChanged(id: id, x: x, y: y) }
            }
            pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.remoteSelectChanged(pressed: pressed) }
            }
            remotes[id] = controller
        }
    }

    private static func clearHandlers(_ controller: GCController) {
        guard controller.extendedGamepad == nil, let pad = controller.microGamepad else { return }
        pad.buttonMenu.pressedChangedHandler = nil
        pad.dpad.valueChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
    }

    private func stopObservingRemotes() {
        remoteObservers.forEach(NotificationCenter.default.removeObserver)
        remoteObservers.removeAll()
        for controller in remotes.values { Self.clearHandlers(controller) }
        remotes.removeAll()
        dpadDirections.removeAll()
    }

    private func remoteMenuChanged(pressed: Bool) {
        guard !pressed, !tornDown else { return }
        let now = CACurrentMediaTime()
        lastRemoteMenu = now
        split.menuPressed(now: now)
    }

    /// One move per swipe: a direction counts when the dominant axis first passes the threshold.
    private func remoteDpadChanged(id: ObjectIdentifier, x: Float, y: Float) {
        guard !tornDown else { return }
        let direction: OverlayDirection? = if max(abs(x), abs(y)) <= Self.dpadThreshold {
            nil
        } else if abs(x) >= abs(y) {
            x > 0 ? .right : .left
        } else {
            y > 0 ? .up : .down
        }
        let previous = dpadDirections[id]
        dpadDirections[id] = direction
        guard let direction, direction != previous, split.isOverlayOpen else { return }
        split.overlayMove(direction)
    }

    private func remoteSelectChanged(pressed: Bool) {
        guard !pressed, !tornDown, split.isOverlayOpen else { return }
        split.overlaySelect()
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
        if abs(released - lastRemoteMenu) < StreamController.menuDebounceSeconds { return }
        split.menuPressed(now: released)
    }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stopObservingRemotes()
        controllerUserInteractionEnabled = true
    }
}

/// Both videos on one display pacer, so the halves change on the same refresh; the display mode
/// and the idle timer as in `StreamSurfaceController`.
@MainActor
final class SplitSurfaceController: UIViewController {
    private let split: SplitController
    private let pacer = DisplayPacer()
    private let videoViews: [SplitSide: VideoLayerView] = [.first: VideoLayerView(), .second: VideoLayerView()]
    /// The StreamController each side's layer is attached to.
    private var attached: [SplitSide: UUID] = [:]
    private weak var displayWindow: UIWindow?
    private var tornDown = false

    init(split: SplitController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = SurfaceRootView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for side in SplitSide.allCases {
            guard let video = videoViews[side] else { continue }
            video.displayLayer.videoGravity = .resizeAspect
            video.displayLayer.preferredDynamicRange = .standard
            view.addSubview(video)
        }
        observeSplit()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for side in SplitSide.allCases {
            videoViews[side]?.frame = SplitGeometry.frame(of: side, in: view.bounds,
                                                          layout: split.plan.layout, swapped: split.isSwapped)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        if let window = view.window {
            displayWindow = window
            DisplayModeController.apply(hdr: false, refreshRate: 60, window: window)
        }
        pacer.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        teardown()
    }

    func setAcceptsFocus(_ accepts: Bool) {
        (view as? SurfaceRootView)?.acceptsFocus = accepts
    }

    /// Follows the streams (a reconnect brings a new controller for a side), the swap and the layout.
    private func observeSplit() {
        guard !tornDown else { return }
        let streams = withObservationTracking {
            _ = split.isSwapped
            _ = split.plan.layout
            return split.streams
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSplit() }
        }
        for side in SplitSide.allCases {
            guard let video = videoViews[side] else { continue }
            let stream = streams[side]
            guard stream?.id != attached[side] else { continue }
            if attached[side] != nil { pacer.detach(layer: video.displayLayer) }
            if let stream { pacer.attach(pacer: stream.session.pacer, layer: video.displayLayer) }
            attached[side] = stream?.id
        }
        view.setNeedsLayout()
    }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        UIApplication.shared.isIdleTimerDisabled = false
        pacer.stop()
        attached.removeAll()
        if let window = view.window ?? displayWindow { DisplayModeController.reset(window: window) }
    }
}
