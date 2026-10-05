import Foundation
import QuartzCore

public enum FramePacingMode: String, Sendable, CaseIterable {
    case lowLatency, smooth, smoothPlus
}

public struct PacerStats: Sendable, Equatable {
    public var presented = 0
    /// Ticks with nothing to show beyond the stream cadence: the stutter metric. In smoothPlus this
    /// includes priming ticks; in smooth it is a vsync that passed while the next frame was due
    /// and had not arrived.
    public var stalls = 0
    /// A frame arrived while the buffer was full (two frames in lowLatency, ten in smooth, four in
    /// smoothPlus); the oldest was discarded.
    public var overflowDrops = 0
    /// A standing lag was cut by skipping one frame (see FramePacer for when each mode does this;
    /// in smooth also an older due frame left out for a newer one).
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
    /// Extra refresh intervals a vsync callback skipped over (a missed CADisplayLink tick), counted
    /// from the gap between consecutive `vsync` timestamps against the reported duration.
    public var missedTicks = 0
    /// Sum of (shown time - arrival) over every frame actually shown, milliseconds, where the shown
    /// time is the vsync ending the interval the frame was enqueued in (before any vsync is known,
    /// the enqueue itself). Dropped frames (overflow, catch-up) add nothing.
    public var displayWaitTotalMilliseconds: Double = 0
    public var displayWaitSamples = 0
    /// Presented frames that had already arrived before the vsync preceding their enqueue, so they
    /// reached the screen one refresh later than they could have. In smooth and in lowLatency
    /// without direct present that is every presented frame except those that arrived between a
    /// vsync and its tick.
    public var laggingPresents = 0

    public init() {}
}

/// Hand-off between the decoder and the vsync tick. Frames are shown in arrival order, so frames
/// that arrive bunched inside one refresh are shown on consecutive ticks instead of dropped.
///
/// `lowLatency` holds at most two frames and presents the oldest. A one-frame backlog that stands
/// for `lowLatencyCatchUpTicks` ticks is cut, but only when none of the recent arrivals came close
/// to the tick: while they straddle it, cutting the lag leaves the next tick empty (a drop followed
/// by a stall), so the lag is kept until the arrival phase has moved on. With direct present the
/// cut also needs the frames to make their vsync with one frame less of lag: the median display
/// wait of the recent presents minus one interval (`waitAfterCut`) must exceed the routine
/// lateness (the `typicalLateness` quantile) when arrivals stay away from the tick, and the rare
/// lateness (`rareLateness`) otherwise. Lateness is measured against a smoothed arrival clock that
/// steps over lost frames (gaps in the frame numbers) and re-anchors after a pause, so neither
/// counts. A lag that rare lateness would not fit through is the jitter buffer absorbing it.
///
/// `smooth` is an elastic playout schedule: every frame is due at its expected time on the host's
/// cadence (`PlayoutClock`) plus a delay, and is shown at the first vsync it is due for, by a tick
/// or, with direct present, on arrival. The delay starts at the base delay (a high quantile of
/// recent lateness, a few milliseconds at most). A vsync that passes while the next frame is due
/// and missing stretches it one refresh, as does a late frame found due together with the next
/// one, up to `smoothStretch` refreshes beyond the base, so a late frame is shown instead of
/// skipped and the frames behind it follow at the cadence. After `smoothCalm` seconds without a
/// stretch the delay steps back one refresh every `smoothStepDown` seconds, each step skipping one
/// frame. Measured against device traces (2026-10-05) this matches the old one-frame jitter buffer
/// in stutter on a quiet network at less than half its latency.
///
/// `smoothPlus` keeps two frames standing as a jitter buffer: it holds up to four, primes to three
/// before presenting (after the start and after every stall), shows each frame for the stream's
/// cadence, and cuts one frame when three have stayed queued for `smoothPlusCatchUpFrames`
/// presentations, which only clock drift between host and display causes.
///
/// Cadence: a stream slower than the display (30 fps on 60 Hz) leaves ticks empty by design, and
/// such an empty tick is no stall. refresh / fps is fractional (30 on 50 is 1.67, shown 2-2-1).
/// smooth follows the frame period by construction. smoothPlus runs a cadence accumulator: each presented frame is owed refresh / fps refreshes, every
/// tick takes one off, and while a frame is still owed the current one is held and an empty tick
/// neither stalls nor re-primes. lowLatency shows frames as they come, so its holds follow the
/// arrivals, not an accumulator phase; an empty tick is a stall there once the current frame has
/// been up for the longest normal hold, ceil(refresh / fps). A stream at or above the refresh
/// never waits in any mode.
///
/// Direct present (lowLatency and smooth, needs `directPresent` and a presenter; the interval
/// bookkeeping below is shared, the rest of this paragraph is lowLatency's): the
/// renderer shows whatever was enqueued before a vsync at that vsync, so a frame enqueued as soon as
/// it is decoded is shown one refresh earlier than one that waits for the tick after the vsync. The
/// span between two `vsync` calls is one interval, and at most one frame is enqueued per interval:
/// the first arrival of an interval goes to the presenter from `put` (under the pacer's lock, so a
/// tick can never overtake it), a second one waits for the next tick as before. A tick presents a
/// waiting frame only while its interval is still unserved, and it judges stalls on the interval
/// that just ended: served by a present (tick or direct) is no stall, unserved is one under the
/// lowLatency hold rule. A frame the tick presents paid a refresh against a direct present; when
/// that happens `lowLatencyCatchUpTicks` intervals in a row and the catch-up rule above allows it,
/// the waiting frame is cut so the next arrival presents directly again. An interval starts at its
/// vsync, not at the tick that reports it: an arrival after the expected vsync but before its tick
/// opens the new interval itself, since the renderer already counts it there.
///
/// `Frame` carries no `Sendable` constraint: `CMSampleBufferRef` is `CM_SWIFT_NONSENDABLE` in this
/// SDK, but frames still cross from the decode thread to the vsync tick and must be treated as
/// immutable once put.
public final class FramePacer<Frame>: @unchecked Sendable {
    /// Which catch-up rule direct present uses. Only the replay harness changes it, to run a
    /// recorded trace through earlier and candidate rules; the app always uses `.roundTwo`.
    enum CatchUpRule: String, CaseIterable, Sendable {
        /// Before 2026-10-04: the tick-away rule alone, and intervals start at the tick.
        case tickAway
        /// b0433f4: the tick-away rule, or the next expected arrival leaves more slack before its
        /// vsync than the largest lateness of `latenessWindow`; no frame numbers, no pause test.
        case roundOne
        /// Shipped (see the type comment).
        case roundTwo
        /// `roundTwo` with the rare lateness at the 99.9th percentile instead of the 99.95th.
        case roundTwoP999
    }

