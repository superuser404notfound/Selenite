import Testing
@testable import StreamKit

/// Feeds `arrivals[i]` frames before tick i and records what each tick presents.
private func run(_ arrivals: [Int], catchUpTicks: Int = 3) -> (shown: [Int?], stats: PacerStats) {
    let pacer = FramePacer<Int>(catchUpTicks: catchUpTicks)
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

@Test func standingLagIsCaughtUpAfterThreeTicks() {
    // One extra frame up front, then one per tick: the buffer never drains on its own.
    let (shown, stats) = run([2] + Array(repeating: 1, count: 9))
    #expect(stats.catchUpDrops == 1)
    #expect(stats.bufferedTicks == 2)
    #expect(shown[2] == 3)   // tick 3 skipped frame 2 and showed the newest
    #expect(shown.last == 10)
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
