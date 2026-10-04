#if os(tvOS)
import AVFoundation
import Foundation
import QuartzCore

/// The one path to a renderer: the display-link tick enqueues from its own thread, a direct
/// present on the decode thread (see FramePacer), so every enqueue and the failure flush take
/// this lock.
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

/// What the display-link thread ticks: just the pacer/presenter pair, none of the layer identity
/// DisplayPacer needs on the main side for attach/detach matching.
private struct TickOutput: Sendable {
    let pacer: FramePacer<CMSampleBuffer>
    let presenter: FramePresenter
}

/// Owns the CADisplayLink and the dedicated thread it runs on, off the main thread. `add`/
/// `remove`/`stop` mutate `outputs` under `lock`; `tick(_:)` holds that same lock for its whole
/// pass over `outputs`, so a caller that waits for the lock (all three do) never returns while a
/// frame from one of those outputs is still being enqueued.
private final class DisplayLinkThread: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [TickOutput] = []
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var link: CADisplayLink?
    private var stopped: DispatchSemaphore?

    /// Starts the thread and its run loop, tearing down a previous one first if still running.
    func start() {
        stop()
        let stopped = DispatchSemaphore(value: 0)
        self.stopped = stopped
        let thread = Thread { [self] in
            self.runLoopBody()
            stopped.signal()
        }
        thread.name = "Selenite display link"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func runLoopBody() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .current, forMode: .common)
        lock.withLock {
            self.link = link
            self.runLoop = CFRunLoopGetCurrent()
        }
        CFRunLoopRun()
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The moment this callback runs is where a late frame misses, not link.timestamp (the
        // refresh that already happened), so arrival phase is measured against it.
        let now = CACurrentMediaTime()
        lock.withLock {
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

    /// Runs on the display-link thread (via `perform(_:on:with:waitUntilDone:)`): invalidating the
    /// link from any other thread is undefined, and stopping the run loop from outside it would
    /// just be ignored.
    @objc private func invalidateAndStopRunLoop() {
        link?.invalidate()
        link = nil
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Stops the run loop and waits for the thread to have left it, so no tick runs after this
    /// returns.
    func stop() {
        guard let thread, let stopped else { return }
        perform(#selector(invalidateAndStopRunLoop), on: thread, with: nil, waitUntilDone: true)
        stopped.wait()
        self.thread = nil
        self.stopped = nil
        self.runLoop = nil
        lock.withLock { outputs.removeAll() }
    }

    func add(_ output: TickOutput) {
        lock.withLock { outputs.append(output) }
    }

    func remove(_ pacer: FramePacer<CMSampleBuffer>) {
        lock.withLock { outputs.removeAll { $0.pacer === pacer } }
    }
}

/// One CADisplayLink for all sessions, running on its own thread (`DisplayLinkThread`) instead of
/// the main one: on every tick each layer gets the newest decoded frame, so split-screen halves
/// change on the same refresh. This type itself is reached only from the main actor; the layer
/// reference is kept here for that main-side identity matching and is never touched by the tick.
@MainActor
public final class DisplayPacer {
    private struct Output {
        let pacer: FramePacer<CMSampleBuffer>
        let presenter: FramePresenter
        let layer: AVSampleBufferDisplayLayer
    }

    private var outputs: [Output] = []
    private let linkThread = DisplayLinkThread()

    public init() {}

    public func attach(pacer: FramePacer<CMSampleBuffer>, layer: AVSampleBufferDisplayLayer) {
        let presenter = FramePresenter(renderer: layer.sampleBufferRenderer)
        pacer.setPresenter { presenter.enqueue($0) }
        outputs.append(Output(pacer: pacer, presenter: presenter, layer: layer))
        linkThread.add(TickOutput(pacer: pacer, presenter: presenter))
    }

    /// Stops feeding `layer` and clears its picture; a layer this pacer never fed is only cleared.
    /// The output is removed from the tick thread's list before the presenter is cleared, and
    /// that removal waits on the same lock a tick holds for its whole pass, so no frame reaches
    /// `layer` after this call returns.
    public func detach(layer: AVSampleBufferDisplayLayer) {
        let detached = outputs.filter { $0.layer === layer }
        guard !detached.isEmpty else {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            return
        }
        outputs.removeAll { $0.layer === layer }
        for output in detached {
            linkThread.remove(output.pacer)
            output.pacer.setPresenter(nil)
            output.presenter.clear()
        }
    }

    public func start() {
        linkThread.start()
    }

    public func stop() {
        linkThread.stop()
        for output in outputs { output.pacer.setPresenter(nil) }
        outputs.removeAll()
    }
}
#endif
