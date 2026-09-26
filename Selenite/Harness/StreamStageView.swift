import AVFoundation
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

@MainActor
final class StreamStageController: UIViewController {
    private let model: HarnessModel
    private let pacer = DisplayPacer()
    private var halves: [(view: StreamLayerView, label: UILabel)] = []
    private var statsTimer: Timer?

    init(model: HarnessModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
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
            pacer.attach(mailbox: session.mailbox, layer: layerView.displayLayer)
        }
        let menu = UITapGestureRecognizer(target: self, action: #selector(exitStream))
        menu.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menu)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window {
            DisplayModeController.apply(hdr: model.hdr && model.layout == .solo, refreshRate: 60, window: window)
        }
        pacer.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
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
            let fps = stats.mailbox.delivered - (last?.mailbox.delivered ?? 0)
            let dropped = stats.mailbox.dropped - (last?.mailbox.dropped ?? 0)
            halves[index].label.text = String(
                format: "shown %d fps  mailbox drops %d/s  decode %.2f ms  net drops %d  rtt %@",
                fps, dropped, stats.averageDecodeMilliseconds, stats.networkDroppedFrames,
                stats.rttMilliseconds.map { "\($0) ms" } ?? "n/a")
            halves[index].label.sizeToFit()
        }
        previous = current
    }

    @objc private func exitStream() {
        statsTimer?.invalidate()
        pacer.stop()
        if let window = view.window { DisplayModeController.reset(window: window) }
        Task { await model.stop() }
    }
}
