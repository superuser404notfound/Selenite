import StreamKit
import Testing
@testable import AppCore

private let settings = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 100_000, hdr: false)

@Test func measuredBitrateComesFromTheByteDelta() {
    let previous = StreamStats(sampledAt: 10, receivedBytes: 1_000_000)
    let current = StreamStats(sampledAt: 12, receivedBytes: 13_500_000)
    let summary = StreamStatsSummary(current: current, previous: previous, settings: settings)
    #expect(abs(summary.measuredBitrateMbps - 50) < 1e-9)
    #expect(summary.bitrateMbps == 100)
}

@Test func theFirstSampleMeasuresZeroBitrate() {
    let summary = StreamStatsSummary(current: StreamStats(sampledAt: 5, receivedBytes: 9_000_000),
                                     previous: nil, settings: settings)
    #expect(summary.measuredBitrateMbps == 0)
}

@Test func aZeroIntervalMeasuresZeroBitrate() {
    let stats = StreamStats(sampledAt: 5, receivedBytes: 9_000_000)
    let summary = StreamStatsSummary(current: stats, previous: StreamStats(sampledAt: 5), settings: settings)
    #expect(summary.measuredBitrateMbps == 0)
    #expect(summary.measuredBitrateMbps.isFinite)
}

@Test func windowMeansUseTheDelta() {
    var previousPacer = PacerStats()
    previousPacer.displayWaitTotalMilliseconds = 100
    previousPacer.displayWaitSamples = 50
    var currentPacer = PacerStats()
    currentPacer.displayWaitTotalMilliseconds = 160
    currentPacer.displayWaitSamples = 110
    currentPacer.jitterMilliseconds = 1.5
    let previous = StreamStats(pacer: previousPacer, sampledAt: 1, hostLatencyTotalTenths: 4000,
                               hostLatencySamples: 100, networkReceiveTotalMicroseconds: 100_000,
                               networkReceiveSamples: 100)
    let current = StreamStats(pacer: currentPacer, rttMilliseconds: 4, sampledAt: 2, queueDroppedFrames: 3,
                              unrecoverableFrames: 2, hostLatencyTotalTenths: 10000, hostLatencySamples: 200,
                              hostLatencyRange: 3...9, networkReceiveTotalMicroseconds: 400_000,
                              networkReceiveSamples: 200, rttVarianceMilliseconds: 2)
    let summary = StreamStatsSummary(current: current, previous: previous, settings: settings)
    #expect(summary.hostLatency == HostLatency(mean: 6, min: 3, max: 9))
    #expect(abs((summary.networkMilliseconds ?? -1) - 3) < 1e-9)
    #expect(abs((summary.displayMilliseconds ?? -1) - 1) < 1e-9)
    #expect(summary.rttVarianceMilliseconds == 2)
    #expect(summary.queueDrops == 3)
    #expect(summary.unrecoverableFrames == 2)
    #expect(summary.jitterMilliseconds == 1.5)
}

@Test func noHostLatencyMeansNil() {
    let summary = StreamStatsSummary(current: StreamStats(sampledAt: 2), previous: StreamStats(sampledAt: 1),
                                     settings: settings)
    #expect(summary.hostLatency == nil)
    #expect(summary.networkMilliseconds == nil)
    #expect(summary.displayMilliseconds == nil)
}

@Test func aCounterThatWentBackwardsGivesNoNetworkWindow() {
    let previous = StreamStats(sampledAt: 1, networkReceiveTotalMicroseconds: 400_000, networkReceiveSamples: 200)
    let current = StreamStats(sampledAt: 2, networkReceiveTotalMicroseconds: 100_000, networkReceiveSamples: 300)
    let summary = StreamStatsSummary(current: current, previous: previous, settings: settings)
    #expect(summary.networkMilliseconds == nil)
}

@Test func withoutAPreviousSampleTheRunningTotalsAreUsed() {
    var pacer = PacerStats()
    pacer.displayWaitTotalMilliseconds = 50
    pacer.displayWaitSamples = 50
    let current = StreamStats(pacer: pacer, hostLatencyTotalTenths: 600, hostLatencySamples: 100,
                              hostLatencyRange: 3...9, networkReceiveTotalMicroseconds: 300_000,
                              networkReceiveSamples: 100)
    let summary = StreamStatsSummary(current: current, previous: nil, settings: settings)
    #expect(summary.hostLatency == HostLatency(mean: 0.6, min: 3, max: 9))
    #expect(abs((summary.networkMilliseconds ?? -1) - 3) < 1e-9)
    #expect(abs((summary.displayMilliseconds ?? -1) - 1) < 1e-9)
}

@Test func fpsUsesTheRealInterval() {
    var previousPacer = PacerStats()
    previousPacer.presented = 0
    var currentPacer = PacerStats()
    currentPacer.presented = 126
    let previous = StreamStats(pacer: previousPacer, sampledAt: 10)
    let current = StreamStats(pacer: currentPacer, sampledAt: 12.1)
    let summary = StreamStatsSummary(current: current, previous: previous, settings: settings)
    #expect(summary.fps == 60)
}

@Test func fpsWithoutTimestampsKeepsTheRawDelta() {
    var previousPacer = PacerStats()
    previousPacer.presented = 100
    var currentPacer = PacerStats()
    currentPacer.presented = 159
    let previous = StreamStats(pacer: previousPacer)
    let current = StreamStats(pacer: currentPacer)
    let summary = StreamStatsSummary(current: current, previous: previous, settings: settings)
    #expect(summary.fps == 59)
}

@Test func displayAndStreamRatesComeFromThePacerMeans() {
    var pacer = PacerStats()
    pacer.vsyncIntervalMilliseconds = 16.6833
    pacer.arrivalIntervalMilliseconds = 16.6667
    let summary = StreamStatsSummary(current: StreamStats(pacer: pacer), previous: nil, settings: settings)
    #expect(abs((summary.displayHz ?? -1) - 59.94) < 0.01)
    #expect(abs((summary.streamFps ?? -1) - 60.00) < 0.01)
}

@Test func missedTicksIsTheRunningPacerTotal() {
    var pacer = PacerStats()
    pacer.missedTicks = 7
    let summary = StreamStatsSummary(current: StreamStats(pacer: pacer), previous: nil, settings: settings)
    #expect(summary.missedTicks == 7)
}

@Test func noPacerMeansNoRates() {
    let summary = StreamStatsSummary(current: StreamStats(), previous: nil, settings: settings)
    #expect(summary.displayHz == nil)
    #expect(summary.streamFps == nil)
}