    /// Set right after init, before any input; never changed by the app.
    var catchUpRule = CatchUpRule.roundTwo

    static var lowLatencyCatchUpTicks: Int { 30 }
    static var smoothPlusCatchUpFrames: Int { 120 }
    static var smoothPlusPrimeFrames: Int { 3 }
    /// smooth: refreshes the delay may stretch beyond the base delay, seconds without a stretch
    /// before it steps back, and seconds between two steps.
    static var smoothStretch: Int { 6 }
    static var smoothCalm: Double { 2 }
    static var smoothStepDown: Double { 0.5 }
    /// Arrivals whose phase decides whether a low latency catch-up is safe.
    static var phaseWindow: Int { 16 }
    /// The closest any of those arrivals may have come to the tick, as a fraction of the interval.
    static var safePhaseDistance: Double { 0.1 }
    /// Lateness is kept as a histogram over this many seconds, in `latenessSlices` slices, with
    /// `latenessBin` second bins up to `latenessBins` of them.
    static var latenessWindow: Double { 120 }
    static var latenessSlices: Int { 6 }
    static var latenessBin: Double { 0.00025 }
    static var latenessBins: Int { 201 }
    /// Quantiles of recent lateness: routine jitter, and the rare outlier a lag has to absorb.
    static var typicalLateness: Double { 0.95 }
    static var rareLateness: Double { 0.9995 }
    /// Slack a frame needs beyond that lateness, seconds.
    static var slackMargin: Double { 0.001 }
    /// A gap of at least this many frame periods followed by regular spacing is a pause.
    static var pauseGap: Double { 2.5 }
    /// The smoothed arrival clock moves 1 / `arrivalSmoothing` of the way to each arrival.
    static var arrivalSmoothing: Double { 16 }
    /// Below this many lateness samples in the window the quantiles say nothing yet (right after
    /// the start, or after a pause longer than the window): the catch-up uses the tick rule alone.
    static var latenessMinimumSamples: Int { 30 }
    /// Presents whose display wait estimates the standing lag.
    static var waitWindow: Int { 16 }
    /// Inter-arrival samples before the arrival estimate is trusted.
    static var arrivalWarmup: Int { 60 }

