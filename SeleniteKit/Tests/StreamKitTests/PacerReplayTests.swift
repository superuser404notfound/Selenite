import Foundation
import Testing
@testable import StreamKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-replay-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs `scenario` through the simulator with `rule` while recording its trace, then replays it.
private func recordAndReplay(_ scenario: PacerScenario, rule: FramePacer<Int>.CatchUpRule) throws
    -> (live: PacerSimResult, replay: PacerReplayResult) {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = PacerTraceRecorder(metadata: PacerTrace.Metadata(
        mode: "lowLatency", directPresent: true, frameRate: 60, slot: 0, width: 1920, height: 1080,
        startedAt: "2026-10-05T12:00:00+02:00"), directory: directory)
    let live = PacerSimulator.run(scenario, mode: .lowLatency, warmupSeconds: 0, trace: recorder) { $0.catchUpRule = rule }
    let trace = try PacerTrace.decode(Data(contentsOf: recorder.fileURL))
    return (live, PacerReplay.run(trace, rule: rule))
}

@Test func aReplayedTraceMakesTheSameDecisionsAsTheLivePacer() throws {
    for rule in [FramePacer<Int>.CatchUpRule.roundTwo, .roundOne] {
        var scenario = PacerSimulator.repeaterScenarios(seconds: 30).first { $0.name == "dyn drift 60.02" }!
        scenario.seed = 4
        let (live, replay) = try recordAndReplay(scenario, rule: rule)
        #expect(replay.stats.presented == live.stats.presented, "\(rule)")
        #expect(replay.stats.directPresents == live.stats.directPresents, "\(rule)")
        #expect(replay.stats.stalls == live.stats.stalls, "\(rule)")
        #expect(replay.stats.catchUpDrops == live.stats.catchUpDrops, "\(rule)")
        #expect(replay.stats.overflowDrops == live.stats.overflowDrops, "\(rule)")
        #expect(abs(replay.latencyMs[0] - live.meanLatencyMs) < 0.2, "\(rule)")
        #expect(abs(replay.laggingShare - live.laggingShare) < 0.01, "\(rule)")
    }
}

@Test func anEarlierLatchCostsTheFramesThatArriveJustBeforeTheVsync() throws {
    var scenario = PacerSimulator.repeaterScenarios(seconds: 20).first { $0.name == "dyn mid" }!
    scenario.seed = 5
    let (_, replay) = try recordAndReplay(scenario, rule: .roundTwo)
    #expect(replay.latencyMs[1] >= replay.latencyMs[0])
    #expect(replay.latencyMs[2] >= replay.latencyMs[1])
}

/// `Fixtures/pacer-trace-fixture.bin`: 10 s of the simulator's "dyn drift 60.02" scenario (seed 7)
/// recorded under round two, regenerated with
/// `PACER_WRITE_FIXTURE=<path> swift test --package-path SeleniteKit --filter writePacerTraceFixture`.
private var fixtureURL: URL {
    Bundle.module.url(forResource: "pacer-trace-fixture", withExtension: "bin", subdirectory: "Fixtures")!
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_WRITE_FIXTURE"] != nil))
func writePacerTraceFixture() throws {
    let destination = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PACER_WRITE_FIXTURE"]!)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var scenario = PacerSimulator.repeaterScenarios(seconds: 10).first { $0.name == "dyn drift 60.02" }!
    scenario.seed = 7
    let recorder = PacerTraceRecorder(metadata: PacerTrace.Metadata(
        mode: "lowLatency", directPresent: true, frameRate: 60, slot: 1, width: 1920, height: 2160,
        startedAt: "2026-10-05T12:00:00+02:00"), directory: directory)
    _ = PacerSimulator.run(scenario, mode: .lowLatency, warmupSeconds: 0, trace: recorder)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: recorder.fileURL, to: destination)
}

@Test func theFixtureTraceReadsAndReplaysThroughEveryRule() throws {
    let trace = try PacerTrace.decode(Data(contentsOf: fixtureURL))
    #expect(trace.metadata.slot == 1 && trace.metadata.width == 1920 && trace.metadata.height == 2160)
    let puts = trace.events.filter { if case .put = $0 { true } else { false } }.count
    let vsyncs = trace.events.filter { if case .vsync = $0 { true } else { false } }.count
    #expect(puts == 599)
    #expect(vsyncs == 600)
    for rule in FramePacer<Int>.CatchUpRule.allCases {
        let result = PacerReplay.run(trace, rule: rule)
        #expect(result.shown > 550, "\(rule)")
        #expect(result.latencyMs[0] > 5 && result.latencyMs[0] < 40, "\(rule)")
    }
    let table = PacerReplay.table([("fixture", trace)])
    #expect(table.split(separator: "\n").count == 1 + FramePacer<Int>.CatchUpRule.allCases.count)
}

/// Replays real traces: `PACER_TRACE=<file or directory> swift test --package-path SeleniteKit
/// --filter pacerTraceReplay` prints one row per trace and rule (`PACER_OUT` also writes it).
@Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_TRACE"] != nil))
func pacerTraceReplay() throws {
    let env = ProcessInfo.processInfo.environment
    let path = env["PACER_TRACE"]!
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    let files = isDirectory.boolValue
        ? try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".bin") }.sorted()
            .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
        : [URL(fileURLWithPath: path)]
    let traces = try files.map { ($0.lastPathComponent, try PacerTrace.decode(Data(contentsOf: $0))) }
    let table = PacerReplay.table(traces)
    if let out = env["PACER_OUT"] { try table.write(toFile: out, atomically: true, encoding: .utf8) }
    print(table)
}
