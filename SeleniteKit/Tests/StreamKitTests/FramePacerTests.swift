import Testing
import Foundation
@testable import StreamKit

/// Feeds `arrivals[i]` frames before tick i and records what each tick presents.
private func run(_ arrivals: [Int], mode: FramePacingMode = .lowLatency) -> (shown: [Int?], stats: PacerStats) {
    let pacer = FramePacer<Int>(mode: mode)
    var next = 0
    var shown: [Int?] = []
    for (tick, count) in arrivals.enumerated() {
        for i in 0..<count {
            pacer.put(next, arrival: Double(tick) / 60 + Double(i) * 0.001)
            next += 1
        }
        shown.append(pacer.tick())
    }
    return (shown, pacer.stats)
}

@Test func steadyArrivalCostsNothing() {
    let (shown, stats) = run(Array(repeating: 1, count: 60))
    #expect(shown == (0..<60).map { $0 })
    #expect(stats.stalls == 0 && stats.overflowDrops == 0 && stats.catchUpDrops == 0 && stats.bufferedTicks == 0)
    #expect(stats.presented == 60)
}

@Test func bunchedArrivalLikeM0WiFiShowsEveryFrame() {
    // Two frames in one interval, none in the next: the M0 mailbox stalled every other tick.
    let (shown, stats) = run((0..<30).flatMap { _ in [2, 0] })
    #expect(shown == (0..<60).map { $0 })
    #expect(stats.stalls == 0)
    #expect(stats.overflowDrops == 0 && stats.catchUpDrops == 0)
    #expect(stats.bufferedTicks == 30)
}

@Test func standingLagIsCaughtUpAfterThirtyTicks() {
    // One extra frame up front, then one per tick: the buffer never drains on its own. No vsync
    // is known here, so the arrival phase counts as safe and only the patience rule applies.
    let (shown, stats) = run([2] + Array(repeating: 1, count: 39))
    let drops: Int = stats.catchUpDrops
    let buffered: Int = stats.bufferedTicks
    let skipped: Int? = shown[29]
    let last: Int? = shown.last ?? nil
    #expect(drops == 1)
    #expect(buffered == 29)
    #expect(skipped == 30)   // tick 30 skipped frame 29 and showed the newest
    #expect(last == 40)
}

@Test func burstNeverHoldsMoreThanTwoFrames() {
    let (shown, stats) = run([5, 0, 0])
    #expect(stats.overflowDrops == 3)
    #expect(shown == [3, 4, nil])
    #expect(stats.stalls == 1)
}

@Test func arrivalJitterIsMeasured() {
    let pacer = FramePacer<Int>()
    for (i, t) in [0.0, 0.016, 0.040, 0.050].enumerated() { pacer.put(i, arrival: t) }
    // Intervals 16, 24, 10 ms: sample standard deviation is about 7.02 ms.
    #expect(abs(pacer.stats.jitterMilliseconds - 7.02) < 0.05)
}

// MARK: - Timed simulation

/// One refresh interval at 60 Hz, in milliseconds.
private let vsyncMs = 1000.0 / 60

/// Deterministic noise in -1...1, so a failing run can be replayed.
private struct Noise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// Per-tick record of what the pacer did.
private struct TickRecord {
    var shown: Int?
    var stalls: Int
    var catchUpDrops: Int
    var overflowDrops: Int
    /// Running display wait total (ms) and sample count; filled by `simulateDirect` only.
    var waitTotalMs = 0.0
    var waitSamples = 0
}

/// Drives a pacer the way DisplayPacer does: frames that arrive between two refreshes are put
/// after the earlier vsync was reported, then each refresh reports its vsync and ticks.
/// `arrivals` are milliseconds on the same clock as the vsyncs, which fire every `refreshMs` from
/// `startMs`; stats are cumulative after each tick.
private func simulate(_ mode: FramePacingMode, arrivals: [Double], ticks: Int,
                      startMs: Double = 1000, frameRate: Int = 60, refreshMs: Double = vsyncMs) -> [TickRecord] {
    let pacer = FramePacer<Int>(mode: mode, frameRate: frameRate)
    var next = 0
    var records: [TickRecord] = []
    for tick in 0..<ticks {
        let now = startMs + Double(tick) * refreshMs
        while next < arrivals.count, arrivals[next] < now {
            pacer.put(next, arrival: arrivals[next] / 1000)
            next += 1
        }
        pacer.vsync(timestamp: now / 1000, duration: refreshMs / 1000, tickTime: now / 1000)
        let frame = pacer.tick()
        let stats = pacer.stats
        records.append(TickRecord(shown: frame, stalls: stats.stalls, catchUpDrops: stats.catchUpDrops,
                                  overflowDrops: stats.overflowDrops))
    }
    return records
}

/// Frame n arrives at `phase(n)` of the refresh interval before tick n + 1 (phase 0 is the tick).
private func arrivals(count: Int, startMs: Double = 1000, phase: (Int) -> Double) -> [Double] {
    (0..<count).map { n in startMs + (Double(n) + phase(n)) * vsyncMs }
}

/// An arrival just before or just after the next refresh, side chosen at random.
private func straddle(_ noise: inout Noise) -> Double {
    let side = noise.next() < 0 ? -1.0 : 1.0
    return 1 + side * (0.05 + 0.03 * noise.next())
}

private func increase(_ records: [TickRecord], from start: Int, _ value: (TickRecord) -> Int) -> Int {
    let before = start > 0 ? value(records[start - 1]) : 0
    return value(records[records.count - 1]) - before
}

@Test func lowLatencyMidIntervalWithJitterCostsNothing() {
    var noise = Noise(seed: 1)
    let times = arrivals(count: 700) { _ in 0.5 + 0.25 * noise.next() }
    let records = simulate(.lowLatency, arrivals: times, ticks: 600)
    let stalls: Int = increase(records, from: 1, \.stalls)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    let overflow: Int = increase(records, from: 0, \.overflowDrops)
    #expect(stalls == 0)
    #expect(catchUp == 0)
    #expect(overflow == 0)
}

@Test func lowLatencyKeepsTheLagWhileArrivalsStraddleTheTick() {
    // The device capture: arrivals sit right at the refresh, at random just before (phase 0.95)
    // or just after it (phase 0.05). Runs of early arrivals are what the 3-tick catch-up cut.
    var noise = Noise(seed: 2)
    let times = arrivals(count: 700) { _ in straddle(&noise) }
    let records = simulate(.lowLatency, arrivals: times, ticks: 600)
    let stalls: Int = increase(records, from: 60, \.stalls)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    let overflow: Int = increase(records, from: 0, \.overflowDrops)
    #expect(stalls == 0)
    #expect(catchUp == 0)
    #expect(overflow == 0)
}

