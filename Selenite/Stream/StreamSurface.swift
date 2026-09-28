import AppCore
import AVFoundation
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

/// Focusable while the overlay is closed, so focus stays inside the stream container (and a TV
/// remote's Menu reaches it); not focusable while the overlay is open, so focus stays on the overlay.
final class SurfaceRootView: UIView {
    var acceptsFocus = true
    override var canBecomeFocused: Bool { acceptsFocus }
}

/// The video, its display pacer, the display mode and the idle timer. Input lives one level up in
/// `StreamContainerController`, which hosts the whole stream screen.
@MainActor
final class StreamSurfaceController: UIViewController {
    private let controller: StreamController
    private let pacer = DisplayPacer()
    private let videoView = VideoLayerView()
    private weak var displayWindow: UIWindow?
    private var tornDown = false
    private var overlayOpen = false

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
        view.backgroundColor = .black
        videoView.displayLayer.videoGravity = .resizeAspect
        videoView.displayLayer.preferredDynamicRange = .standard
        view.addSubview(videoView)
        pacer.attach(pacer: controller.session.pacer, layer: videoView.displayLayer)
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
        (view as? SurfaceRootView)?.acceptsFocus = !open
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Runs when the cover leaves the screen; only the first call acts.
    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        UIApplication.shared.isIdleTimerDisabled = false
        pacer.stop()
        if let window = view.window ?? displayWindow { DisplayModeController.reset(window: window) }
    }
}
