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
    var stats = PacerStats()

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
        var random = SimRandom(seed: scenario.seed)
        let period = 1 / scenario.fps
        let refresh = 1 / scenario.refreshHz
        let sigma = scenario.jitterMs / 2.squareRoot() / 1000
        let count = Int(scenario.seconds * scenario.fps)
        var burstStart = scenario.bursts ? start + exponential(&random, mean: scenario.burstEverySeconds) : .infinity
        var times: [Double] = []
        times.reserveCapacity(count + 1)
        let base = start + scenario.tickDelayMs / 1000 + scenario.phase * refresh
        var previous = -Double.infinity
        for n in 0..<count {
            let nominal = base + Double(n) * period
            var t = nominal + sigma * random.gaussian()
            while nominal > burstStart + scenario.burstSeconds {
                burstStart += scenario.burstSeconds + exponential(&random, mean: scenario.burstEverySeconds)
            }
            if nominal >= burstStart {
                t += random.uniform() * scenario.burstDelayMs / 1000
            }
            t = max(t, previous + 0.0002)
            previous = t
            times.append(t)
        }
        if scenario.startupPair, times.count > 1 {
            times[0] = times[1] - 0.001
        }
        return times
    }

    private static func exponential(_ random: inout SimRandom, mean: Double) -> Double {
        -mean * log(max(random.uniform(), 1e-12))
    }

    /// Drives a pacer the way DisplayPacer does: frames are put at their arrival time (direct
    /// present hands them to the renderer right there), and every refresh reports its vsync and
    /// ticks `tickDelayMs` later. A frame the renderer has `latchMs` before vsync k is shown at
    /// vsync k; of several, only the newest. The first `warmupSeconds` are not measured.
    static func run(_ scenario: PacerScenario, mode: FramePacingMode, directPresent: Bool = true,
                    warmupSeconds: Double = 2, configure: (FramePacer<Int>) -> Void = { _ in }) -> PacerSimResult {
        let clock = SimClock()
        let pacer = FramePacer<Int>(mode: mode, frameRate: Int(scenario.fps.rounded()),
                                    directPresent: directPresent, clock: { clock.now })
        configure(pacer)
        let renderer = SimRenderer()
        if directPresent {
            pacer.setPresenter { [renderer, clock] frame in renderer.enqueued.append((frame, clock.now)) }
        }
        let start = 1.0
        let refresh = 1 / scenario.refreshHz
        let tickDelay = scenario.tickDelayMs / 1000
        let latch = scenario.latchMs / 1000
        let times = arrivals(scenario, start: start)
        let vsyncCount = Int(scenario.seconds * scenario.refreshHz)
        var next = 0
        var shownAt = [Int](repeating: -1, count: times.count)
        var consumed = 0
        var lastShown = -1
        let measureFrom = start + warmupSeconds
        var result = PacerSimResult(scenario: scenario.name, minutes: (scenario.seconds - warmupSeconds) / 60)
        for k in 0..<vsyncCount {
            let vsync = start + Double(k) * refresh
            let tick = vsync + tickDelay
            func putArrivals(before time: Double) {
                while next < times.count, times[next] < time {
                    clock.now = times[next]
                    pacer.put(next, arrival: times[next])
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
        result.stats = pacer.stats
        return result
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