@Test func lowLatencyCutsTheLagOnceArrivalsMoveAwayFromTheTick() {
    // Straddling for 300 frames, then the phase drifts to mid-interval over 60 frames and stays.
    var noise = Noise(seed: 3)
    let times = arrivals(count: 1000) { n -> Double in
        let near = straddle(&noise)
        if n < 300 { return near }
        let t = min(1, Double(n - 300) / 60)
        return near * (1 - t) + 0.5 * t
    }
    let records = simulate(.lowLatency, arrivals: times, ticks: 900)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    let stalls: Int = increase(records, from: 60, \.stalls)
    #expect(catchUp == 1)
    #expect(stalls == 0)
}

@Test func lowLatencyBurstStillOverflows() {
    let (shown, stats) = run([3, 0, 0])
    let overflow: Int = stats.overflowDrops
    #expect(overflow == 1)
    #expect(shown == [1, 2, nil])
}

@Test func smoothPlusAbsorbsJitterAtEveryPhase() {
    for (index, phase) in [0.0, 0.1, 0.3, 0.5, 0.7, 0.9].enumerated() {
        var noise = Noise(seed: UInt64(10 + index))
        let times = arrivals(count: 1300) { _ in phase + 0.45 * noise.next() }
        let records = simulate(.smoothPlus, arrivals: times, ticks: 1200)
        // Priming holds the first ticks; count stalls only once the first frame was shown.
        let firstShown = records.firstIndex { $0.shown != nil } ?? 0
        let stalls: Int = increase(records, from: firstShown, \.stalls)
        let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
        let overflow: Int = increase(records, from: 0, \.overflowDrops)
        #expect(stalls == 0, "phase \(phase)")
        #expect(catchUp == 0, "phase \(phase)")
        #expect(overflow == 0, "phase \(phase)")
    }
}

@Test func smoothPlusPrimesBeforeTheFirstFrame() {
    let (shown, stats) = run([1, 1, 1, 1, 1], mode: .smoothPlus)
    let stalls: Int = stats.stalls
    #expect(shown == [nil, nil, 0, 1, 2])
    #expect(stalls == 2)
}

@Test func smoothPlusCutsClockDriftCreepWithIsolatedDrops() {
    // Host clock runs fast: a frame every 16.60 ms against a 16.666 ms refresh.
    var noise = Noise(seed: 4)
    let times = (0..<5000).map { n in 1000 + 8 + Double(n) * 16.60 + 1.5 * noise.next() }
    let records = simulate(.smoothPlus, arrivals: times, ticks: 4800)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let stalls: Int = increase(records, from: firstShown, \.stalls)
    #expect(stalls == 0)
    var dropTicks: [Int] = []
    for (tick, record) in records.enumerated() {
        let previous = tick > 0 ? records[tick - 1].catchUpDrops : 0
        let added: Int = record.catchUpDrops - previous
        #expect(added <= 1)
        if added > 0 { dropTicks.append(tick) }
    }
    let dropCount: Int = dropTicks.count
    #expect(dropCount >= 5)
    for (earlier, later) in zip(dropTicks, dropTicks.dropFirst()) {
        let spacing: Int = later - earlier
        #expect(spacing >= 120)
    }
}

@Test func smoothPlusStallsThroughAGapThenReprimes() {
    // Frames 200, 201 and 202 never arrive.
    let times = arrivals(count: 700) { _ in 0.5 }.enumerated().filter { !(200...202).contains($0.offset) }.map(\.element)
    let records = simulate(.smoothPlus, arrivals: times, ticks: 600)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let before: Int = increase(Array(records[..<195]), from: firstShown, \.stalls)
    let gap: Int = records[215].stalls - records[195].stalls
    let after: Int = increase(records, from: 216, \.stalls)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    #expect(before == 0)
    #expect(gap >= 3)
    #expect(after == 0)
    #expect(catchUp == 0)
}

// MARK: - Review round 1

/// Frame n of a 30 fps stream arrives `offset` refreshes (plus jitter) after tick 2n.
private func arrivals30(count: Int, startMs: Double = 1000, offset: (Int) -> Double) -> [Double] {
    (0..<count).map { n in startMs + (Double(2 * n) + offset(n)) * vsyncMs }
}

@Test func smoothPlusAt30FpsOn60HzHoldsEveryFrameForTwoTicks() {
    var noise = Noise(seed: 20)
    let times = arrivals30(count: 700) { _ in 1 + 0.8 * noise.next() }
    let records = simulate(.smoothPlus, arrivals: times, ticks: 1200, frameRate: 30)
    let shownTicks = records.enumerated().compactMap { $0.element.shown == nil ? nil : $0.offset }
    let firstShown = shownTicks.first ?? 0
    let stalls: Int = increase(records, from: firstShown, \.stalls)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    #expect(stalls == 0)
    #expect(catchUp == 0)
    for (earlier, later) in zip(shownTicks, shownTicks.dropFirst()) {
        let spacing: Int = later - earlier
        #expect(spacing == 2)
    }
}

@Test func smoothPlusAt30FpsReprimesOnlyWhenAFrameIsMissing() {
    // Frames 100 to 102 never arrive: more than the two standing frames can cover (two missing
    // frames are absorbed by them), the rest is on time.
    let times = arrivals30(count: 400) { _ in 1.5 }.enumerated().filter { !(100...102).contains($0.offset) }.map(\.element)
    let records = simulate(.smoothPlus, arrivals: times, ticks: 700, frameRate: 30)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let before: Int = increase(Array(records[..<190]), from: firstShown, \.stalls)
    let gap: Int = records[215].stalls - records[190].stalls
    let after: Int = increase(records, from: 230, \.stalls)
    #expect(before == 0)
    #expect(gap >= 1)
    #expect(after == 0)
}

@Test func lowLatencyAt30FpsOn60HzCountsNoCadenceGapAsAStall() {
    var noise = Noise(seed: 21)
    // Arrivals stay inside one refresh interval (between ticks 2n + 1 and 2n + 2): jitter that
    // straddles a tick holds a frame for three refreshes, which is a real stall.
    let times = arrivals30(count: 700) { _ in 1.5 + 0.4 * noise.next() }
    let records = simulate(.lowLatency, arrivals: times, ticks: 1200, frameRate: 30)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let stalls: Int = increase(records, from: firstShown, \.stalls)
    let shown: Int = records.compactMap(\.shown).count
    #expect(stalls == 0)
    #expect(shown >= 590)
}

@Test func lowLatencyAt30FpsCountsAMissingFrameAsAStall() {
    let times = arrivals30(count: 400) { _ in 1.5 }.enumerated().filter { $0.offset != 100 }.map(\.element)
    let records = simulate(.lowLatency, arrivals: times, ticks: 700, frameRate: 30)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let stalls: Int = increase(records, from: firstShown, \.stalls)
    #expect(stalls >= 1)
    #expect(stalls <= 2)
}

