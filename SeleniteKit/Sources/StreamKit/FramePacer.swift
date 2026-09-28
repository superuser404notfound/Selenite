import Foundation

public enum FramePacingMode: String, Sendable, CaseIterable {
    case lowLatency, smooth
}

public struct PacerStats: Sendable, Equatable {
    public var presented = 0
    /// Ticks with nothing to show: the stutter metric. In smooth mode this includes priming ticks.
    public var stalls = 0
    /// A frame arrived while the buffer was full (two frames in lowLatency, three in smooth);
    /// the oldest was discarded.
    public var overflowDrops = 0
    /// A standing lag was cut by skipping one frame (see FramePacer for when each mode does this).
    public var catchUpDrops = 0
    /// Ticks that presented a frame while another waited: one frame of latency paid.
    public var bufferedTicks = 0
    /// Sample standard deviation of frame inter-arrival time.
    public var jitterMilliseconds: Double = 0
    /// Diagnostics: where in the refresh interval frames arrive, in tenths after the last vsync.
    public var phaseBins = [Int](repeating: 0, count: 10)
    /// Diagnostics: running mean of frame inter-arrival time and of the vsync interval.
    public var arrivalIntervalMilliseconds: Double = 0
    public var vsyncIntervalMilliseconds: Double = 0
    public var vsyncs = 0

    public init() {}
}

/// Hand-off between the decoder and the vsync tick. Frames are shown in arrival order, so frames
/// that arrive bunched inside one refresh are shown on consecutive ticks instead of dropped.
///
/// `lowLatency` holds at most two frames and presents the oldest. A one-frame backlog that stands
/// for `lowLatencyCatchUpTicks` ticks is cut, but only while recent arrivals sit away from the tick:
/// while they straddle it, cutting the lag leaves the next tick empty (a drop followed by a stall),
/// so the lag is kept until the arrival phase has moved on.
///
/// `smooth` keeps one frame standing as a jitter buffer: it holds up to three, primes to two before
/// presenting (after the start and after every stall), and cuts one frame when two have stayed
/// queued for `smoothCatchUpTicks` ticks, which only clock drift between host and display causes.
///
/// `Frame` carries no `Sendable` constraint: `CMSampleBufferRef` is `CM_SWIFT_NONSENDABLE` in this
/// SDK, but frames still cross from the decode thread to the vsync tick and must be treated as
/// immutable once put.
public final class FramePacer<Frame>: @unchecked Sendable {
    static var lowLatencyCatchUpTicks: Int { 30 }
    static var smoothCatchUpTicks: Int { 120 }
    static var smoothPrimeFrames: Int { 2 }
    /// Arrivals whose phase decides whether a low latency catch-up is safe.
    static var phaseWindow: Int { 16 }
    /// Mean distance of those arrivals from the tick, as a fraction of the refresh interval.
    static var safePhaseDistance: Double { 0.2 }

    public let mode: FramePacingMode
    public var capacity: Int { mode == .smooth ? 3 : 2 }

    private let lock = NSLock()
    private var queue: [Frame] = []
    private var backlogTicks = 0
    private var primed = false
    private var counters = PacerStats()
    private var lastArrival: Double?
    private var intervalCount = 0
    private var intervalMean = 0.0
    private var intervalM2 = 0.0
    private var lastVsync = 0.0
    private var vsyncDuration = 0.0
    private var vsyncIntervalSum = 0.0
    private var phaseDistances: [Double] = []
    private var phaseDistanceIndex = 0

    public init(mode: FramePacingMode = .lowLatency) {
        self.mode = mode
        queue.reserveCapacity(4)
        phaseDistances.reserveCapacity(Self.phaseWindow)
    }

    public func put(_ frame: Frame, arrival: Double) {
        lock.withLock {
            if let last = lastArrival {
                let interval = (arrival - last) * 1000
                intervalCount += 1
                let delta = interval - intervalMean
                intervalMean += delta / Double(intervalCount)
                intervalM2 += delta * (interval - intervalMean)
            }
            lastArrival = arrival
            var distance = 0.5
            if lastVsync > 0, vsyncDuration > 0 {
                let phase = (arrival - lastVsync) / vsyncDuration
                let fraction = phase - phase.rounded(.down)
                counters.phaseBins[min(9, max(0, Int(fraction * 10)))] += 1
                distance = min(fraction, 1 - fraction)
            }
            recordPhaseDistance(distance)
            if queue.count >= capacity {
                queue.removeFirst()
                counters.overflowDrops += 1
            }
            queue.append(frame)
        }
    }

    /// Diagnostics: the vsync this tick belongs to, so arrivals can be placed in the refresh interval.
    public func vsync(timestamp: Double, duration: Double) {
        lock.withLock {
            if lastVsync > 0, timestamp > lastVsync {
                vsyncIntervalSum += (timestamp - lastVsync) * 1000
                counters.vsyncs += 1
            }
            lastVsync = timestamp
            vsyncDuration = duration
        }
    }

    public func tick() -> Frame? {
        lock.withLock {
            switch mode {
            case .lowLatency: lowLatencyTick()
            case .smooth: smoothTick()
            }
        }
    }

    private func lowLatencyTick() -> Frame? {
        guard !queue.isEmpty else { return stall() }
        var frame = queue.removeFirst()
        if queue.isEmpty {
            backlogTicks = 0
        } else {
            backlogTicks += 1
            if backlogTicks >= Self.lowLatencyCatchUpTicks, arrivalsAreAwayFromTheTick {
                frame = queue.removeFirst()
                counters.catchUpDrops += 1
                backlogTicks = 0
            } else {
                counters.bufferedTicks += 1
            }
        }
        counters.presented += 1
        return frame
    }

    private func smoothTick() -> Frame? {
        if !primed {
            guard queue.count >= Self.smoothPrimeFrames else { return stall() }
            primed = true
        }
        guard !queue.isEmpty else { return stall() }
        var frame = queue.removeFirst()
        if queue.count >= 2 {
            backlogTicks += 1
        } else {
            backlogTicks = 0
        }
        if backlogTicks >= Self.smoothCatchUpTicks {
            frame = queue.removeFirst()
            counters.catchUpDrops += 1
            backlogTicks = 0
        } else if !queue.isEmpty {
            counters.bufferedTicks += 1
        }
        counters.presented += 1
        return frame
    }

    private func stall() -> Frame? {
        counters.stalls += 1
        backlogTicks = 0
        primed = false
        return nil
    }

    private func recordPhaseDistance(_ distance: Double) {
        if phaseDistances.count < Self.phaseWindow {
            phaseDistances.append(distance)
        } else {
            phaseDistances[phaseDistanceIndex] = distance
        }
        phaseDistanceIndex = (phaseDistanceIndex + 1) % Self.phaseWindow
    }

    /// Before any vsync is known every arrival counts as mid-interval (0.5), so this is true.
    private var arrivalsAreAwayFromTheTick: Bool {
        guard !phaseDistances.isEmpty else { return true }
        let mean = phaseDistances.reduce(0, +) / Double(phaseDistances.count)
        return mean >= Self.safePhaseDistance
    }

    public var stats: PacerStats {
        lock.withLock {
            var snapshot = counters
            snapshot.jitterMilliseconds = intervalCount > 1 ? (intervalM2 / Double(intervalCount - 1)).squareRoot() : 0
            snapshot.arrivalIntervalMilliseconds = intervalMean
            snapshot.vsyncIntervalMilliseconds = counters.vsyncs > 0 ? vsyncIntervalSum / Double(counters.vsyncs) : 0
            return snapshot
        }
    }
}
