import Testing
@testable import StreamKit

private let period = 1.0 / 60

@Test func theClockAdvancesByFrameNumbersAndTakesAnEarlyArrival() {
    var clock = PlayoutClock()
    #expect(clock.expect(arrival: 1.0, frameNumber: 10, period: period) == (1.0, true))
    // Two frames lost: the next one is expected three periods on.
    let late = clock.expect(arrival: 1.0 + 3 * period + 0.002, frameNumber: 13, period: period)
    #expect(abs(late.time - (1.0 + 3 * period)) < 1e-9 && !late.restarted)
    // An arrival before its expected time moves the clock to it.
    let early = clock.expect(arrival: 1.0 + 4 * period - 0.003, frameNumber: 14, period: period)
    #expect(abs(early.time - (1.0 + 4 * period - 0.003)) < 1e-9)
}

@Test func theClockStartsOverAfterAnOutageAJumpOrARestart() {
    var clock = PlayoutClock()
    _ = clock.expect(arrival: 1.0, frameNumber: 0, period: period)
    #expect(clock.expect(arrival: 1.5, frameNumber: 1, period: period).restarted)
    #expect(clock.expect(arrival: 1.5 + period, frameNumber: 200, period: period).restarted)
    #expect(clock.expect(arrival: 1.5 + 2 * period, frameNumber: 5, period: period).restarted)
    #expect(!clock.expect(arrival: 1.5 + 3 * period, frameNumber: 6, period: period).restarted)
}

@Test func theClockFollowsAHostSlowerThanThePeriodItIsGiven() {
    // The host runs at 59.97 fps while the clock is told 60: without the low-quantile shift the
    // lateness would grow by half a millisecond a second, to 20 ms by the end.
    var clock = PlayoutClock()
    var lateness: [Double] = []
    for n in 0..<2400 {
        let arrival = 1.0 + Double(n) / 59.97
        lateness.append(arrival - clock.expect(arrival: arrival, frameNumber: n, period: period).time)
    }
    let worst = lateness.suffix(1200).max() ?? 0
    #expect(worst < 0.003)
}

@Test func theBaseDelayIsCappedAndCoversRoutineLateness() {
    var clock = PlayoutClock()
    #expect(clock.baseDelay == PlayoutClock.baseCap)
    for n in 0..<600 {
        // Lateness 0, 1 or 2 ms in turn.
        _ = clock.expect(arrival: 1.0 + Double(n) * period + Double(n % 3) * 0.001, frameNumber: n, period: period)
    }
    let base = clock.baseDelay
    #expect(base >= 0.002 + PlayoutClock.baseMargin - 1e-9)
    #expect(base < PlayoutClock.baseCap)
}
