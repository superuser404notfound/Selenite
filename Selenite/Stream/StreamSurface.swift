import AppCore
import AVFoundation
import GameController
import QuartzCore
import StreamKit
import SwiftUI
import UIKit

// Adapted from Selenite/Developer/StreamStageView.swift (the harness stage), solo only.

struct StreamSurface: UIViewControllerRepresentable {
    let controller: StreamController
    /// Read in the parent's body, so an overlay change re-renders this representable.
    let isOverlayOpen: Bool

    func makeUIViewController(context: Context) -> StreamSurfaceController {
        StreamSurfaceController(controller: controller)
    }

    func updateUIViewController(_ surface: StreamSurfaceController, context: Context) {
        surface.setOverlayOpen(isOverlayOpen)
    }
}

final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Focusable while the overlay is closed, so the surface receives presses instead of the SwiftUI
/// host behind it; not focusable while the overlay is open, so focus stays on the overlay.
final class SurfaceRootView: UIView {
    var acceptsFocus = true
    override var canBecomeFocused: Bool { acceptsFocus }
}

/// A `GCEventViewController` with controller user interaction off while the overlay is closed:
/// tvOS would otherwise also deliver game controller buttons to UIKit as presses, and B arrives as
/// `.menu`. While the overlay is open it is on, so controllers navigate the overlay (B backs out).
@MainActor
final class StreamSurfaceController: GCEventViewController {
    private let controller: StreamController
    private let pacer = DisplayPacer()
    private let videoView = VideoLayerView()
    private weak var displayWindow: UIWindow?
    private var tornDown = false
    private var overlayOpen = false
    private var windowMenuCatcher: UITapGestureRecognizer?
    private var remoteObservers: [NSObjectProtocol] = []
    private var remotes: [ObjectIdentifier: GCController] = [:]

    init(controller: StreamController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = SurfaceRootView()
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [view] }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = false
        view.backgroundColor = .black
        videoView.displayLayer.videoGravity = .resizeAspect
        videoView.displayLayer.preferredDynamicRange = .standard
        view.addSubview(videoView)
        pacer.attach(pacer: controller.session.pacer, layer: videoView.displayLayer)
        startObservingRemotes()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoView.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A controller is not touch input to the idle timer: without this the screensaver or
        // sleep starts in the middle of a game.
        UIApplication.shared.isIdleTimerDisabled = true
        if let window = view.window {
            displayWindow = window
            // A Menu that reaches UIKit while no stream view holds focus (the overlay just opened
            // or closed) would otherwise fall through to the presented cover and dismiss it, which
            // ends the stream. Catching it on the window routes every such press to the overlay.
            if windowMenuCatcher == nil {
                let catcher = UITapGestureRecognizer(target: self, action: #selector(windowMenuPressed))
                catcher.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
                window.addGestureRecognizer(catcher)
                windowMenuCatcher = catcher
            }
            let fps = controller.settings.fps
            DisplayModeController.apply(hdr: false, refreshRate: Float(fps >= 50 ? fps : 60), window: window)
        }
        pacer.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        teardown()
    }

    func setOverlayOpen(_ open: Bool) {
        guard open != overlayOpen, !tornDown else { return }
        overlayOpen = open
        controllerUserInteractionEnabled = open
        (view as? SurfaceRootView)?.acceptsFocus = !open
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    // MARK: Siri Remote

    /// With controller user interaction off, the Siri Remote's Menu does not reach UIKit either, so
    /// it is read through GameController: a controller with a micro profile and no extended one is
    /// a Siri Remote (an extended gamepad also reports a micro profile).
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

    /// The overlay is driven through GameController only, which sees every press whatever UIKit's
    /// focus is doing: the Siri Remote's Menu toggles it on release, in both states. UIKit also
    /// receives the Menu while the overlay is open, and there it is only swallowed (the overlay's
    /// and the cover's exit commands), because acting on it there dismissed the cover on every
    /// second press on device.
    private func remoteMenuChanged(pressed: Bool) {
        guard !pressed else { return }
        DiagnosticLog.note("[menu] remote, overlay open: \(controller.isOverlayOpen)")
        menuPressed()
    }

    /// A gamepad's B closes the overlay (it also arrives in UIKit as Menu, which is swallowed
    /// there). While the overlay is closed B belongs to the game.
    private func gamepadBChanged(pressed: Bool) {
        guard !pressed, controller.isOverlayOpen else { return }
        DiagnosticLog.note("[menu] gamepad B closes the overlay")
        menuPressed()
    }

    @objc private func windowMenuPressed() {
        DiagnosticLog.note("[menu] swallowed on the window, overlay open: \(controller.isOverlayOpen)")
    }

    private func menuPressed() {
        controller.menuPressed(now: CACurrentMediaTime())
    }

    // A Menu that still arrives as a press (a TV remote over HDMI-CEC, which is no GameController
    // device) is consumed here in full: passed on, the SwiftUI host would background the app.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            // A TV remote over HDMI-CEC is no GameController; the surface only holds focus while
            // the overlay is closed, so this can only open it.
            if !overlayOpen {
                DiagnosticLog.note("[menu] press on the surface opens the overlay")
                menuPressed()
            }
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesChanged(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesCancelled(presses, with: event)
    }

    /// Runs when the cover leaves the screen; only the first call acts.
    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        UIApplication.shared.isIdleTimerDisabled = false
        if let catcher = windowMenuCatcher { catcher.view?.removeGestureRecognizer(catcher) }
        windowMenuCatcher = nil
        stopObservingRemotes()
        controllerUserInteractionEnabled = true
        pacer.stop()
        if let window = view.window ?? displayWindow { DisplayModeController.reset(window: window) }
    }
}
