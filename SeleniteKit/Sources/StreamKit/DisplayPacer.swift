#if os(tvOS)
import AVFoundation
import QuartzCore

/// One CADisplayLink for all sessions: on every vsync each layer gets the newest decoded frame,
/// so split-screen halves change on the same refresh.
@MainActor
public final class DisplayPacer {
    private struct Output {
        let pacer: FramePacer<CMSampleBuffer>
        let renderer: AVSampleBufferVideoRenderer
    }

    // CADisplayLink fires on the main run loop it was added to.
    @MainActor
    private final class Target: NSObject {
        weak var pacer: DisplayPacer?
        @objc func tick(_ link: CADisplayLink) {
            pacer?.tick()
        }
    }

    private var outputs: [Output] = []
    private var link: CADisplayLink?
    private let target = Target()

    public init() {
        target.pacer = self
    }

    public func attach(pacer: FramePacer<CMSampleBuffer>, layer: AVSampleBufferDisplayLayer) {
        outputs.append(Output(pacer: pacer, renderer: layer.sampleBufferRenderer))
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
        outputs.removeAll()
    }

    private func tick() {
        for output in outputs {
            if output.renderer.status == .failed { output.renderer.flush() }
            if let frame = output.pacer.tick() {
                output.renderer.enqueue(frame)
            }
        }
    }
}
#endif
