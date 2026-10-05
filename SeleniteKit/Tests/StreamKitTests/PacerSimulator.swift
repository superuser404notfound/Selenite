import Foundation
@testable import StreamKit

/// Deterministic generator (SplitMix64) with uniform and Gaussian draws, so a run replays exactly.
struct SimRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * uniform())
    }
}

/// One simulated stream against one simulated display.
struct PacerScenario: Sendable {
    var name: String
    var fps = 60.0
    var refreshHz = 60.0
    /// Where frame 0 lands after the first tick, as a fraction of the refresh interval. A stream
    /// at another rate than the display drifts away from it.
    var phase = 0.5
    /// Target standard deviation of the inter-arrival time (the pacer's jitter stat), ms. Each
    /// frame gets independent Gaussian noise of jitter / sqrt(2).
    var jitterMs = 2.0
    /// Wi-Fi bursts: episodes (exponential gaps, mean `burstEverySeconds`) of `burstSeconds` in
    /// which every frame is delayed by an extra uniform 0...`burstDelayMs`.
    var bursts = false
    var burstEverySeconds = 20.0
    var burstSeconds = 0.5
    var burstDelayMs = 30.0
    /// The first two frames arrive together, as after a stream start (the decoder hands over the
    /// IDR and the next frame at once), which can leave a direct-present stream a frame behind.
    var startupPair = true
    var seconds = 600.0
    var seed: UInt64 = 1
    /// The tick callback runs this long after its vsync.
    var tickDelayMs = 1.0
    /// The renderer must have a frame this long before the vsync to show it there.
    var latchMs = 0.0
    /// Replaces the Gaussian `jitterMs` noise with a measured link model when set.
    var link: LinkProfile?
}

/// Wi-Fi through a repeater, calibrated to the split device run (host processing 2.2 to 9.5 ms,
/// mean 4.8, jitter stat 3.0 to 3.2 ms): every frame pays host processing (a floor plus an
/// exponential tail, capped) and Gaussian network noise; rarely a frame is held up by an outlier
/// (later frames queue behind it), lost (never arrives), or the host pauses for a few frames
/// (static content sends nothing new).
struct LinkProfile: Sendable {
    var hostMinMs = 2.2
    var hostExtraMeanMs = 2.2
    var hostMaxMs = 10.0
    var networkSigmaMs = 0.8
    var outlierChance = 0.002
    var outlierMinMs = 8.0
    var outlierMaxMs = 30.0
    var lossChance = 0.0
    var pauseChance = 0.0
    var pauseFramesMax = 6
}

struct PacerSimResult: Sendable {
    var scenario: String
    var minutes: Double
    var shown = 0
    var meanLatencyMs = 0.0
    /// Share of shown frames that went on screen a vsync later than the earliest one after their
    /// arrival.
    var laggingShare = 0.0
    /// Vsyncs that showed no new frame.
    var repeats = 0
    /// Frames that arrived and were never on screen (pacer drops and frames the renderer replaced
    /// before their vsync).
    var drops = 0
    /// Pacer counters over the measured span only, what the overlay shows on device.
    var stats = PacerStats()
    /// Frames the link lost or the host skipped (gaps in the arrivals), not counted as drops.
    var lostFrames = 0

    var pacerStallsPerMinute: Double { Double(stats.stalls) / minutes }
    var pacerDropsPerMinute: Double { Double(stats.overflowDrops + stats.catchUpDrops) / minutes }
    var laggingStatPercent: Double { Double(stats.laggingPresents) / Double(max(1, stats.presented)) * 100 }
    var displayWaitMs: Double { stats.displayWaitTotalMilliseconds / Double(max(1, stats.displayWaitSamples)) }

    var repeatsPerMinute: Double { Double(repeats) / minutes }
    var dropsPerMinute: Double { Double(drops) / minutes }
    var hitchesPerMinute: Double { Double(repeats + drops) / minutes }
}

private final class SimClock: @unchecked Sendable {
    var now = 0.0
}

/// Collects (frame, enqueue time) as the renderer sees them.
private final class SimRenderer: @unchecked Sendable {
    var enqueued: [(frame: Int, time: Double)] = []
}

enum PacerSimulator {
    /// Frame arrival times in seconds, in order (a decoder hands frames over serially, so a
    /// delayed frame holds back the ones behind it).
    static func arrivals(_ scenario: PacerScenario, start: Double) -> [Double] {
        frames(scenario, start: start).times
    }

