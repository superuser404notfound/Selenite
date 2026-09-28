import Testing
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
/// `arrivals` are milliseconds on the same clock as the vsyncs, which fire every `vsyncMs` from
/// `startMs`; stats are cumulative after each tick.
private func simulate(_ mode: FramePacingMode, arrivals: [Double], ticks: Int,
                      startMs: Double = 1000) -> [TickRecord] {
    let pacer = FramePacer<Int>(mode: mode)
    var next = 0
    var records: [TickRecord] = []
    for tick in 0..<ticks {
        let now = startMs + Double(tick) * vsyncMs
        while next < arrivals.count, arrivals[next] < now {
            pacer.put(next, arrival: arrivals[next] / 1000)
            next += 1
        }
        pacer.vsync(timestamp: now / 1000, duration: vsyncMs / 1000)
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
