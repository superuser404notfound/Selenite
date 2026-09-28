import Foundation

public enum FramePacingMode: String, Sendable, CaseIterable {
    case lowLatency, smooth
}

public struct PacerStats: Sendable, Equatable {
    public var presented = 0
    /// Ticks with nothing to show beyond the stream cadence: the stutter metric. In smooth mode this
    /// includes priming ticks.
    public var stalls = 0
    /// A frame arrived while the buffer was full (two frames in lowLatency, three in smooth);
    /// the oldest was discarded.
    public var overflowDrops = 0
    /// A standing lag was cut by skipping one frame (see FramePacer for when each mode does this).
    public var catchUpDrops = 0
    /// Ticks that presented a frame while another waited: one frame of latency paid.
    public var bufferedTicks = 0
    /// Frames handed to the renderer on arrival instead of on a tick (direct present).
    public var directPresents = 0
    /// Sample standard deviation of frame inter-arrival time.
    public var jitterMilliseconds: Double = 0
    /// Diagnostics: where in the refresh interval frames arrive, in tenths after the last tick.
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
/// for `lowLatencyCatchUpTicks` ticks is cut, but only when none of the recent arrivals came close
/// to the tick: while they straddle it, cutting the lag leaves the next tick empty (a drop followed
/// by a stall), so the lag is kept until the arrival phase has moved on.
///
/// `smooth` keeps one frame standing as a jitter buffer: it holds up to three, primes to two before
/// presenting (after the start and after every stall), shows each frame for the stream's cadence,
/// and cuts one frame when two have stayed queued for `smoothCatchUpFrames` presentations, which
/// only clock drift between host and display causes.
///
/// Cadence: a stream slower than the display (30 fps on 60 Hz) leaves ticks empty by design, and
/// such an empty tick is no stall. refresh / fps is fractional (30 on 50 is 1.67, shown 2-2-1).
/// smooth runs a cadence accumulator: each presented frame is owed refresh / fps refreshes, every
/// tick takes one off, and while a frame is still owed the current one is held and an empty tick
/// neither stalls nor re-primes. lowLatency shows frames as they come, so its holds follow the
/// arrivals, not an accumulator phase; an empty tick is a stall there once the current frame has
/// been up for the longest normal hold, ceil(refresh / fps). A stream at or above the refresh
/// never waits in either mode.
///
/// Direct present (experimental, lowLatency only, needs `directPresent` and a presenter): the
/// renderer shows whatever was enqueued before a vsync at that vsync, so a frame enqueued as soon as
/// it is decoded is shown one refresh earlier than one that waits for the tick after the vsync. The
/// span between two `vsync` calls is one interval, and at most one frame is enqueued per interval:
/// the first arrival of an interval goes to the presenter from `put` (under the pacer's lock, so a
/// tick can never overtake it), a second one waits for the next tick as before. A tick presents a
/// waiting frame only while its interval is still unserved, and it judges stalls on the interval
/// that just ended: served by a present (tick or direct) is no stall, unserved is one under the
/// lowLatency hold rule. A frame the tick presents paid a refresh against a direct present; when
/// that happens `lowLatencyCatchUpTicks` intervals in a row with arrivals away from the tick, the
/// waiting frame is cut so the next arrival presents directly again.
///
/// `Frame` carries no `Sendable` constraint: `CMSampleBufferRef` is `CM_SWIFT_NONSENDABLE` in this
/// SDK, but frames still cross from the decode thread to the vsync tick and must be treated as
/// immutable once put.
public final class FramePacer<Frame>: @unchecked Sendable {
    static var lowLatencyCatchUpTicks: Int { 30 }
    static var smoothCatchUpFrames: Int { 120 }
    static var smoothPrimeFrames: Int { 2 }
    /// Arrivals whose phase decides whether a low latency catch-up is safe.
    static var phaseWindow: Int { 16 }
    /// The closest any of those arrivals may have come to the tick, as a fraction of the interval.
    static var safePhaseDistance: Double { 0.1 }