    public let mode: FramePacingMode
    public var capacity: Int {
        switch mode {
        case .lowLatency: 2
        case .smooth: Self.smoothStretch + 4
        case .smoothPlus: Self.smoothPlusPrimeFrames + 1
        }
    }
    /// The stream's frame rate; 0 when unknown, which assumes one frame per refresh.
    public let frameRate: Int

    private let lock = NSLock()
    private var queue: [Frame] = []
    /// Arrival time of each frame in `queue`, same index, appended and removed alongside it.
    private var arrivals: [Double] = []
    /// smooth: each queued frame's expected time on the host's cadence (`PlayoutClock`), same
    /// index; the arrival itself in the other modes.
    private var expectedTimes: [Double] = []
    private let clock: @Sendable () -> Double
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
    /// smoothPlus: refreshes the current frame is still owed; at or below zero the next one is due.
    private var cadenceDue = 0.0
    /// smooth: the host's cadence, the refreshes the delay is stretched beyond the base, when it
    /// last stretched and stepped back, and the expected time of the last frame presented.
    private var playout = PlayoutClock()
    private var stretch = 0
    private var lastStretch = -Double.infinity
    private var lastStepDown = -Double.infinity
    private var lastPresentedExpected: Double?
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
    /// Direct present: the vsync that starts the interval `intervalServed` belongs to.
    private var intervalStart = 0.0
    /// Smoothed arrival time of the latest frame and that frame's number, if the caller knows it.
    private var smoothedArrival: Double?
    private var lastFrameNumber: Int?
    /// Running mean of the frame period, seconds, leaving out lost frames and pauses.
    private var periodMean = 0.0
    private var periodSamples = 0
    /// The latest frame's lateness, gap since the frame before (frame periods) and arrival: decided
    /// on at the next arrival, since only that shows whether the gap was a pause.
    private var pendingLateness: (lateness: Double, gap: Double, time: Double)?
    /// Lateness against the smoothed arrival clock over `latenessWindow`.
    private var arrivalLateness = LatenessHistogram(window: latenessWindow, slices: latenessSlices, bin: latenessBin,
                                                    bins: latenessBins)
    /// Display waits of the latest presents, seconds.
    private var recentWaits: [Double] = []

    public let directPresent: Bool
    private var present: ((Frame) -> Void)?
    /// Records every input (puts, vsyncs, ticks, presenter changes) for offline replay, if set.
    private var trace: PacerTraceRecorder?

    public init(mode: FramePacingMode = .lowLatency, frameRate: Int = 0, directPresent: Bool = false,
                trace: PacerTraceRecorder? = nil, clock: @escaping @Sendable () -> Double = { CACurrentMediaTime() }) {
        self.trace = trace
        self.mode = mode
        self.frameRate = frameRate
        self.directPresent = directPresent
        self.clock = clock
        queue.reserveCapacity(capacity + 1)
        arrivals.reserveCapacity(capacity + 1)
        expectedTimes.reserveCapacity(capacity + 1)
        phaseDistances.reserveCapacity(Self.phaseWindow)
    }

    public func setPresenter(_ present: (@Sendable (Frame) -> Void)?) {
        lock.withLock {
            self.present = present
            trace?.record(.presenter(attached: present != nil))
        }
    }

    /// Stops recording and completes the trace file; a no-op without one.
    public func finishTrace() {
        let finished: PacerTraceRecorder? = lock.withLock {
            defer { trace = nil }
            return trace
        }
        finished?.close()
    }

    /// `frameNumber` is the stream's number for this frame, when known: a gap means frames were
    /// lost, which then do not count as lateness.
    public func put(_ frame: Frame, arrival: Double, frameNumber: Int? = nil) {
        lock.withLock {
            trace?.record(.put(arrival: arrival, frameNumber: frameNumber))
            record(arrival: arrival, frameNumber: frameNumber)
            var expected = arrival
            if mode == .smooth {
                let playoutTime = playout.expect(arrival: arrival, frameNumber: frameNumber, period: framePeriod)
                expected = playoutTime.time
                if playoutTime.restarted {
                    stretch = 0
                    lastPresentedExpected = nil
                }
            }
            if isDirect, catchUpRule != .tickAway { openIntervalIfVsyncPassed(arrival) }
            if queue.count >= capacity {
                removeOldest()
                counters.overflowDrops += 1
            }
            queue.append(frame)
            arrivals.append(arrival)
            expectedTimes.append(expected)
            assertQueueInSync()
            if isDirect, !intervalServed, let present {
                if mode == .smooth {
                    if let frame = presentDue(direct: true) { present(frame) }
                } else {
                    present(presentNext(direct: true))
                }
            }
        }
    }