@Test func aMissedTickCountsAsTwoIntervals() {
    let pacer = FramePacer<Int>()
    let duration = 1.0 / 60
    // Starts at 1.0, not 0, so this does not depend on lastVsync's 0.0 initial value.
    pacer.vsync(timestamp: 1.0, duration: duration)
    pacer.vsync(timestamp: 1.0 + 1.0 / 60, duration: duration)
    // The callback for 1.0 + 2/60 never ran: this one reports 1.0 + 3/60, two intervals late.
    pacer.vsync(timestamp: 1.0 + 3.0 / 60, duration: duration)
    pacer.vsync(timestamp: 1.0 + 4.0 / 60, duration: duration)
    let stats = pacer.stats
    #expect(stats.missedTicks == 1)
    #expect(abs(stats.vsyncIntervalMilliseconds - 1000.0 / 60) < 1e-6)
}

@Test func steadyVsyncsMissNothing() {
    let pacer = FramePacer<Int>()
    let duration = 1.0 / 60
    for tick in 0...4 {
        pacer.vsync(timestamp: Double(tick) * duration, duration: duration)
    }
    let stats = pacer.stats
    #expect(stats.missedTicks == 0)
    #expect(abs(stats.vsyncIntervalMilliseconds - 1000.0 / 60) < 1e-6)
}

@Test func arrivalPhaseIsMeasuredAgainstTheTickNotTheRefresh() {
    let pacer = FramePacer<Int>()
    let duration = 1.0 / 60
    // The tick callback runs 8 ms after the refresh it reports.
    pacer.vsync(timestamp: 1.0, duration: duration, tickTime: 1.008)
    pacer.put(0, arrival: 1.008 + 0.25 * duration)
    let bins: [Int] = pacer.stats.phaseBins
    let second: Int = bins[2]
    #expect(second == 1)
}

@Test func lowLatencyKeepsTheLagWhileTheArrivalTailTouchesTheTick() {
    // Mean distance from the tick about 0.25, but with a tail: most frames arrive around phase
    // 0.75, every 8th comes within 0.05 of the tick and every 48th lands just after it. One frame
    // of lag stands from the start. The mean alone clears the old 0.2 gate, so a catch-up would cut
    // the lag and the next late frame would leave its tick empty; the tail criterion keeps the lag.
    var noise = Noise(seed: 22)
    let lag = [1000 - 0.5 * vsyncMs]
    let times = lag + arrivals(count: 6000) { n -> Double in
        if n % 48 == 47 { return 1.03 + 0.01 * noise.next() }
        if n % 8 == 7 { return 0.97 + 0.02 * noise.next() }
        return 0.75 + 0.04 * noise.next()
    }
    let records = simulate(.lowLatency, arrivals: times, ticks: 5500)
    var pairs = 0
    for tick in 1..<(records.count - 1) where records[tick].catchUpDrops > records[tick - 1].catchUpDrops {
        if records[tick + 1].stalls > records[tick].stalls { pairs += 1 }
    }
    let dropStallPairs: Int = pairs
    let stalls: Int = increase(records, from: 60, \.stalls)
    #expect(dropStallPairs == 0)
    #expect(stalls == 0)
}

// MARK: - Review round 2: refresh / fps is not an integer

private let refresh50Ms = 20.0

/// A stream at `fps` whose frames arrive every 1000 / fps ms, `offsetMs` after the first refresh.
private func streamArrivals(count: Int, fps: Double, startMs: Double = 1000, offsetMs: Double,
                            jitter: (Int) -> Double = { _ in 0 }) -> [Double] {
    (0..<count).map { n in startMs + offsetMs + Double(n) * 1000 / fps + jitter(n) }
}

@Test func smoothPlusAt30FpsOn50HzShowsAllThirtyFrames() {
    var noise = Noise(seed: 30)
    let times = streamArrivals(count: 1000, fps: 30, offsetMs: 7) { _ in 4 * noise.next() }
    let records = simulate(.smoothPlus, arrivals: times, ticks: 1500, frameRate: 30, refreshMs: refresh50Ms)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let stalls: Int = increase(records, from: firstShown, \.stalls)
    let overflow: Int = increase(records, from: 0, \.overflowDrops)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    // 1500 ticks at 50 Hz are 30 s: 900 frames arrive, all but the standing ones are shown.
    let shown: Int = records.compactMap(\.shown).count
    #expect(stalls == 0)
    #expect(overflow == 0)
    #expect(catchUp == 0)
    #expect(shown >= 895)
}

@Test func smoothPlusAt30FpsOn50HzHoldsTwoTwoOne() {
    let times = streamArrivals(count: 400, fps: 30, offsetMs: 7)
    let records = simulate(.smoothPlus, arrivals: times, ticks: 500, frameRate: 30, refreshMs: refresh50Ms)
    let shownTicks = records.enumerated().compactMap { $0.element.shown == nil ? nil : $0.offset }
    for (earlier, later) in zip(shownTicks, shownTicks.dropFirst()) {
        let spacing: Int = later - earlier
        #expect(spacing == 1 || spacing == 2)
    }
    let span: Int = shownTicks[shownTicks.count - 1] - shownTicks[0]
    let frames: Int = shownTicks.count - 1
    // 5 refreshes per 3 frames on average.
    #expect(abs(span * 3 - frames * 5) <= 5)
}

@Test func lowLatencyAt30FpsOn50HzCountsNoCadenceGapAsAStall() {
    var noise = Noise(seed: 31)
    let times = streamArrivals(count: 1000, fps: 30, offsetMs: 7) { _ in 2 * noise.next() }
    let records = simulate(.lowLatency, arrivals: times, ticks: 1500, frameRate: 30, refreshMs: refresh50Ms)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let stalls: Int = increase(records, from: firstShown, \.stalls)
    let shown: Int = records.compactMap(\.shown).count
    #expect(stalls == 0)
    #expect(shown >= 895)
}

@Test func smoothPlusAt60FpsOn50HzNeverWaits() {
    // More frames than refreshes: every tick after priming shows one, the surplus overflows.
    let times = streamArrivals(count: 700, fps: 60, offsetMs: 3)
    let records = simulate(.smoothPlus, arrivals: times, ticks: 500, frameRate: 60, refreshMs: refresh50Ms)
    let firstShown = records.firstIndex { $0.shown != nil } ?? 0
    let empty: Int = records[firstShown...].filter { $0.shown == nil }.count
    #expect(empty == 0)
}

// MARK: - Direct present on arrival (experimental, lowLatency only)

/// Collects what the pacer hands the renderer directly, from whichever thread puts.
private final class PresentSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int] = []
    var presented: [Int] { lock.withLock { frames } }
    func present(_ frame: Int) { lock.withLock { frames.append(frame) } }
}