    /// Arrival times plus the stream's frame number for each: a lost frame leaves a gap in the
    /// numbers, a host pause (nothing new to send) does not.
    static func frames(_ scenario: PacerScenario, start: Double) -> (times: [Double], numbers: [Int]) {
        var random = SimRandom(seed: scenario.seed)
        let period = 1 / scenario.fps
        let refresh = 1 / scenario.refreshHz
        let sigma = scenario.jitterMs / 2.squareRoot() / 1000
        let count = Int(scenario.seconds * scenario.fps)
        var burstStart = scenario.bursts ? start + exponential(&random, mean: scenario.burstEverySeconds) : .infinity
        var times: [Double] = []
        var numbers: [Int] = []
        var number = 0
        times.reserveCapacity(count + 1)
        let base = start + scenario.tickDelayMs / 1000 + scenario.phase * refresh
        var previous = -Double.infinity
        var skip = 0
        for n in 0..<count {
            let nominal = base + Double(n) * period
            var t = nominal + sigma * random.gaussian()
            if let link = scenario.link {
                let host = min(link.hostMaxMs, link.hostMinMs + exponential(&random, mean: link.hostExtraMeanMs))
                t = nominal + (host + link.networkSigmaMs * random.gaussian()) / 1000
                if random.uniform() < link.outlierChance {
                    t += (link.outlierMinMs + random.uniform() * (link.outlierMaxMs - link.outlierMinMs)) / 1000
                }
                if skip == 0, random.uniform() < link.pauseChance {
                    skip = 2 + Int(random.uniform() * Double(max(1, link.pauseFramesMax - 1)))
                }
                if skip == 0, random.uniform() < link.lossChance {
                    skip = 1
                    number += 1
                }
                if skip > 0, n > 2 {
                    skip -= 1
                    continue
                }
                skip = 0
            }
            while nominal > burstStart + scenario.burstSeconds {
                burstStart += scenario.burstSeconds + exponential(&random, mean: scenario.burstEverySeconds)
            }
            if nominal >= burstStart {
                t += random.uniform() * scenario.burstDelayMs / 1000
            }
            t = max(t, previous + 0.0002)
            previous = t
            times.append(t)
            numbers.append(number)
            number += 1
        }
        if scenario.startupPair, times.count > 1 {
            times[0] = times[1] - 0.001
        }
        return (times, numbers)
    }

    private static func exponential(_ random: inout SimRandom, mean: Double) -> Double {
        -mean * log(max(random.uniform(), 1e-12))
    }

    /// Drives a pacer the way DisplayPacer does: frames are put at their arrival time (direct
    /// present hands them to the renderer right there), and every refresh reports its vsync and
    /// ticks `tickDelayMs` later. A frame the renderer has `latchMs` before vsync k is shown at
    /// vsync k; of several, only the newest. The first `warmupSeconds` are not measured.
    static func run(_ scenario: PacerScenario, mode: FramePacingMode, directPresent: Bool = true,
                    warmupSeconds: Double = 2, trace: PacerTraceRecorder? = nil,
                    configure: (FramePacer<Int>) -> Void = { _ in }) -> PacerSimResult {
        let clock = SimClock()
        let pacer = FramePacer<Int>(mode: mode, frameRate: Int(scenario.fps.rounded()),
                                    directPresent: directPresent, trace: trace, clock: { clock.now })
        configure(pacer)
        let renderer = SimRenderer()
        if directPresent {
            pacer.setPresenter { [renderer, clock] frame in renderer.enqueued.append((frame, clock.now)) }
        }
        let start = 1.0
        let refresh = 1 / scenario.refreshHz
        let tickDelay = scenario.tickDelayMs / 1000
        let latch = scenario.latchMs / 1000
        let (times, numbers) = frames(scenario, start: start)
        let vsyncCount = Int(scenario.seconds * scenario.refreshHz)
        var next = 0
        var shownAt = [Int](repeating: -1, count: times.count)
        var consumed = 0
        var lastShown = -1
        let measureFrom = start + warmupSeconds
        var result = PacerSimResult(scenario: scenario.name, minutes: (scenario.seconds - warmupSeconds) / 60)
        result.lostFrames = Int(scenario.seconds * scenario.fps) - times.count
        var atMeasureStart: PacerStats?
        for k in 0..<vsyncCount {
            let vsync = start + Double(k) * refresh
            if atMeasureStart == nil, vsync >= measureFrom { atMeasureStart = pacer.stats }
            let tick = vsync + tickDelay
            func putArrivals(before time: Double) {
                while next < times.count, times[next] < time {
                    clock.now = times[next]
                    pacer.put(next, arrival: times[next], frameNumber: numbers[next])
                    next += 1
                }
            }
            putArrivals(before: vsync)
            // The vsync: the newest frame the renderer had by its latch goes on screen.
            var newest: Int?
            while consumed < renderer.enqueued.count, renderer.enqueued[consumed].time < vsync - latch {
                newest = renderer.enqueued[consumed].frame
                consumed += 1
            }
            if let newest {
                shownAt[newest] = k
                lastShown = newest
            } else if vsync >= measureFrom, lastShown >= 0 {
                result.repeats += 1
            }
            putArrivals(before: tick)
            clock.now = tick
            pacer.vsync(timestamp: vsync, duration: refresh, tickTime: tick)
            if let frame = pacer.tick() {
                renderer.enqueued.append((frame, tick))
            }
        }
        let lastVsync = start + Double(vsyncCount - 1) * refresh
        var latencySum = 0.0
        var lagging = 0
        for (frame, arrival) in times.enumerated() where arrival >= measureFrom && arrival < lastVsync - 2 * refresh {
            let k = shownAt[frame]
            guard k >= 0 else {
                result.drops += 1
                continue
            }
            let shown = start + Double(k) * refresh
            latencySum += shown - arrival
            let earliest = Int(((arrival + latch - start) / refresh).rounded(.down)) + 1
            if k > earliest { lagging += 1 }
            result.shown += 1
        }
        result.meanLatencyMs = result.shown > 0 ? latencySum / Double(result.shown) * 1000 : 0
        result.laggingShare = result.shown > 0 ? Double(lagging) / Double(result.shown) : 0
        result.stats = span(pacer.stats, since: atMeasureStart ?? PacerStats())
        pacer.finishTrace()
        return result
    }

