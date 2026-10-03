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

@Test func smoothAbsorbsJitterAtEveryPhase() {
    for (index, phase) in [0.0, 0.1, 0.3, 0.5, 0.7, 0.9].enumerated() {
        var noise = Noise(seed: UInt64(10 + index))
        let times = arrivals(count: 1300) { _ in phase + 0.45 * noise.next() }
        let records = simulate(.smooth, arrivals: times, ticks: 1200)
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

@Test func smoothPrimesBeforeTheFirstFrame() {
    let (shown, stats) = run([1, 1, 1, 1], mode: .smooth)
    let stalls: Int = stats.stalls
    #expect(shown == [nil, 0, 1, 2])
    #expect(stalls == 1)
}

@Test func smoothCutsClockDriftCreepWithIsolatedDrops() {
    // Host clock runs fast: a frame every 16.60 ms against a 16.666 ms refresh.
    var noise = Noise(seed: 4)
    let times = (0..<5000).map { n in 1000 + 8 + Double(n) * 16.60 + 1.5 * noise.next() }
    let records = simulate(.smooth, arrivals: times, ticks: 4800)
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

@Test func smoothStallsThroughAGapThenReprimes() {
    // Frames 200, 201 and 202 never arrive.
    let times = arrivals(count: 700) { _ in 0.5 }.enumerated().filter { !(200...202).contains($0.offset) }.map(\.element)
    let records = simulate(.smooth, arrivals: times, ticks: 600)
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

@Test func smoothAt30FpsOn60HzHoldsEveryFrameForTwoTicks() {
    var noise = Noise(seed: 20)
    let times = arrivals30(count: 700) { _ in 1 + 0.8 * noise.next() }
    let records = simulate(.smooth, arrivals: times, ticks: 1200, frameRate: 30)
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

@Test func smoothAt30FpsReprimesOnlyWhenAFrameIsMissing() {
    // Frames 100 and 101 never arrive: more than the standing frame can cover (one missing frame
    // is absorbed by it), the rest is on time.
    let times = arrivals30(count: 400) { _ in 1.5 }.enumerated().filter { ![100, 101].contains($0.offset) }.map(\.element)
    let records = simulate(.smooth, arrivals: times, ticks: 700, frameRate: 30)
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

@Test func smoothAt30FpsOn50HzShowsAllThirtyFrames() {
    var noise = Noise(seed: 30)
    let times = streamArrivals(count: 1000, fps: 30, offsetMs: 7) { _ in 4 * noise.next() }
    let records = simulate(.smooth, arrivals: times, ticks: 1500, frameRate: 30, refreshMs: refresh50Ms)
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

@Test func smoothAt30FpsOn50HzHoldsTwoTwoOne() {
    let times = streamArrivals(count: 400, fps: 30, offsetMs: 7)
    let records = simulate(.smooth, arrivals: times, ticks: 500, frameRate: 30, refreshMs: refresh50Ms)
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

@Test func smoothAt60FpsOn50HzNeverWaits() {
    // More frames than refreshes: every tick after priming shows one, the surplus overflows.
    let times = streamArrivals(count: 700, fps: 60, offsetMs: 3)
    let records = simulate(.smooth, arrivals: times, ticks: 500, frameRate: 60, refreshMs: refresh50Ms)
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
                            ticks: Int, startMs: Double = 1000, frameRate: Int = 60,
                            refreshMs: Double = vsyncMs) -> (records: [TickRecord], rendered: [Int], stats: PacerStats) {
    let pacer = FramePacer<Int>(mode: mode, frameRate: frameRate, directPresent: directPresent)
    let sink = PresentSink()
    pacer.setPresenter { sink.present($0) }
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
        if let frame { sink.present(frame) }
        let stats = pacer.stats
        records.append(TickRecord(shown: frame, stalls: stats.stalls, catchUpDrops: stats.catchUpDrops,
                                  overflowDrops: stats.overflowDrops))
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

@Test func smoothIgnoresDirectPresent() {
    var noise = Noise(seed: 43)
    let times = arrivals(count: 700) { _ in 0.5 + 0.25 * noise.next() }
    let (records, _, stats) = simulateDirect(.smooth, arrivals: times, ticks: 600)
    let reference = simulate(.smooth, arrivals: times, ticks: 600)
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

@Test func displayWaitIsArrivalToTick() {
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
    #expect(stats.displayWaitSamples == 1)
    #expect(abs(stats.displayWaitTotalMilliseconds - 1) < 1e-6)
}

@Test func catchUpDropsAddNoDisplayWait() {
    let (_, stats) = run([2] + Array(repeating: 1, count: 39))
    #expect(stats.catchUpDrops == 1)
    #expect(stats.displayWaitSamples == stats.presented)
}