private func directPacer(mode: FramePacingMode = .lowLatency, frameRate: Int = 60,
                         directPresent: Bool = true) -> (FramePacer<Int>, PresentSink) {
    let pacer = FramePacer<Int>(mode: mode, frameRate: frameRate, directPresent: directPresent)
    let sink = PresentSink()
    pacer.setPresenter { sink.present($0) }
    return (pacer, sink)
}

/// `simulate` with a present sink attached: records what each tick returns, stats after each tick,
/// and the order of every frame that reached the renderer (direct or tick).
private func simulateDirect(_ mode: FramePacingMode = .lowLatency, directPresent: Bool = true, arrivals: [Double],
                            numbers: [Int]? = nil, ticks: Int, startMs: Double = 1000, frameRate: Int = 60,
                            refreshMs: Double = vsyncMs) -> (records: [TickRecord], rendered: [Int], stats: PacerStats) {
    let pacer = FramePacer<Int>(mode: mode, frameRate: frameRate, directPresent: directPresent)
    let sink = PresentSink()
    pacer.setPresenter { sink.present($0) }
    var next = 0
    var records: [TickRecord] = []
    for tick in 0..<ticks {
        let now = startMs + Double(tick) * refreshMs
        while next < arrivals.count, arrivals[next] < now {
            pacer.put(next, arrival: arrivals[next] / 1000, frameNumber: numbers?[next])
            next += 1
        }
        pacer.vsync(timestamp: now / 1000, duration: refreshMs / 1000, tickTime: now / 1000)
        let frame = pacer.tick()
        if let frame { sink.present(frame) }
        let stats = pacer.stats
        records.append(TickRecord(shown: frame, stalls: stats.stalls, catchUpDrops: stats.catchUpDrops,
                                  overflowDrops: stats.overflowDrops, waitTotalMs: stats.displayWaitTotalMilliseconds,
                                  waitSamples: stats.displayWaitSamples))
    }
    return (records, sink.presented, pacer.stats)
}

@Test func directPresentShowsMidIntervalFramesOnArrival() {
    var noise = Noise(seed: 40)
    let times = arrivals(count: 700) { _ in 0.5 + 0.2 * noise.next() }
    let (records, rendered, stats) = simulateDirect(arrivals: times, ticks: 600)
    let stalls: Int = increase(records, from: 1, \.stalls)
    let tickShown: Int = records.compactMap(\.shown).count
    let direct: Int = stats.directPresents
    let presented: Int = stats.presented
    let inOrder: Bool = rendered == rendered.sorted()
    #expect(stalls == 0)
    #expect(tickShown == 0)
    #expect(direct == presented)
    #expect(direct >= 598)
    #expect(inOrder)
}

@Test func directPresentSendsTheSecondFrameOfAnIntervalToTheNextTick() {
    let (pacer, sink) = directPacer()
    let d = 1.0 / 60
    pacer.vsync(timestamp: 1.0, duration: d)
    _ = pacer.tick()
    let stallsBefore: Int = pacer.stats.stalls
    pacer.put(0, arrival: 1.0 + 0.4 * d)
    pacer.put(1, arrival: 1.0 + 0.6 * d)
    let directAfterPut: [Int] = sink.presented
    #expect(directAfterPut == [0])
    pacer.vsync(timestamp: 1.0 + d, duration: d)
    let second: Int? = pacer.tick()
    #expect(second == 1)
    // Nothing arrives in the interval the tick served; the next tick is no stall.
    pacer.vsync(timestamp: 1.0 + 2 * d, duration: d)
    let empty: Int? = pacer.tick()
    #expect(empty == nil)
    let stalls: Int = pacer.stats.stalls - stallsBefore
    let direct: Int = pacer.stats.directPresents
    let presented: Int = pacer.stats.presented
    #expect(stalls == 0)
    #expect(direct == 1)
    #expect(presented == 2)
}

@Test func directPresentResumesInTheIntervalAfterAServedOne() {
    let (pacer, sink) = directPacer()
    let d = 1.0 / 60
    pacer.vsync(timestamp: 1.0, duration: d)
    _ = pacer.tick()
    pacer.put(0, arrival: 1.0 + 0.5 * d)
    pacer.vsync(timestamp: 1.0 + d, duration: d)
    let tick1: Int? = pacer.tick()
    pacer.put(1, arrival: 1.0 + 1.5 * d)
    pacer.vsync(timestamp: 1.0 + 2 * d, duration: d)
    let tick2: Int? = pacer.tick()
    let rendered: [Int] = sink.presented
    let stalls: Int = pacer.stats.stalls
    #expect(tick1 == nil)
    #expect(tick2 == nil)
    #expect(rendered == [0, 1])
    // Only the very first tick, before any frame, counts as a stall.
    #expect(stalls == 1)
}

@Test func aDirectPresentBetweenVsyncAndTickKeepsArrivalOrder() {
    let (pacer, sink) = directPacer()
    let d = 1.0 / 60
    pacer.vsync(timestamp: 1.0, duration: d)
    _ = pacer.tick()
    pacer.put(0, arrival: 1.0 + 0.3 * d)
    pacer.put(1, arrival: 1.0 + 0.6 * d)
    // The decode thread wins the race against the tick that follows this vsync.
    pacer.vsync(timestamp: 1.0 + d, duration: d)
    pacer.put(2, arrival: 1.0 + d + 0.001)
    let tick: Int? = pacer.tick()
    let rendered: [Int] = sink.presented
    #expect(tick == nil)
    #expect(rendered == [0, 1])
    pacer.vsync(timestamp: 1.0 + 2 * d, duration: d)
    let next: Int? = pacer.tick()
    #expect(next == 2)
}

@Test func directPresentCutsTheLagABurstLeavesBehind() {
    // Two frames in the interval before the first tick (the first goes out directly, the second
    // waits), then one per interval mid-interval: without a cut every frame would go out on the
    // tick (one refresh late) for the rest of the stream.
    let times = [1000 - 0.6 * vsyncMs, 1000 - 0.4 * vsyncMs] + arrivals(count: 700) { _ in 0.5 }
    let (records, rendered, _) = simulateDirect(arrivals: times, ticks: 600)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    let stalls: Int = increase(records, from: 1, \.stalls)
    let lateTickShown: Int = records[100...].compactMap(\.shown).count
    let inOrder: Bool = rendered == rendered.sorted()
    #expect(catchUp == 1)
    #expect(stalls == 0)
    #expect(lateTickShown == 0)
    #expect(inOrder)
}

@Test func directPresentAt30FpsOn60HzCountsNoCadenceGapAsAStall() {
    var noise = Noise(seed: 41)
    let times = arrivals30(count: 700) { _ in 1.5 + 0.3 * noise.next() }
    let (records, rendered, stats) = simulateDirect(arrivals: times, ticks: 1200, frameRate: 30)
    let stalls: Int = increase(records, from: 3, \.stalls)
    let direct: Int = stats.directPresents
    #expect(stalls == 0)
    #expect(direct >= 595)
    #expect(rendered.count >= 595)
}

