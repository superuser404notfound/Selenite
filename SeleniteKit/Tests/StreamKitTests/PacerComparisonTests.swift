import Foundation
import Testing
@testable import StreamKit

/// The full pacer comparison: every scenario of `PacerSimulator.scenarios()` for 10 simulated
/// minutes and three seeds, per pacing mode. Takes about ten seconds, so it only runs on request:
/// `PACER_COMPARISON=1 swift test --package-path SeleniteKit --filter pacerComparison`
/// (`PACER_SECONDS`, `PACER_TICKDELAY` and `PACER_LATCH` override the model, `PACER_OUT` names a
/// file for the table).
@Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_COMPARISON"] != nil))
func pacerComparison() {
    let env = ProcessInfo.processInfo.environment
    let seconds = env["PACER_SECONDS"].flatMap(Double.init) ?? 600
    let tickDelay = env["PACER_TICKDELAY"].flatMap(Double.init) ?? 1
    let latch = env["PACER_LATCH"].flatMap(Double.init) ?? 0
    let modes: [(String, FramePacingMode, Bool)] = [
        ("lowLatency direct", .lowLatency, true),
        ("lowLatency tick", .lowLatency, false),
        ("smooth", .smooth, false),
    ]
    let seeds: [UInt64] = [1, 2, 3]
    var lines = ["mode | scenario | latency ms | lagging % | repeats/min | drops/min | hitches/min | Lagging stat %"]
    for (name, mode, direct) in modes {
        for var scenario in PacerSimulator.scenarios(seconds: seconds) {
            scenario.tickDelayMs = tickDelay
            scenario.latchMs = latch
            let results = seeds.map { seed -> PacerSimResult in
                var seeded = scenario
                seeded.seed = seed
                return PacerSimulator.run(seeded, mode: mode, directPresent: direct)
            }
            func mean(_ value: (PacerSimResult) -> Double) -> String {
                String(format: "%.2f", results.map(value).reduce(0, +) / Double(results.count))
            }
            lines.append([name, scenario.name, mean(\.meanLatencyMs), mean { $0.laggingShare * 100 },
                          mean(\.repeatsPerMinute), mean(\.dropsPerMinute), mean(\.hitchesPerMinute),
                          mean { Double($0.stats.laggingPresents) / Double(max(1, $0.stats.presented)) * 100 }]
                .joined(separator: " | "))
        }
    }
    let table = lines.joined(separator: "\n")
    if let path = env["PACER_OUT"] { try? table.write(toFile: path, atomically: true, encoding: .utf8) }
    print(table)
}
