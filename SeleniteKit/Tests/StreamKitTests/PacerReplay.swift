import Foundation
@testable import StreamKit

/// One recorded trace replayed through one catch-up rule.
struct PacerReplayResult: Sendable {
    var minutes: Double
    var shown = 0
    /// Arrival to the vsync that shows the frame, mean, with the renderer taking a frame enqueued
    /// up to the vsync itself (`latch` 0) and with it needing the frame 1 or 2 ms earlier.
    var latencyMs: [Double] = []
    var laggingShare = 0.0
    var stats = PacerStats()
    /// Vsyncs between the first and last shown frame that showed no new frame, and frames that
    /// arrived and never reached the screen, per latch.
    var repeats: [Int] = []
    var drops: [Int] = []

    var stallsPerMinute: Double { Double(stats.stalls) / minutes }
    var catchUpDropsPerMinute: Double { Double(stats.catchUpDrops) / minutes }
    var overflowDropsPerMinute: Double { Double(stats.overflowDrops) / minutes }
    func hitchesPerMinute(latch: Int = 0) -> Double { Double(repeats[latch] + drops[latch]) / minutes }
}

private final class ReplayClock: @unchecked Sendable {
    var now = 0.0
    var enqueued: [(frame: Int, time: Double)] = []
}

enum PacerReplay {
    /// The latches the renderer is evaluated at, milliseconds before the vsync.
    static let latchesMs: [Double] = [0, 1, 2]

    /// Feeds the trace's inputs in their recorded order into a fresh pacer that uses `rule`, with
    /// the pacer's clock at each input's own time: a put at its arrival (a direct present enqueues
    /// right there), a vsync and its tick at the tick time. Frames are numbered by put order.
    /// Every enqueue is shown at the first vsync after it (plus the latch) on the grid of recorded
    /// vsyncs, gaps from missed callbacks filled at the reported duration; of several for one
    /// vsync only the newest is shown.
    static func run(_ trace: PacerTrace, rule: FramePacer<Int>.CatchUpRule) -> PacerReplayResult {
        let clock = ReplayClock()
        let metadata = trace.metadata
        let pacer = FramePacer<Int>(mode: FramePacingMode(rawValue: metadata.mode) ?? .lowLatency,
                                    frameRate: metadata.frameRate, directPresent: metadata.directPresent,
                                    clock: { clock.now })
        pacer.catchUpRule = rule
        var arrivals: [Double] = []
        var grid: [Double] = []
        var lastTick = 0.0
        for event in trace.events {
            switch event {
            case let .put(arrival, frameNumber):
                clock.now = arrival
                pacer.put(arrivals.count, arrival: arrival, frameNumber: frameNumber)
                arrivals.append(arrival)
            case let .vsync(timestamp, duration, tickTime):
                if let last = grid.last, duration > 0, timestamp - last > 1.5 * duration {
                    var filled = last + duration
                    while filled < timestamp - duration / 2 {
                        grid.append(filled)
                        filled += duration
                    }
                }
                if grid.last.map({ timestamp > $0 }) ?? true { grid.append(timestamp) }
                clock.now = tickTime
                lastTick = tickTime
                pacer.vsync(timestamp: timestamp, duration: duration, tickTime: tickTime)
            case .tick:
                clock.now = lastTick
                if let frame = pacer.tick() { clock.enqueued.append((frame, lastTick)) }
            case let .presenter(attached):
                if attached {
                    pacer.setPresenter { [clock] frame in clock.enqueued.append((frame, clock.now)) }
                } else {
                    pacer.setPresenter(nil)
                }
            }
        }
        let first = min(arrivals.first ?? 0, grid.first ?? 0)
        let last = max(arrivals.last ?? 0, grid.last ?? 0)
        var result = PacerReplayResult(minutes: max(1e-9, (last - first) / 60))
        result.stats = pacer.stats
        for latchMs in latchesMs {
            let evaluated = evaluate(arrivals: arrivals, enqueued: clock.enqueued, grid: grid, latch: latchMs / 1000)
            result.latencyMs.append(evaluated.latencyMs)
            result.repeats.append(evaluated.repeats)
            result.drops.append(evaluated.drops)
            if latchMs == 0 {
                result.laggingShare = evaluated.laggingShare
                result.shown = evaluated.shown
            }
        }
        return result
    }

    private static func evaluate(arrivals: [Double], enqueued: [(frame: Int, time: Double)], grid: [Double],
                                 latch: Double) -> (latencyMs: Double, laggingShare: Double, repeats: Int, drops: Int, shown: Int) {
        guard !grid.isEmpty else { return (0, 0, 0, arrivals.count, 0) }
        /// First grid vsync the renderer can still take a frame for, at or after `time`.
        func firstVsync(after time: Double) -> Int? {
            var low = 0, high = grid.count
            while low < high {
                let middle = (low + high) / 2
                if grid[middle] - latch > time { high = middle } else { low = middle + 1 }
            }
            return low < grid.count ? low : nil
        }
        var shownAt = [Int](repeating: -1, count: arrivals.count)
        var newestFor: [Int: Int] = [:]
        for (frame, time) in enqueued {
            guard let vsync = firstVsync(after: time) else { continue }
            newestFor[vsync] = frame
        }
        for (vsync, frame) in newestFor { shownAt[frame] = vsync }
        var latency = 0.0, lagging = 0, shown = 0
        for (frame, arrival) in arrivals.enumerated() where shownAt[frame] >= 0 {
            latency += grid[shownAt[frame]] - arrival
            if let earliest = firstVsync(after: arrival), shownAt[frame] > earliest { lagging += 1 }
            shown += 1
        }
        let used = Set(newestFor.keys)
        var repeats = 0
        if let low = used.min(), let high = used.max() {
            repeats = (low...high).filter { !used.contains($0) }.count
        }
        let drops = arrivals.count - shown
        return (shown > 0 ? latency / Double(shown) * 1000 : 0, shown > 0 ? Double(lagging) / Double(shown) : 0,
                repeats, drops, shown)
    }

    /// One table row per trace and rule.
    static func table(_ traces: [(name: String, trace: PacerTrace)],
                      rules: [FramePacer<Int>.CatchUpRule] = FramePacer<Int>.CatchUpRule.allCases) -> String {
        var lines = ["trace | rule | minutes | latency ms | latency latch 1 ms | latency latch 2 ms | Lagging % | "
            + "stalls/min | catch-up drops/min | overflow drops/min | hitches/min | hitches/min latch 2 ms"]
        for (name, trace) in traces {
            for rule in rules {
                let result = run(trace, rule: rule)
                func f(_ value: Double) -> String { String(format: "%.2f", value) }
                lines.append([name, rule.rawValue, f(result.minutes), f(result.latencyMs[0]), f(result.latencyMs[1]),
                              f(result.latencyMs[2]), f(result.laggingShare * 100), f(result.stallsPerMinute),
                              f(result.catchUpDropsPerMinute), f(result.overflowDropsPerMinute),
                              f(result.hitchesPerMinute()), f(result.hitchesPerMinute(latch: 2))].joined(separator: " | "))
            }
        }
        return lines.joined(separator: "\n")
    }
}