@Test func directPresentOffLeavesThePacerAsToday() {
    var noise = Noise(seed: 42)
    let times = arrivals(count: 700) { _ in 0.5 + 0.25 * noise.next() }
    let (records, rendered, stats) = simulateDirect(directPresent: false, arrivals: times, ticks: 600)
    let reference = simulate(.lowLatency, arrivals: times, ticks: 600)
    let shown: [Int?] = records.map(\.shown)
    let expected: [Int?] = reference.map(\.shown)
    let direct: Int = stats.directPresents
    let renderedCount: Int = rendered.count
    let tickCount: Int = shown.compactMap { $0 }.count
    #expect(shown == expected)
    #expect(direct == 0)
    #expect(renderedCount == tickCount)
}

@Test func smoothPlusIgnoresDirectPresent() {
    var noise = Noise(seed: 43)
    let times = arrivals(count: 700) { _ in 0.5 + 0.25 * noise.next() }
    let (records, _, stats) = simulateDirect(.smoothPlus, arrivals: times, ticks: 600)
    let reference = simulate(.smoothPlus, arrivals: times, ticks: 600)
    let shown: [Int?] = records.map(\.shown)
    let expected: [Int?] = reference.map(\.shown)
    let direct: Int = stats.directPresents
    #expect(shown == expected)
    #expect(direct == 0)
}

@Test func directPresentNeedsAPresenter() {
    // Switch on but nothing attached (a pacer the harness never shows): frames wait for the tick.
    let pacer = FramePacer<Int>(mode: .lowLatency, frameRate: 60, directPresent: true)
    let d = 1.0 / 60
    pacer.vsync(timestamp: 1.0, duration: d)
    _ = pacer.tick()
    pacer.put(0, arrival: 1.0 + 0.5 * d)
    pacer.vsync(timestamp: 1.0 + d, duration: d)
    let shown: Int? = pacer.tick()
    let direct: Int = pacer.stats.directPresents
    #expect(shown == 0)
    #expect(direct == 0)
}

// MARK: - Display wait

private final class ManualClock: @unchecked Sendable {
    var now = 0.0
}

@Test func displayWaitWithoutAVsyncRunsToTheEnqueue() {
    let clock = ManualClock()
    let pacer = FramePacer<Int>(mode: .lowLatency, clock: { clock.now })
    pacer.put(1, arrival: 1.000)
    clock.now = 1.004
    #expect(pacer.tick() == 1)
    pacer.put(2, arrival: 1.010)
    clock.now = 1.020
    #expect(pacer.tick() == 2)
    let stats = pacer.stats
    #expect(stats.displayWaitSamples == 2)
    #expect(abs(stats.displayWaitTotalMilliseconds - 14) < 1e-6)
}

@Test func displayWaitOfATickPresentRunsToTheNextVsync() {
    let clock = ManualClock()
    let pacer = FramePacer<Int>(mode: .lowLatency, clock: { clock.now })
    let d = 1.0 / 60
    clock.now = 0.995
    pacer.put(1, arrival: 0.995)
    clock.now = 1.001
    pacer.vsync(timestamp: 1.0, duration: d, tickTime: 1.001)
    #expect(pacer.tick() == 1)
    // Enqueued by the tick after the vsync at 1.0: shown at 1.0 + d, not at the enqueue.
    let wait: Double = pacer.stats.displayWaitTotalMilliseconds
    #expect(abs(wait - (1.0 + d - 0.995) * 1000) < 1e-6)
}

@Test func aLateTickCallbackNeverGivesANegativeDisplayWait() {
    let clock = ManualClock()
    let pacer = FramePacer<Int>(mode: .lowLatency, clock: { clock.now })
    let d = 1.0 / 60
    // The callback for the vsync at 1.0 runs after the next vsync (1.0 + d) and finds a frame that
    // arrived after that one too: the vsync showing it is 1.0 + 2d.
    let arrival = 1.0 + 1.1 * d
    clock.now = arrival
    pacer.put(1, arrival: arrival)
    clock.now = 1.0 + 1.2 * d
    pacer.vsync(timestamp: 1.0, duration: d, tickTime: clock.now)
    #expect(pacer.tick() == 1)
    let wait: Double = pacer.stats.displayWaitTotalMilliseconds
    #expect(abs(wait - (1.0 + 2 * d - arrival) * 1000) < 1e-6)
}

@Test func droppedFramesAddNoDisplayWait() {
    let clock = ManualClock()
    let pacer = FramePacer<Int>(mode: .lowLatency, clock: { clock.now })
    pacer.put(1, arrival: 0)
    pacer.put(2, arrival: 0)
    pacer.put(3, arrival: 0)
    clock.now = 0.002
    #expect(pacer.tick() == 2)
    #expect(pacer.stats.overflowDrops == 1)
    #expect(pacer.stats.displayWaitSamples == 1)
}

@Test func directPresentRecordsDisplayWait() {
    let clock = ManualClock()
    let pacer = FramePacer<Int>(mode: .lowLatency, frameRate: 60, directPresent: true, clock: { clock.now })
    let sink = PresentSink()
    pacer.setPresenter { sink.present($0) }
    let d = 1.0 / 60
    // The first vsync plus tick is the warmup every direct-present test starts from: it leaves
    // intervalServed false and primes vsyncDuration so the next put presents directly.
    pacer.vsync(timestamp: 1.0, duration: d)
    _ = pacer.tick()
    let arrival = 1.0 + 0.4 * d
    clock.now = arrival + 0.001
    pacer.put(0, arrival: arrival)
    #expect(sink.presented == [0])
    let stats = pacer.stats
    // Display wait runs to the vsync that shows the frame (the first after its enqueue, here
    // 1 + d), not to the enqueue 1 ms after arrival.
    #expect(stats.displayWaitSamples == 1)
    #expect(abs(stats.displayWaitTotalMilliseconds - 0.6 * d * 1000) < 1e-6)
}

@Test func catchUpDropsAddNoDisplayWait() {
    let (_, stats) = run([2] + Array(repeating: 1, count: 39))
    #expect(stats.catchUpDrops == 1)
    #expect(stats.displayWaitSamples == stats.presented)
}

// MARK: - Catch-up near the tick (direct present)

