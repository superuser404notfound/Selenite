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
    let previous = StreamStats(pacer: previousPacer, sampledAt: 1, hostLatencyTotalTenths: 400,
                               hostLatencySamples: 100, networkReceiveTotalMicroseconds: 100_000,
                               networkReceiveSamples: 100)
    let current = StreamStats(pacer: currentPacer, rttMilliseconds: 4, sampledAt: 2, queueDroppedFrames: 3,
                              unrecoverableFrames: 2, hostLatencyTotalTenths: 1000, hostLatencySamples: 200,
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
