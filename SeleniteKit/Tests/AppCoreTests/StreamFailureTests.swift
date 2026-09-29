import Foundation
import HostKit
import StreamKit
import Testing
@testable import AppCore

@Test func sessionErrorsMapToReasons() {
    let slot: StreamFailure = StreamFailure.from(error: StreamSessionError.noFreeSlot)
    let refused: StreamFailure = StreamFailure.from(error: StreamSessionError.launchFailed("The host is busy"))
    let connect: StreamFailure = StreamFailure.from(error: StreamSessionError.connectionFailed(-1))
    #expect(slot == .slotBusy)
    #expect(refused == .hostRefused("The host is busy"))
    #expect(connect == .connectionFailed(-1))
}

@Test func networkAndHostErrorsMapToReasons() {
    let timedOut: StreamFailure = StreamFailure.from(error: URLError(.timedOut))
    let unreachable: StreamFailure = StreamFailure.from(error: URLError(.cannotConnectToHost))
    let status: StreamFailure = StreamFailure.from(error: NvError.status(503, "busy"))
    #expect(timedOut == .timedOut)
    #expect(unreachable == .hostUnreachable)
    #expect(status == .hostRefused("busy"))
}

@Test func terminationCodesMapToReasons() {
    let cases: [(Int32, StreamFailure)] = [
        (0, .gameClosed), (-100, .noVideoTraffic), (-101, .unstableConnection),
        (-102, .earlyTermination), (-103, .protectedContent), (-104, .frameConversion),
        (-1, .connectionEnded(-1)), (42, .connectionEnded(42)),
    ]
    for (code, expected) in cases {
        let failure: StreamFailure = StreamFailure.from(terminationCode: code)
        #expect(failure == expected, "code \(code)")
    }
}

@Test func theSummaryTakesFramesPerSecondFromTheDelta() {
    var previousPacer = PacerStats()
    previousPacer.presented = 100
    var currentPacer = PacerStats()
    currentPacer.presented = 159
    currentPacer.overflowDrops = 2
    currentPacer.catchUpDrops = 1
    currentPacer.stalls = 4
    var audio = AudioRingStats()
    audio.underruns = 5
    let settings = StreamSettings(width: 3840, height: 2160, fps: 60, bitrateKbps: 150_000, hdr: false)
    let summary = StreamStatsSummary(
        current: StreamStats(networkDroppedFrames: 3, pacer: currentPacer, averageDecodeMilliseconds: 2.5,
                             rttMilliseconds: 12, audio: audio),
        previous: StreamStats(pacer: previousPacer),
        settings: settings)
    #expect(summary.fps == 59)
    #expect(summary.width == 3840)
    #expect(summary.height == 2160)
    #expect(summary.bitrateMbps == 150)
    #expect(summary.rttMilliseconds == 12)
    #expect(summary.decodeMilliseconds == 2.5)
    #expect(summary.networkDrops == 3)
    #expect(summary.pacerDrops == 3)
    #expect(summary.stalls == 4)
    #expect(summary.audioUnderruns == 5)
}

@Test func theFirstSampleReportsZeroFramesPerSecond() {
    var pacer = PacerStats()
    pacer.presented = 30
    let settings = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, hdr: false)
    let summary = StreamStatsSummary(current: StreamStats(pacer: pacer), previous: nil, settings: settings)
    #expect(summary.fps == 0)
    #expect(summary.rttMilliseconds == nil)
    #expect(summary.audioUnderruns == 0)
}

@Test func aFailedQuitOffersNoRetry() {
    // Retrying after a failed quit would relaunch the game just quit.
    let quit: Bool = StreamFailure.quitFailed.offersRetry
    let lost: Bool = StreamFailure.unstableConnection.offersRetry
    #expect(!quit)
    #expect(lost)
}

@Test func aHostThatDidNotWakeOffersRetry() {
    #expect(StreamFailure.hostDidNotWake("PC").offersRetry)
}