    public let mode: FramePacingMode
    public var capacity: Int { mode == .smooth ? 3 : 2 }
    /// The stream's frame rate; 0 when unknown, which assumes one frame per refresh.
    public let frameRate: Int

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
    /// When the pacer last ticked: the straddle point arrival phase is measured against.
    private var lastTick = 0.0
    /// smooth: refreshes the current frame is still owed; at or below zero the next one is due.
    private var cadenceDue = 0.0
    /// lowLatency: refreshes since the last presented frame.
    private var ticksSincePresent = Int.max / 2
    private var vsyncDuration = 0.0
    private var vsyncIntervalSum = 0.0
    private var phaseDistances: [Double] = []
    private var phaseDistanceIndex = 0
    /// Direct present: a frame was enqueued in the current interval, and whether the interval that
    /// ended at the last vsync had one.
    private var intervalServed = false
    private var endedIntervalServed = false
    /// Direct present: intervals in a row that enqueued nothing.
    private var idleIntervals = 0

    public let directPresent: Bool
    private var present: ((Frame) -> Void)?

    public init(mode: FramePacingMode = .lowLatency, frameRate: Int = 0, directPresent: Bool = false) {
        self.mode = mode
        self.frameRate = frameRate
        self.directPresent = directPresent
        queue.reserveCapacity(capacity + 1)
        phaseDistances.reserveCapacity(Self.phaseWindow)
    }

    public func setPresenter(_ present: (@Sendable (Frame) -> Void)?) {
        lock.withLock { self.present = present }
    }

    public func put(_ frame: Frame, arrival: Double) {
        lock.withLock {
            record(arrival: arrival)
            if queue.count >= capacity {
                queue.removeFirst()
                counters.overflowDrops += 1
            }
            queue.append(frame)
            if isDirect, !intervalServed, let present {
                present(presentNext(direct: true))
            }
        }
    }

    private func record(arrival: Double) {
        if let last = lastArrival {
            let interval = (arrival - last) * 1000
            intervalCount += 1
            let delta = interval - intervalMean
            intervalMean += delta / Double(intervalCount)
            intervalM2 += delta * (interval - intervalMean)
        }
        lastArrival = arrival
        var distance = 0.5
        if lastTick > 0, vsyncDuration > 0 {
            let phase = (arrival - lastTick) / vsyncDuration
            let fraction = phase - phase.rounded(.down)
            counters.phaseBins[min(9, max(0, Int(fraction * 10)))] += 1
            distance = min(fraction, 1 - fraction)
        }
        recordPhaseDistance(distance)
    }

    /// The refresh this tick belongs to (`timestamp`, `duration`: the vsync interval stat and the
    /// cadence) and when the tick callback actually runs (`tickTime`, defaulting to `timestamp`):
    /// arrival phase is measured against the tick, since that is where a late frame misses.
    public func vsync(timestamp: Double, duration: Double, tickTime: Double? = nil) {
        lock.withLock {
            if lastVsync > 0, timestamp > lastVsync {
                vsyncIntervalSum += (timestamp - lastVsync) * 1000
                counters.vsyncs += 1
            }
            lastVsync = timestamp
            lastTick = tickTime ?? timestamp
            vsyncDuration = duration
            endedIntervalServed = intervalServed
            intervalServed = false
        }
    }

    public func tick() -> Frame? {
        lock.withLock {
            switch mode {
            case .lowLatency: isDirect ? directTick() : lowLatencyTick()
            case .smooth: smoothTick()
            }
        }
    }

