import Foundation
import Testing
@testable import StreamKit

/// The full pacer comparison: every scenario of `PacerSimulator.scenarios()`,
/// `repeaterScenarios()` and `wiredScenarios()` for 10 simulated minutes and three seeds, per pacing mode, with the
/// pacer's own counters next to the measured ones. Takes about 20 seconds, so it only runs on
/// request:
/// `PACER_COMPARISON=1 swift test --package-path SeleniteKit --filter pacerComparison`
/// (`PACER_SECONDS`, `PACER_TICKDELAY` and `PACER_LATCH` override the model, `PACER_RULE` picks a
/// `FramePacer.CatchUpRule` other than the shipped one, `PACER_OUT` names a file for the table).
@Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_COMPARISON"] != nil))
func pacerComparison() {
    let env = ProcessInfo.processInfo.environment
    let seconds = env["PACER_SECONDS"].flatMap(Double.init) ?? 600
    let tickDelay = env["PACER_TICKDELAY"].flatMap(Double.init) ?? 1
    let latch = env["PACER_LATCH"].flatMap(Double.init) ?? 0
    let rule = env["PACER_RULE"].flatMap(FramePacer<Int>.CatchUpRule.init(rawValue:)) ?? .roundTwo
    let modes: [(String, FramePacingMode, Bool)] = [
        ("lowLatency direct", .lowLatency, true),
        ("lowLatency tick", .lowLatency, false),
        ("smooth direct", .smooth, true),
        ("smoothPlus", .smoothPlus, false),
    ]
    let seeds: [UInt64] = [1, 2, 3]
    var lines = ["mode | scenario | latency ms | lagging % | repeats/min | drops/min | hitches/min | Lagging stat % | "
        + "Display wait ms | pacer stalls/min | pacer drops/min | jitter ms"]
    let scenarios = PacerSimulator.scenarios(seconds: seconds) + PacerSimulator.repeaterScenarios(seconds: seconds)
        + PacerSimulator.wiredScenarios(seconds: seconds)
    for (name, mode, direct) in modes {
        for var scenario in scenarios {
            scenario.tickDelayMs = tickDelay
            scenario.latchMs = latch
            let results = seeds.map { seed -> PacerSimResult in
                var seeded = scenario
                seeded.seed = seed
                return PacerSimulator.run(seeded, mode: mode, directPresent: direct) { $0.catchUpRule = rule }
            }
            func mean(_ value: (PacerSimResult) -> Double) -> String {
                String(format: "%.2f", results.map(value).reduce(0, +) / Double(results.count))
            }
            lines.append([name, scenario.name, mean(\.meanLatencyMs), mean { $0.laggingShare * 100 },
                          mean(\.repeatsPerMinute), mean(\.dropsPerMinute), mean(\.hitchesPerMinute),
                          mean(\.laggingStatPercent), mean(\.displayWaitMs), mean(\.pacerStallsPerMinute),
                          mean(\.pacerDropsPerMinute), mean { $0.stats.jitterMilliseconds }]
                .joined(separator: " | "))
        }
    }
    let table = lines.joined(separator: "\n")
    if let path = env["PACER_OUT"] { try? table.write(toFile: path, atomically: true, encoding: .utf8) }
    print(table)
}