    private static func span(_ end: PacerStats, since start: PacerStats) -> PacerStats {
        var stats = end
        stats.presented -= start.presented
        stats.stalls -= start.stalls
        stats.overflowDrops -= start.overflowDrops
        stats.catchUpDrops -= start.catchUpDrops
        stats.directPresents -= start.directPresents
        stats.laggingPresents -= start.laggingPresents
        stats.displayWaitTotalMilliseconds -= start.displayWaitTotalMilliseconds
        stats.displayWaitSamples -= start.displayWaitSamples
        return stats
    }

    /// Wi-Fi through a repeater (`LinkProfile`), as in the split device run: a dynamic stream
    /// (Steam, 60.02 fps when drifting) and a static one (desktop, rare lost frames and pauses,
    /// 60.01 when drifting), each at the phases that decide the pacer's behaviour. Phase is where
    /// the host captures relative to the tick; host processing (mean 4.4 ms) comes on top, so
    /// "mid" arrives about 3 ms before the vsync.
    static func repeaterScenarios(seconds: Double = 600, seed: UInt64 = 1, outlierChance: Double = 0.002) -> [PacerScenario] {
        let interval = 1000 / 60.0
        var dynamic = LinkProfile()
        dynamic.outlierChance = outlierChance
        var still = dynamic
        still.lossChance = 0.0002
        still.pauseChance = 0.0003
        let shapes: [(String, Double, Double)] = [
            ("mid", 60, 0.5), ("tick-1ms", 60, 1 - 1 / interval), ("tick", 60, 0), ("tick+1ms", 60, 1 / interval),
            ("tick+3ms", 60, 3 / interval),
        ]
        return [("dyn", dynamic, 60.02), ("static", still, 60.01)].flatMap { label, link, drift in
            (shapes + [("drift \(drift)", drift, 0.5)]).map { name, fps, phase in
                var scenario = PacerScenario(name: "\(label) \(name)", fps: fps, phase: phase, seconds: seconds, seed: seed)
                scenario.link = link
                return scenario
            }
        }
    }

    /// A clean wired stream close to the tick (jitter stat about 1.3 ms) with rare large outliers
    /// (8 to 30 ms, 0.04 % of frames): the case where keeping the lag (round 1) is cleaner and
    /// cutting it (round 2) is faster. Host processing adds about 2.8 ms to the capture phase, so
    /// "tick-3ms" arrives just before the tick and "tick" about 3 ms after it.
    static func wiredScenarios(seconds: Double = 600, seed: UInt64 = 1) -> [PacerScenario] {
        let interval = 1000 / 60.0
        var link = LinkProfile()
        link.hostExtraMeanMs = 0.6
        link.networkSigmaMs = 0.6
        link.outlierChance = 0.0004
        return [("tick-3ms", 1 - 3 / interval), ("tick-2ms", 1 - 2 / interval), ("tick", 0.0)].map { name, phase in
            var scenario = PacerScenario(name: "wired \(name)", phase: phase, seconds: seconds, seed: seed)
            scenario.link = link
            return scenario
        }
    }

    /// The scenario set the pacer is judged on: phase mid-interval, at the tick (just before,
    /// on, just after), and drifting through every phase (stream faster and slower than the
    /// display), each with 2 ms jitter and with Wi-Fi bursts.
    static func scenarios(seconds: Double = 600, seed: UInt64 = 1) -> [PacerScenario] {
        let interval = 1000 / 60.0
        let shapes: [(String, Double, Double)] = [
            ("mid", 60, 0.5),
            ("tick-1ms", 60, 1 - 1 / interval),
            ("tick", 60, 0),
            ("tick+1ms", 60, 1 / interval),
            ("drift 60.05", 60.05, 0.5),
            ("drift 59.95", 59.95, 0.5),
        ]
        return shapes.flatMap { name, fps, phase in
            [false, true].map { bursts in
                PacerScenario(name: name + (bursts ? " burst" : " 2ms"), fps: fps, phase: phase, bursts: bursts,
                              seconds: seconds, seed: seed)
            }
        }
    }
}