    private func assertQueueInSync() {
        assert(queue.count == arrivals.count && queue.count == expectedTimes.count,
               "queue, arrivals and expected times must track each other 1:1")
    }

    @discardableResult
    private func removeOldest() -> (frame: Frame, arrival: Double) {
        expectedTimes.removeFirst()
        return (queue.removeFirst(), arrivals.removeFirst())
    }

    /// Arrival to the vsync that shows the frame: every present (direct or tick) is enqueued inside
    /// the current interval, so that is the vsync ending it, or the first vsync after the arrival
    /// when a late tick callback hands over a frame that came after that vsync (only direct present
    /// opens intervals on arrival). Before any vsync, the enqueue itself.
    private func recordDisplayWait(_ arrival: Double) {
        var shown = clock()
        if intervalStart > 0, vsyncDuration > 0 {
            shown = intervalStart + vsyncDuration
            if arrival >= shown {
                shown += vsyncDuration * (((arrival - shown) / vsyncDuration).rounded(.down) + 1)
            }
        }
        counters.displayWaitTotalMilliseconds += (shown - arrival) * 1000
        counters.displayWaitSamples += 1
        if arrival < intervalStart { counters.laggingPresents += 1 }
        recentWaits.append(shown - arrival)
        if recentWaits.count > Self.waitWindow { recentWaits.removeFirst() }
    }

    /// Direct present: an arrival at or after the vsync that ends the current interval belongs to
    /// the next one even though its tick has not run yet.
    private func openIntervalIfVsyncPassed(_ arrival: Double) {
        guard intervalStart > 0, vsyncDuration > 0, arrival >= intervalStart + vsyncDuration else { return }
        let intervals = ((arrival - intervalStart) / vsyncDuration).rounded(.down)
        endedIntervalServed = intervals == 1 && intervalServed
        intervalServed = false
        intervalStart += intervals * vsyncDuration
    }