@Test func directPresentDoesNotStayAFrameBehindNearTheTick() {
    // A lag stands from the start and arrivals sit 1 ms after the tick: the old rule kept it for
    // the whole stream, since every arrival came within 0.1 of the interval of the tick.
    var noise = Noise(seed: 44)
    let times = [1000 - 0.6 * vsyncMs, 1000 - 0.4 * vsyncMs]
        + arrivals(count: 3700) { _ in 1 / vsyncMs + 0.3 / vsyncMs * noise.next() }
    let (records, rendered, stats) = simulateDirect(arrivals: times, ticks: 3600)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    let stalls: Int = increase(records, from: 1, \.stalls)
    let lateTickShown: Int = records[120...].compactMap(\.shown).count
    let inOrder: Bool = rendered == rendered.sorted()
    let lagging: Int = stats.laggingPresents
    #expect(catchUp == 1)
    #expect(stalls == 0)
    #expect(lateTickShown == 0)
    #expect(inOrder)
    #expect(lagging < 120)
}

@Test func directPresentKeepsTheLagNearTheTickWhileLateFramesRecur() {
    // Same stream, but from frame 300 every 120th frame arrives 18 ms late. The first misses its
    // interval (one stall) and leaves a lag. Cutting it would leave 15.7 ms of slack, less than a
    // lateness that recurs this often (0.8 % of frames), so the lag stands and absorbs the rest.
    var noise = Noise(seed: 45)
    let times = [1000 - 0.6 * vsyncMs, 1000 - 0.4 * vsyncMs]
        + arrivals(count: 3700) { n in
            let late = n >= 300 && n % 120 == 60 ? 18 / vsyncMs : 0
            return 1 / vsyncMs + 0.3 / vsyncMs * noise.next() + late
        }
    let (records, _, _) = simulateDirect(arrivals: times, ticks: 3600)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    let stalls: Int = increase(records, from: 1, \.stalls)
    let tickShownAtTheEnd: Int = records[3400...].compactMap(\.shown).count
    #expect(catchUp == 1)
    #expect(stalls == 1)
    // Each late frame finds the queue empty at one tick and the lag forms again behind it.
    #expect(tickShownAtTheEnd >= 195)
}

/// Arrivals 1 ms after the tick with a startup lag; frame 600 arrives 18 ms late (a stall and a new
/// lag), plus five single frames lost between 300 and 340 (`lose`) or a pause of three periods
/// before frame 300 (`pause`). Returns how many ticks from 90 to 100 s still presented a frame
/// (the losses leave the 120 s lateness window only after that).
private func lagAfterOneLateFrame(seed: UInt64, lose: Bool = false, pause: Bool = false,
                                  passNumbers: Bool = true) -> (tickShownAtTheEnd: Int, catchUp: Int) {
    var noise = Noise(seed: seed)
    var times = [1000 - 0.6 * vsyncMs, 1000 - 0.4 * vsyncMs]
        + arrivals(count: 7300) { n in 1 / vsyncMs + 0.3 / vsyncMs * noise.next() + (n == 600 ? 18 / vsyncMs : 0) }
    var numbers = Array(0..<times.count)
    if lose {
        for index in [334, 326, 318, 310, 302] {
            times.remove(at: index)
            numbers.remove(at: index)
        }
    }
    if pause {
        times = times.enumerated().map { $0.offset >= 302 ? $0.element + 3 * vsyncMs : $0.element }
        times.removeSubrange(302...304)
        numbers = Array(0..<times.count)
    }
    let (records, _, _) = simulateDirect(arrivals: times, numbers: passNumbers ? numbers : nil, ticks: 7200)
    let catchUp: Int = increase(records, from: 0, \.catchUpDrops)
    return (records[5400..<6000].compactMap(\.shown).count, catchUp)
}

@Test func theLatenessGateWaitsForEnoughSamples() {
    // A startup lag 1 ms after the tick: lateness is measured from the 61st interval on and
    // decided a frame later, so the near-tick cut cannot come before the histogram holds
    // `latenessMinimumSamples` of them (an empty one used to read as no lateness at all).
    var noise = Noise(seed: 50)
    let times = [1000 - 0.6 * vsyncMs, 1000 - 0.4 * vsyncMs]
        + arrivals(count: 700) { _ in 1 / vsyncMs + 0.3 / vsyncMs * noise.next() }
    let (records, _, _) = simulateDirect(arrivals: times, ticks: 600)
    let firstCut = records.firstIndex { $0.catchUpDrops > 0 } ?? -1
    #expect(firstCut >= 60 + FramePacer<Int>.latenessMinimumSamples)
    #expect(firstCut < 120)
}

@Test func aSingleLateFrameNoLongerHoldsTheLagForMinutes() {
    let result = lagAfterOneLateFrame(seed: 47)
    #expect(result.catchUp == 2)
    #expect(result.tickShownAtTheEnd == 0)
}

@Test func lostFramesDoNotCountAsLateness() {
    // With frame numbers each lost frame is a gap, not lateness. Without them each looks like a
    // frame one period late, five of them are too common to ignore, and the lag stays.
    let known = lagAfterOneLateFrame(seed: 48, lose: true)
    let unknown = lagAfterOneLateFrame(seed: 48, lose: true, passNumbers: false)
    #expect(known.tickShownAtTheEnd == 0)
    #expect(unknown.tickShownAtTheEnd == 600)
}

@Test func aPauseDoesNotCountAsLateness() {
    // Nothing new to send for a few frames: the frame numbers run on without a gap, the stream
    // resumes at its old spacing, and the arrival clock moves on instead of counting lateness.
    let result = lagAfterOneLateFrame(seed: 49, pause: true)
    #expect(result.tickShownAtTheEnd == 0)
}

@Test func anArrivalAfterTheVsyncOpensTheNextIntervalBeforeItsTick() {
    let (pacer, sink) = directPacer()
    let d = 1.0 / 60
    pacer.vsync(timestamp: 1.0, duration: d, tickTime: 1.001)
    _ = pacer.tick()
    pacer.put(0, arrival: 1.0 + 0.5 * d)
    // After the vsync at 1 + d, before the tick that reports it: the renderer counts this frame
    // for the next refresh, so it goes out directly instead of waiting for that tick.
    pacer.put(1, arrival: 1.0 + d + 0.0005)
    let direct: [Int] = sink.presented
    #expect(direct == [0, 1])
    pacer.vsync(timestamp: 1.0 + d, duration: d, tickTime: 1.0 + d + 0.001)
    let tick: Int? = pacer.tick()
    #expect(tick == nil)
    // The interval the early arrival opened is served: the next frame waits for the next tick.
    pacer.put(2, arrival: 1.0 + 1.5 * d)
    #expect(sink.presented == [0, 1])
    pacer.vsync(timestamp: 1.0 + 2 * d, duration: d, tickTime: 1.0 + 2 * d + 0.001)
    let next: Int? = pacer.tick()
    let stalls: Int = pacer.stats.stalls
    #expect(next == 2)
    #expect(stalls == 1)
}

