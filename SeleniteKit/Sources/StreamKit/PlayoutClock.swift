import Foundation

/// smooth: when each frame is expected on the host's cadence, and how far behind that a frame is
/// scheduled before any stretch (`baseDelay`).
///
/// The expected time advances by the frame period per frame number from the previous frame. It
/// follows the early edge of the arrivals: an arrival before its expected time moves the clock to
/// it at once, and every `envelopeEvery` arrivals the clock moves later by the
/// `envelopeQuantile` of the lateness of the latest `envelopeFrames` frames when that exceeds
/// `envelopeMinimumShift`. A lone early frame therefore sets the clock only until the low quantile
/// catches up, and a host slower than the measured period cannot leave the clock behind for long.
/// The clock starts over at the arrival after an outage (a gap of `outageGap` from the expected
/// time) and when the frame numbers jump by more than `outageFrames` or run backwards.
struct PlayoutClock {
    static var outageGap: Double { 0.4 }
    static var outageFrames: Int { 30 }
    static var envelopeFrames: Int { 120 }
    static var envelopeEvery: Int { 60 }
    static var envelopeQuantile: Double { 0.05 }
    static var envelopeMinimumShift: Double { 0.0005 }
    /// The base delay is this quantile of the lateness over `latenessWindow` seconds plus
    /// `baseMargin`, at most `baseCap`, and `baseCap` until `minimumSamples` are in.
    static var baseQuantile: Double { 0.995 }
    static var baseMargin: Double { 0.001 }
    static var baseCap: Double { 0.008 }
    static var latenessWindow: Double { 60 }
    static var minimumSamples: Int { 30 }

    private var expected: Double?
    private var lastNumber: Int?
    private var recent: [Double] = []
    private var arrivalsSinceShift = 0
    private var lateness = LatenessHistogram(window: latenessWindow, slices: 6, bin: 0.00025, bins: 201)

    /// The expected time of the frame that arrived at `arrival`, seconds, and whether the clock
    /// started over with it. `period` is the current frame period.
    mutating func expect(arrival: Double, frameNumber: Int?, period: Double) -> (time: Double, restarted: Bool) {
        defer { lastNumber = frameNumber ?? lastNumber.map { $0 + 1 } }
        var steps = 1
        var restart = expected == nil
        if let frameNumber, let lastNumber {
            steps = frameNumber - lastNumber
            if steps <= 0 || steps > Self.outageFrames { restart = true }
        }
        var time = (expected ?? arrival) + period * Double(max(1, steps))
        if restart || abs(arrival - time) > Self.outageGap {
            expected = arrival
            recent.removeAll()
            arrivalsSinceShift = 0
            return (arrival, true)
        }
        var late = arrival - time
        if late < 0 {
            time = arrival
            recent = recent.map { $0 - late }
            late = 0
        }
        recent.append(late)
        if recent.count > Self.envelopeFrames { recent.removeFirst(recent.count - Self.envelopeFrames) }
        arrivalsSinceShift += 1
        if arrivalsSinceShift >= Self.envelopeEvery, recent.count >= Self.envelopeEvery {
            arrivalsSinceShift = 0
            let low = recent.sorted()[Int(Double(recent.count) * Self.envelopeQuantile)]
            if low > Self.envelopeMinimumShift {
                time += low
                late -= low
                recent = recent.map { $0 - low }
            }
        }
        lateness.add(late, at: arrival)
        expected = time
        return (time, false)
    }

    /// How far behind its expected time a frame is due before any stretch, seconds.
    var baseDelay: Double {
        guard lateness.total >= Self.minimumSamples else { return Self.baseCap }
        return min(Self.baseCap, lateness.quantile(Self.baseQuantile) + Self.baseMargin)
    }
}
