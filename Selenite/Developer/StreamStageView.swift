import AVFoundation
import GameController
import StreamKit
import SwiftUI
import UIKit

struct StreamStageView: UIViewControllerRepresentable {
    @Environment(HarnessModel.self) private var model

    func makeUIViewController(context: Context) -> StreamStageController {
        StreamStageController(model: model)
    }

    func updateUIViewController(_ controller: StreamStageController, context: Context) {}
}

final class StreamLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Focusable, so the stage receives the remote's presses instead of the SwiftUI host behind it.
final class StageRootView: UIView {
    override var canBecomeFocused: Bool { true }
}

/// A `GCEventViewController` with controller user interaction off while streaming: tvOS otherwise
/// also delivers game controller buttons to UIKit as presses, and B (on many pads Menu/Start too)
/// arrives as `.menu`, which would end the stream mid-game.
@MainActor
final class StreamStageController: GCEventViewController {
    private let model: HarnessModel
    private let pacer = DisplayPacer()
    private var halves: [(view: StreamLayerView, label: UILabel)] = []
    private var statsTimer: Timer?
    private weak var displayWindow: UIWindow?
    private var tornDown = false
    private var exiting = false
    private var remoteObservers: [NSObjectProtocol] = []
    private var remotes: [ObjectIdentifier: GCController] = [:]

    init(model: HarnessModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = StageRootView()
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [view] }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = false
        startObservingRemotes()
        view.backgroundColor = .black
        for session in model.sessions {
            let layerView = StreamLayerView()
            layerView.displayLayer.videoGravity = .resizeAspect
            if #available(tvOS 26.0, *) {
                layerView.displayLayer.preferredDynamicRange = model.hdr && model.layout == .solo ? .high : .standard
            }
            let label = UILabel()
            label.textColor = .white
            label.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
            label.numberOfLines = 0
            view.addSubview(layerView)
            view.addSubview(label)
            halves.append((layerView, label))
            pacer.attach(pacer: session.pacer, layer: layerView.displayLayer)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window {
            displayWindow = window
            DisplayModeController.apply(hdr: model.hdr && model.layout == .solo, refreshRate: 60, window: window)
        }
        pacer.start()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        teardown()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        for (index, half) in halves.enumerated() {
            let frame: CGRect = switch (model.layout, index) {
            case (.solo, _): bounds
            case (.sideBySide, 0): CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
            case (.sideBySide, _): CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
            case (.topBottom, 0): CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
            case (.topBottom, _): CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2)
            }
            half.view.frame = frame
            half.label.frame = frame.insetBy(dx: 40, dy: 40)
            half.label.sizeToFit()
        }
    }

    private var previous: [StreamStats] = []

    private func refreshStats() {
        let current = model.sessions.map { $0.stats() }
        for (index, stats) in current.enumerated() where index < halves.count {
            let last = index < previous.count ? previous[index] : nil
            let fps = Int32(stats.pacer.presented - (last?.pacer.presented ?? 0))
            let stallsPerMinute = Int32((stats.pacer.stalls - (last?.pacer.stalls ?? 0)) * 60)
            let bufferedPerSecond = Int32(stats.pacer.bufferedTicks - (last?.pacer.bufferedTicks ?? 0))
            let event = index < model.eventTexts.count ? model.eventTexts[index] : ""
            var text = String(
                format: "shown %d fps  stalls %d/min  overflow %d  catch-up %d  buffered %d/s  jitter %.1f ms  decode %.2f ms  net drops %d  rtt %@",
                fps, stallsPerMinute, Int32(stats.pacer.overflowDrops), Int32(stats.pacer.catchUpDrops), bufferedPerSecond,
                stats.pacer.jitterMilliseconds, stats.averageDecodeMilliseconds, Int32(stats.networkDroppedFrames),
                stats.rttMilliseconds.map { "\($0) ms" } ?? "n/a") + "\n" + event
            if let audio = stats.audio {
                let channels = index < model.audioChannels.count ? model.audioChannels[index] : .stereo
                let channelsText = channels == .surround51 ? "5.1" : "stereo"
                text += "\n" + String(format: "audio %@  fill %.0f ms  underruns %d  catch-up %d",
                                      channelsText, audio.fillMilliseconds, Int32(audio.underruns), Int32(audio.catchUps))
            }
            halves[index].label.text = text
            halves[index].label.sizeToFit()
        }
        previous = current
    }

    // MARK: Exit

    /// The Siri Remote's Menu no longer reaches UIKit either, so it is read through GameController:
    /// a controller with a micro profile and no extended one is a Siri Remote (an extended gamepad
    /// also reports a micro profile). Game controllers exit through the Start+Select hold instead.
    private func startObservingRemotes() {
        guard remoteObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // Both notifications re-scan rather than read `note.object`, which is not Sendable.
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
            remotes.removeValue(forKey: id)?.microGamepad?.buttonMenu.pressedChangedHandler = nil
        }
        for controller in connected where remotes[ObjectIdentifier(controller)] == nil {
            guard controller.extendedGamepad == nil, let pad = controller.microGamepad else { continue }
            // Exits on release, like the press handling this replaces. Handlers run on the main queue.
            pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                guard !pressed else { return }
                MainActor.assumeIsolated { self?.exitStream(reason: "Siri Remote Menu") }
            }
            remotes[ObjectIdentifier(controller)] = controller
        }
    }

    private func stopObservingRemotes() {
        remoteObservers.forEach(NotificationCenter.default.removeObserver)
        remoteObservers.removeAll()
        for controller in remotes.values { controller.microGamepad?.buttonMenu.pressedChangedHandler = nil }
        remotes.removeAll()
    }

    // Fallback for a Menu that still arrives as a press, e.g. a TV remote over HDMI-CEC, which is no
    // GameController device. Game controllers cannot reach this with controller user interaction off.
    // Menu is consumed here in full: passed on, the SwiftUI host would background the app with
    // both streams still running.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            exitStream(reason: "Menu press")
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

    /// The `exiting` latch keeps it to one exit per press, whichever path reports the press first.
    private func exitStream(reason: String) {
        guard !exiting else { return }
        exiting = true
        NSLog("[Selenite] stage exit: %@", reason)
        teardown()
        Task { await model.stop() }
    }

    /// Runs on Menu and again when the controller leaves the screen; only the first call acts.
    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stopObservingRemotes()
        controllerUserInteractionEnabled = true
        statsTimer?.invalidate()
        statsTimer = nil
        pacer.stop()
        if let window = view.window ?? displayWindow { DisplayModeController.reset(window: window) }
    }
}