@Test func aLateVsyncCallbackNeverPresentsTwoFramesForOneVsync() {
    let (pacer, sink) = directPacer()
    let d = 1.0 / 60
    pacer.vsync(timestamp: 1.0, duration: d, tickTime: 1.001)
    _ = pacer.tick()
    pacer.put(0, arrival: 1.0 + 0.5 * d)
    // The callbacks for 1 + d and 1 + 2d run late: an arrival after 1 + 2d opens that interval
    // first, then the callback for 1 + d reports the older vsync.
    pacer.put(1, arrival: 1.0 + 2 * d + 0.001)
    pacer.vsync(timestamp: 1.0 + d, duration: d, tickTime: 1.0 + 2 * d + 0.002)
    let tick: Int? = pacer.tick()
    // Same display interval as frame 1: it waits instead of going out directly.
    pacer.put(2, arrival: 1.0 + 2 * d + 0.003)
    let rendered: [Int] = sink.presented
    #expect(tick == nil)
    #expect(rendered == [0, 1])
    pacer.vsync(timestamp: 1.0 + 3 * d, duration: d, tickTime: 1.0 + 3 * d + 0.001)
    let next: Int? = pacer.tick()
    #expect(next == 2)
}

@Test func laggingPresentsCountFramesThatWaitedThroughAVsync() {
    var noise = Noise(seed: 46)
    let times = arrivals(count: 700) { _ in 0.5 + 0.2 * noise.next() }
    let direct = simulateDirect(arrivals: times, ticks: 600).stats
    let tickOnly = simulateDirect(directPresent: false, arrivals: times, ticks: 600).stats
    let directLagging: Int = direct.laggingPresents
    let tickLagging: Int = tickOnly.laggingPresents
    let tickPresented: Int = tickOnly.presented
    #expect(directLagging == 0)
    #expect(tickLagging == tickPresented)
}

// MARK: - Simulator regression (PacerSimulator, 2 minutes per scenario, seeds 1 to 3)

/// Hitches (repeats + drops) per scenario summed over seeds 1 to 3, measured with the rule this
/// replaced (catch-up only when 16 arrivals in a row stayed 0.1 of an interval from the tick,
/// interval boundary at the tick). One hitch of slack: in the near-tick burst runs both rules keep
/// the lag almost throughout and absorb the bursts, so the counts are a handful of single events
/// that can land one either way (tick+1ms burst is 5 against 4 here).
private let previousRuleHitches: [String: Int] = [
    "mid 2ms": 0, "mid burst": 80, "tick-1ms 2ms": 0, "tick-1ms burst": 3, "tick 2ms": 0, "tick burst": 3,
    "tick+1ms 2ms": 0, "tick+1ms burst": 4, "drift 60.05 2ms": 74, "drift 60.05 burst": 114,
    "drift 59.95 2ms": 160, "drift 59.95 burst": 260,
]

@Test func lowLatencyHitchesDoNotIncreaseOverThePreviousRule() {
    for scenario in PacerSimulator.scenarios(seconds: 120) {
        var hitches = 0
        for seed in UInt64(1)...3 {
            var seeded = scenario
            seeded.seed = seed
            let result = PacerSimulator.run(seeded, mode: .lowLatency)
            hitches += result.repeats + result.drops
        }
        let previous = previousRuleHitches[scenario.name] ?? -1
        #expect(hitches <= previous + 1, "\(scenario.name): \(hitches) hitches, previous rule \(previous)")
    }
}

@Test func lowLatencyNearTheTickNoLongerLocksAFrameBehind() {
    // Seeds 3, 5 and 8 are the ones where the previous rule kept the startup lag for the whole
    // minute (31 to 32 ms mean latency, every frame a refresh late).
    for seed: UInt64 in [3, 5, 8] {
        for (name, phase) in [("tick", 0.0), ("tick+1ms", 1 / vsyncMs)] {
            let scenario = PacerScenario(name: name, phase: phase, seconds: 60, seed: seed)
            let result = PacerSimulator.run(scenario, mode: .lowLatency)
            #expect(result.meanLatencyMs < 17, "\(name) seed \(seed): \(result.meanLatencyMs) ms")
            #expect(result.laggingShare < 0.3, "\(name) seed \(seed): \(result.laggingShare)")
            #expect(result.repeats + result.drops == 0, "\(name) seed \(seed)")
        }
    }
}

// MARK: - Wi-Fi repeater profile (PacerSimulator.repeaterScenarios, 2 minutes, seeds 1 to 3)

/// Hitches per repeater scenario summed over seeds 1 to 3 with the rule this replaced (largest
/// lateness over 120 s as the only gate, frame gaps counted as lateness, no check of the slack the
/// tick-away rule leaves). Two hitches of slack: the tick-1ms runs differ by two events in six
/// simulated minutes. The one scenario family where round two is knowingly worse is not in this
/// table but in `wiredException` below.
private let roundOneHitches: [String: Int] = [
    "dyn mid": 134, "dyn tick-1ms": 47, "dyn tick": 64, "dyn tick+1ms": 66, "dyn tick+3ms": 74,
    "dyn drift 60.02": 119, "static mid": 162, "static tick-1ms": 70, "static tick": 86,
    "static tick+1ms": 90, "static tick+3ms": 100, "static drift 60.01": 189,
]

@Test func repeaterHitchesDoNotIncreaseOverTheRoundOneRule() {
    for scenario in PacerSimulator.repeaterScenarios(seconds: 120) {
        var hitches = 0
        for seed in UInt64(1)...3 {
            var seeded = scenario
            seeded.seed = seed
            let result = PacerSimulator.run(seeded, mode: .lowLatency)
            hitches += result.repeats + result.drops
        }
        let previous = roundOneHitches[scenario.name] ?? -1
        #expect(hitches <= previous + 2, "\(scenario.name): \(hitches) hitches, round one \(previous)")
    }
}

/// The stated exception to "no more hitches than round one" (owner ruling: lowLatency takes the
/// latency). A clean wired stream just before the tick with rare 8 to 30 ms outliers, 10 minutes
/// per seed, seeds 1 to 3: round one held the lag after the first outlier for good (hitches
/// summed over the seeds, mean latency), round two cuts it again once the outliers are rare enough
/// to ignore and pays a repeat plus a drop per outlier instead.
private let wiredException: [String: (roundOneHitches: Int, roundOneLatency: Double, acceptedHitches: Int)] = [
    "wired tick-3ms": (12, 28.3, 60),
    "wired tick-2ms": (10, 27.3, 60),
]