    private func lowLatencyTick() -> Frame? {
        if ticksSincePresent < Int.max / 2 { ticksSincePresent += 1 }
        guard !queue.isEmpty else {
            backlogTicks = 0
            return ticksSincePresent < longestNormalHold ? nil : stall()
        }
        ticksSincePresent = 0
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

    /// Direct present is on for this pacer: lowLatency, switched on, and a presenter attached.
    private var isDirect: Bool { mode == .lowLatency && directPresent && present != nil }

    private func directTick() -> Frame? {
        if endedIntervalServed {
            idleIntervals = 0
        } else {
            if idleIntervals < Int.max / 2 { idleIntervals += 1 }
            if idleIntervals >= longestNormalHold { _ = stall() }
        }
        // A frame already went out directly after this vsync: the tick lost the race, not a stall.
        guard !intervalServed else { return nil }
        guard !queue.isEmpty else {
            backlogTicks = 0
            return nil
        }
        // This frame waited through an interval that was already served: one refresh of latency.
        backlogTicks += 1
        if backlogTicks >= Self.lowLatencyCatchUpTicks, arrivalsAreAwayFromTheTick {
            queue.removeFirst()
            counters.catchUpDrops += 1
            backlogTicks = 0
            // Left unserved on purpose: the next arrival in this interval presents directly.
            guard !queue.isEmpty else { return nil }
        }
        return presentNext(direct: false)
    }

    /// Direct present: the oldest waiting frame is enqueued in this interval.
    private func presentNext(direct: Bool) -> Frame {
        intervalServed = true
        let frame = queue.removeFirst()
        if queue.isEmpty {
            if direct { backlogTicks = 0 }
        } else {
            counters.bufferedTicks += 1
            if direct { backlogTicks += 1 }
        }
        counters.presented += 1
        if direct { counters.directPresents += 1 }
        return frame
    }

    private func smoothTick() -> Frame? {
        advanceCadence()
        if primed, withinCadence { return nil }
        if !primed {
            guard queue.count >= Self.smoothPrimeFrames else { return stall() }
            primed = true
        }
        guard !queue.isEmpty else { return stall() }
        presentedOnCadence()
        var frame = queue.removeFirst()
        if queue.count >= 2 {
            backlogTicks += 1
        } else {
            backlogTicks = 0
        }
        if backlogTicks >= Self.smoothCatchUpFrames {
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

    /// Refreshes per stream frame, fractional: 2 for 30 fps on 60 Hz, 1.67 for 30 on 50, 0.83 for
    /// 60 on 50; 1 when either side is unknown.
    private var ticksPerFrame: Double {
        guard frameRate > 0, vsyncDuration > 0 else { return 1 }
        return 1 / (vsyncDuration * Double(frameRate))
    }

    /// The longest a frame stays up in the normal cadence: 1 at 60 on 60, 2 at 30 on 60 and 30 on 50.
    private var longestNormalHold: Int {
        max(1, Int((ticksPerFrame - 1e-6).rounded(.up)))
    }

    /// smooth: one refresh passed. The floor of -1 keeps a stall from building a debt that would let later
    /// frames through faster than the cadence, while the fractional remainder (above -1) carries.
    private func advanceCadence() {
        cadenceDue = max(cadenceDue - 1, -1)
    }

    /// A frame went on screen: it is owed refresh / fps refreshes from now. Only an on-time
    /// remainder in (-1, 0] carries over (that is what makes 30 on 50 come out 2-2-1). A frame shown
    /// early (lowLatency) or after an idle tick at the floor (start, stall) restarts the cadence.
    private func presentedOnCadence() {
        let carry = cadenceDue <= -1 ? 0 : min(cadenceDue, 0)
        cadenceDue = carry + ticksPerFrame
    }

    /// The last frame is still owed refreshes: an empty tick here is the cadence, not a stall.
    private var withinCadence: Bool { cadenceDue > 1e-9 }

    private func recordPhaseDistance(_ distance: Double) {
        if phaseDistances.count < Self.phaseWindow {
            phaseDistances.append(distance)
        } else {
            phaseDistances[phaseDistanceIndex] = distance
        }
        phaseDistanceIndex = (phaseDistanceIndex + 1) % Self.phaseWindow
    }

    /// True when none of the recent arrivals came within `safePhaseDistance` of the tick. Before
    /// any vsync is known every arrival counts as mid-interval (0.5), so this is true.
    private var arrivalsAreAwayFromTheTick: Bool {
        phaseDistances.allSatisfy { $0 >= Self.safePhaseDistance }
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