    private func record(arrival: Double, frameNumber: Int?) {
        if let last = lastArrival {
            let interval = (arrival - last) * 1000
            intervalCount += 1
            let delta = interval - intervalMean
            intervalMean += delta / Double(intervalCount)
            intervalM2 += delta * (interval - intervalMean)
        }
        recordLateness(arrival, frameNumber: frameNumber)
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
            trace?.record(.vsync(timestamp: timestamp, duration: duration, tickTime: tickTime ?? timestamp))
            // Unless an arrival already opened this interval (see `openIntervalIfVsyncPassed`).
            if timestamp >= intervalStart + vsyncDuration / 2 {
                endedIntervalServed = intervalServed
                intervalServed = false
            }
            // A late callback reports a vsync an arrival may already have moved past.
            intervalStart = max(intervalStart, timestamp)
            if lastVsync > 0, timestamp > lastVsync {
                vsyncIntervalSum += (timestamp - lastVsync) * 1000
                if duration > 0 {
                    let intervals = max(1, Int(((timestamp - lastVsync) / duration).rounded()))
                    counters.vsyncs += intervals
                    counters.missedTicks += intervals - 1
                } else {
                    counters.vsyncs += 1
                }
            }
            lastVsync = timestamp
            lastTick = tickTime ?? timestamp
            vsyncDuration = duration
        }
    }

    public func tick() -> Frame? {
        lock.withLock {
            trace?.record(.tick)
            return switch mode {
            case .lowLatency: isDirect ? directTick() : lowLatencyTick()
            case .smooth: playoutTick()
            case .smoothPlus: smoothPlusTick()
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
        var (frame, frameArrival) = removeOldest()
        if queue.isEmpty {
            backlogTicks = 0
        } else {
            backlogTicks += 1
            if backlogTicks >= Self.lowLatencyCatchUpTicks, arrivalsAreAwayFromTheTick {
                (frame, frameArrival) = removeOldest()
                counters.catchUpDrops += 1
                backlogTicks = 0
            } else {
                counters.bufferedTicks += 1
            }
        }
        assertQueueInSync()
        counters.presented += 1
        recordDisplayWait(frameArrival)
        return frame
    }

    /// Direct present is on for this pacer: lowLatency or smooth, switched on, and a presenter attached.
    private var isDirect: Bool { mode != .smoothPlus && directPresent && present != nil }

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
        if backlogTicks >= Self.lowLatencyCatchUpTicks, catchUpIsClean {
            removeOldest()
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
        let (frame, frameArrival) = removeOldest()
        assertQueueInSync()
        if queue.isEmpty {
            if direct { backlogTicks = 0 }
        } else {
            counters.bufferedTicks += 1
            if direct { backlogTicks += 1 }
        }
        counters.presented += 1
        if direct { counters.directPresents += 1 }
        recordDisplayWait(frameArrival)
        return frame
    }

    private func smoothPlusTick() -> Frame? {
        advanceCadence()
        if primed, withinCadence { return nil }
        if !primed {
            guard queue.count >= Self.smoothPlusPrimeFrames else { return stall() }
            primed = true
        }
        guard !queue.isEmpty else { return stall() }
        presentedOnCadence()
        var (frame, frameArrival) = removeOldest()
        if queue.count >= Self.smoothPlusPrimeFrames {
            backlogTicks += 1
        } else {
            backlogTicks = 0
        }
        if backlogTicks >= Self.smoothPlusCatchUpFrames {
            (frame, frameArrival) = removeOldest()
            counters.catchUpDrops += 1
            backlogTicks = 0
        } else if !queue.isEmpty {
            counters.bufferedTicks += 1
        }
        assertQueueInSync()
        counters.presented += 1
        recordDisplayWait(frameArrival)
        return frame
    }

    /// smooth (see the type comment). Runs after the vsync that opened the current interval;
    /// presents for the vsync that ends it.
    private func playoutTick() -> Frame? {
        guard intervalStart > 0, vsyncDuration > 0 else { return nil }
        let passed = intervalStart
        // The vsync that just passed showed nothing new although the next frame was due there and
        // had not arrived: a stall, and the delay stretches so that frame is shown when it comes.
        if !endedIntervalServed, let presented = lastPresentedExpected,
           presented + framePeriod + playoutDelay <= passed + 1e-9, !arrivals.contains(where: { $0 < passed }) {
            counters.stalls += 1
            if stretch < Self.smoothStretch {
                stretch += 1
                lastStretch = passed
            }
        }
        if stretch > 0, passed - lastStretch > Self.smoothCalm, passed - lastStepDown > Self.smoothStepDown {
            stretch -= 1
            lastStepDown = passed
            // The frame the step makes due early is skipped: the newest due one is shown.
            return intervalServed ? nil : presentDue(direct: false, mayStretch: false)
        }
        guard !intervalServed else { return nil }
        return presentDue(direct: false, mayStretch: stretch < Self.smoothStretch)
    }

    /// smooth: how far behind its expected time a frame is due, seconds.
    private var playoutDelay: Double { playout.baseDelay + Double(stretch) * vsyncDuration }

    /// smooth: presents for the vsync ending the current interval. Of the frames due there, the
    /// newest is shown and the older ones dropped, except when the oldest was already due at the
    /// vsync before (it arrived late) and `mayStretch`: then it is shown and the delay stretches
    /// one refresh, so the frames behind it follow one per refresh. Nil when none is due or the
    /// interval is served. One frame per interval, as in lowLatency: a frame that comes due in an
    /// interval already served waits for the next tick, and the refresh of lag that can stand after
    /// a step back is kept as jitter buffer (replacing the served frame instead was measured on the
    /// device traces: a few milliseconds less latency for five times the judder).
    private func presentDue(direct: Bool, mayStretch: Bool = false) -> Frame? {
        guard intervalStart > 0, vsyncDuration > 0, !intervalServed else { return nil }
        let target = intervalStart + vsyncDuration
        let delay = playoutDelay
        guard let newest = expectedTimes.lastIndex(where: { $0 + delay <= target + 1e-9 }) else { return nil }
        var pick = newest
        if newest > 0, mayStretch, expectedTimes[0] + delay <= intervalStart + 1e-9 {
            pick = 0
            stretch += 1
            lastStretch = target
        }
        for _ in 0..<pick {
            removeOldest()
            counters.catchUpDrops += 1
        }
        intervalServed = true
        lastPresentedExpected = expectedTimes[0]
        let (frame, frameArrival) = removeOldest()
        assertQueueInSync()
        if !queue.isEmpty { counters.bufferedTicks += 1 }
        counters.presented += 1
        if direct { counters.directPresents += 1 }
        recordDisplayWait(frameArrival)
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

    /// smoothPlus: one refresh passed. The floor of -1 keeps a stall from building a debt that would let later
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

    /// Seconds between frames: the measured mean once it has settled, the nominal rate before.
    private var framePeriod: Double {
        if periodSamples <= Self.arrivalWarmup, frameRate > 0 { return 1 / Double(frameRate) }
        return periodSamples > 0 ? periodMean : intervalMean / 1000
    }

    /// Tracks a smoothed arrival clock and, once warmed up, the lateness against it. A frame's
    /// lateness is committed at the next arrival: a gap of `pauseGap` periods or more followed by
    /// regular spacing was a pause, so the clock moves on instead.
    private func recordLateness(_ arrival: Double, frameNumber: Int?) {
        defer { lastFrameNumber = frameNumber }
        guard var anchor = smoothedArrival, let last = lastArrival else {
            smoothedArrival = arrival
            return
        }
        let legacy = catchUpRule == .tickAway || catchUpRule == .roundOne
        if legacy {
            let period = intervalCount <= Self.arrivalWarmup && frameRate > 0 ? 1 / Double(frameRate) : intervalMean / 1000
            let expected = anchor + period
            smoothedArrival = expected + (arrival - expected) / Self.arrivalSmoothing
            if intervalCount > Self.arrivalWarmup { commitLateness(arrival - expected, at: arrival) }
            return
        }
        let period = framePeriod
        var steps = 1.0
        if let frameNumber, let lastFrameNumber, frameNumber > lastFrameNumber {
            steps = Double(frameNumber - lastFrameNumber)
        }
        let gap = (arrival - last) / period
        if gap / steps < Self.pauseGap {
            periodSamples += 1
            periodMean += ((arrival - last) / steps - periodMean) / Double(periodSamples)
        }
        if let pending = pendingLateness {
            if pending.gap >= Self.pauseGap, abs(gap - steps) <= 0.25 * steps {
                // The clock had moved 1 / arrivalSmoothing of that gap already; move it the rest.
                anchor += (pending.gap - 1).rounded() * period * (1 - 1 / Self.arrivalSmoothing)
            } else {
                commitLateness(pending.lateness, at: pending.time)
            }
            pendingLateness = nil
        }
        let expected = anchor + steps * period
        let lateness = arrival - expected
        smoothedArrival = expected + lateness / Self.arrivalSmoothing
        if intervalCount > Self.arrivalWarmup {
            pendingLateness = (lateness, gap - (steps - 1), arrival)
        }
    }

    private func commitLateness(_ value: Double, at time: Double) {
        arrivalLateness.add(value, at: time)
    }

    /// The `typicalLateness` and `rareLateness` quantiles of the lateness in the window, seconds;
    /// nil below `latenessMinimumSamples`.
    private var latenessQuantiles: (typical: Double, rare: Double)? {
        guard arrivalLateness.total >= Self.latenessMinimumSamples else { return nil }
        return (arrivalLateness.quantile(Self.typicalLateness), arrivalLateness.quantile(Self.rareLateness))
    }

    /// Direct present: what a typical frame would have left before its vsync with one frame less
    /// of lag (median display wait of the latest presents minus one interval), seconds.
    private var waitAfterCut: Double? {
        guard recentWaits.count >= Self.waitWindow / 2, vsyncDuration > 0 else { return nil }
        return recentWaits.sorted()[recentWaits.count / 2] - vsyncDuration
    }

    /// Direct present: cutting the standing lag leaves the stream clean (see the type comment).
    private var catchUpIsClean: Bool {
        switch catchUpRule {
        case .tickAway: return arrivalsAreAwayFromTheTick
        case .roundOne: return arrivalsAreAwayFromTheTick || nextArrivalClearsLargestLateness
        case .roundTwo, .roundTwoP999: break
        }
        guard let after = waitAfterCut, let lateness = latenessQuantiles else { return arrivalsAreAwayFromTheTick }
        let rare = catchUpRule == .roundTwoP999 ? arrivalLateness.quantile(0.999) : lateness.rare
        return (arrivalsAreAwayFromTheTick && after > lateness.typical + Self.slackMargin)
            || after > rare + Self.slackMargin
    }

    /// `roundOne`: the next expected arrival leaves more slack before its vsync than the largest
    /// lateness in the window.
    private var nextArrivalClearsLargestLateness: Bool {
        guard let smoothedArrival, intervalCount > Self.arrivalWarmup, vsyncDuration > 0 else { return false }
        let period = intervalMean / 1000
        var slack = (lastVsync + vsyncDuration - (smoothedArrival + period)).truncatingRemainder(dividingBy: vsyncDuration)
        if slack < 0 { slack += vsyncDuration }
        return slack > arrivalLateness.largest + Self.slackMargin
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
