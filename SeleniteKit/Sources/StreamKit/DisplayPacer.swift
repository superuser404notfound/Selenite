#if os(tvOS)
import AVFoundation
import QuartzCore

/// The one path to a renderer: the vsync tick enqueues on the main thread, a direct present on
/// the decode thread (see FramePacer), so every enqueue and the failure flush take this lock.
final class FramePresenter: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func enqueue(_ frame: CMSampleBuffer) {
        lock.withLock {
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(frame)
        }
    }

    func flushIfFailed() {
        lock.withLock {
            if renderer.status == .failed { renderer.flush() }
        }
    }

    func clear() {
        lock.withLock { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    }
}

/// One CADisplayLink for all sessions: on every vsync each layer gets the newest decoded frame,
/// so split-screen halves change on the same refresh.
@MainActor
public final class DisplayPacer {
    private struct Output {
        let pacer: FramePacer<CMSampleBuffer>
        let presenter: FramePresenter
        let layer: AVSampleBufferDisplayLayer
    }

    // CADisplayLink fires on the main run loop it was added to.
    @MainActor
    private final class Target: NSObject {
        weak var pacer: DisplayPacer?
        @objc func tick(_ link: CADisplayLink) {
            pacer?.tick(link)
        }
    }

    private var outputs: [Output] = []
    private var link: CADisplayLink?
    private let target = Target()

    public init() {
        target.pacer = self
    }

    public func attach(pacer: FramePacer<CMSampleBuffer>, layer: AVSampleBufferDisplayLayer) {
        let presenter = FramePresenter(renderer: layer.sampleBufferRenderer)
        pacer.setPresenter { presenter.enqueue($0) }
        outputs.append(Output(pacer: pacer, presenter: presenter, layer: layer))
    }

    /// Stops feeding `layer` and clears its picture; a layer this pacer never fed is only cleared.
    public func detach(layer: AVSampleBufferDisplayLayer) {
        let detached = outputs.filter { $0.layer === layer }
        guard !detached.isEmpty else {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            return
        }
        outputs.removeAll { $0.layer === layer }
        for output in detached {
            output.pacer.setPresenter(nil)
            output.presenter.clear()
        }
    }

    public func start() {
        link?.invalidate()
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public func stop() {
        link?.invalidate()
        link = nil
        for output in outputs { output.pacer.setPresenter(nil) }
        outputs.removeAll()
    }

    private func tick(_ link: CADisplayLink) {
        // The moment this callback runs is where a late frame misses, not link.timestamp (the
        // refresh that already happened), so arrival phase is measured against it.
        let now = CACurrentMediaTime()
        for output in outputs {
            output.pacer.vsync(timestamp: link.timestamp, duration: link.targetTimestamp - link.timestamp,
                               tickTime: now)
            output.presenter.flushIfFailed()
            if let frame = output.pacer.tick() {
                output.presenter.enqueue(frame)
            }
        }
    }
}
#endif