@Test func wiredNearTheTickTradesRareHitchesForLatency() {
    for scenario in PacerSimulator.wiredScenarios(seconds: 600) {
        guard let exception = wiredException[scenario.name] else { continue }
        var hitches = 0
        var latency = 0.0
        for seed in UInt64(1)...3 {
            var seeded = scenario
            seeded.seed = seed
            let result = PacerSimulator.run(seeded, mode: .lowLatency)
            hitches += result.repeats + result.drops
            latency += result.meanLatencyMs / 3
        }
        // Accepted: at most 2 hitches per minute (round one: 0.3 to 0.4) for 10 ms less latency.
        #expect(hitches <= exception.acceptedHitches, "\(scenario.name): \(hitches), round one \(exception.roundOneHitches)")
        #expect(latency < exception.roundOneLatency - 8, "\(scenario.name): \(latency) ms")
    }
}

@Test func aStreamArrivingAroundTheVsyncStandsOneFrameBehindWithoutCutting() {
    // Arrivals about 3 ms before the vsync with a 2 to 10 ms host tail: a quarter of them land
    // after it, so a frame of lag is what keeps the stream clean. The tick-away rule used to cut it
    // anyway (134 hitches in six minutes); holding a second frame instead would add 16.7 ms.
    for name in ["dyn mid", "static mid"] {
        var hitches = 0
        var latency = 0.0
        for seed in UInt64(1)...3 {
            var scenario = PacerSimulator.repeaterScenarios(seconds: 120).first { $0.name == name }!
            scenario.seed = seed
            let result = PacerSimulator.run(scenario, mode: .lowLatency)
            hitches += result.repeats + result.drops
            latency += result.meanLatencyMs / 3
        }
        #expect(latency < 21.5, "\(name): \(latency) ms")
        #expect(hitches <= (name == "dyn mid" ? 40 : 75), "\(name): \(hitches)")
    }
}

@Test func displayWaitAndLaggingMatchWhatTheSimulatedScreenShows() {
    var scenario = PacerSimulator.repeaterScenarios(seconds: 60).first { $0.name == "dyn drift 60.02" }!
    scenario.seed = 2
    let result = PacerSimulator.run(scenario, mode: .lowLatency)
    #expect(abs(result.displayWaitMs - result.meanLatencyMs) < 0.2)
    #expect(abs(result.laggingStatPercent - result.laggingShare * 100) < 1)
}

// MARK: - Smooth: elastic playout

private enum PlayoutClockCap { static let ms = PlayoutClock.baseCap * 1000 }

/// Mean display wait of the frames presented in ticks `range`, milliseconds.
private func meanWait(_ records: [TickRecord], _ range: Range<Int>) -> Double {
    let first = records[range.lowerBound - 1], last = records[range.upperBound - 1]
    let samples = last.waitSamples - first.waitSamples
    return samples > 0 ? (last.waitTotalMs - first.waitTotalMs) / Double(samples) : 0
}

@Test func smoothShowsEveryFrameOfACleanStreamWithinARefresh() {
    var noise = Noise(seed: 50)
    let times = arrivals(count: 700) { _ in 0.5 + 0.2 * noise.next() }
    let (records, rendered, stats) = simulateDirect(.smooth, arrivals: times, numbers: Array(0..<700), ticks: 600)
    let stalls: Int = stats.stalls
    let drops: Int = stats.catchUpDrops + stats.overflowDrops
    let wait: Double = meanWait(records, 60..<600)
    #expect(stalls == 0)
    #expect(drops == 0)
    #expect(rendered == Array(0..<rendered.count))
    #expect(rendered.count >= 595)
    #expect(wait < vsyncMs)
}

@Test func smoothShowsALateFrameInsteadOfSkippingItThenStepsBack() {
    // Frame 300 comes 30 ms late and 301 14 ms late, the rest on time.
    var noise = Noise(seed: 51)
    let delays: [Int: Double] = [300: 30, 301: 14]
    let times = arrivals(count: 900) { _ in 0.5 + 0.05 * noise.next() }.enumerated().map { $0.element + (delays[$0.offset] ?? 0) }
    let (records, rendered, stats) = simulateDirect(.smooth, arrivals: times, numbers: Array(0..<900), ticks: 800)
    let stalls: Int = stats.stalls
    let catchUp: Int = stats.catchUpDrops
    let skipped = Set(0..<(rendered.last ?? 0)).subtracting(rendered)
    let before: Double = meanWait(records, 100..<290)
    let after: Double = meanWait(records, 700..<800)
    #expect(rendered.contains(300) && rendered.contains(301))
    #expect(stalls >= 1 && stalls <= 3)
    // Every stretch is stepped back once the stream is calm, each step skipping at most one frame.
    // The late frames also lift the base delay (at most to its cap) for the lateness window, and a
    // refresh of lag may stand after the last step (see `presentDue`), nothing more.
    #expect(catchUp <= stalls)
    #expect(skipped.count == catchUp)
    #expect(skipped.allSatisfy { $0 > 400 })
    #expect(rendered == rendered.sorted())
    #expect(after - before < vsyncMs + PlayoutClockCap.ms)
}

@Test func smoothStartsOverAfterAnOutage() {
    // One second without frames (60 frame numbers lost), then a regular stream again.
    var noise = Noise(seed: 52)
    let all = arrivals(count: 900) { _ in 0.5 + 0.1 * noise.next() }
    let kept = Array(0..<300) + Array(360..<900)
    let (records, rendered, stats) = simulateDirect(.smooth, arrivals: kept.map { all[$0] }, numbers: kept, ticks: 800)
    let catchUp: Int = stats.catchUpDrops
    let after: Double = meanWait(records, 500..<800)
    #expect(catchUp == 0)
    #expect(rendered == Array(0..<rendered.count))
    #expect(after < vsyncMs)
}

@Test func smoothTakesAFrameNumberJumpWithoutAGapInStride() {
    // The host's numbering jumps by 174 with no time passing (seen on device after a keyframe).
    var noise = Noise(seed: 53)
    let times = arrivals(count: 700) { _ in 0.5 + 0.1 * noise.next() }
    let numbers = (0..<700).map { $0 < 300 ? $0 : $0 + 174 }
    let (_, rendered, stats) = simulateDirect(.smooth, arrivals: times, numbers: numbers, ticks: 600)
    let stalls: Int = stats.stalls
    let drops: Int = stats.catchUpDrops + stats.overflowDrops
    #expect(stalls == 0)
    #expect(drops == 0)
    #expect(rendered == Array(0..<rendered.count))
}

@Test func smoothAt30FpsOn60HzShowsEveryFrameWithoutStalls() {
    var noise = Noise(seed: 54)
    let times = arrivals30(count: 400) { _ in 1 + 0.2 * noise.next() }
    let (_, rendered, stats) = simulateDirect(.smooth, arrivals: times, numbers: Array(0..<400), ticks: 700,
                                              frameRate: 30)
    let stalls: Int = stats.stalls
    let drops: Int = stats.catchUpDrops + stats.overflowDrops
    #expect(stalls == 0)
    #expect(drops == 0)
    #expect(rendered == Array(0..<rendered.count))
    #expect(rendered.count >= 345)
}
