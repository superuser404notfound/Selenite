import StreamKit

/// Host processing latency over the window: mean, min and max, all milliseconds.
public struct HostLatency: Equatable, Sendable {
    public var mean: Double
    public var min: Double
    public var max: Double

    public init(mean: Double, min: Double, max: Double) {
        self.mean = mean
        self.min = min
        self.max = max
    }
}

/// One overlay refresh: `current` against the sample one second earlier. Counters are totals since
/// the stream started, frames per second is the delta of presented frames over the real elapsed
/// interval. The window fields (`networkMilliseconds`, `displayMilliseconds`, `hostLatency`) average
/// just the samples that arrived since `previous`, falling back to the running totals of `current`
/// when there is none. `displayHz` and `streamFps` read the pacer's running means directly, so they
/// need no `previous` sample.
public struct StreamStatsSummary: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateMbps: Int
    public var measuredBitrateMbps: Double
    public var codec: VideoCodec
    public var rttMilliseconds: Int?
    public var decodeMilliseconds: Double
    public var networkDrops: Int
    public var queueDrops: Int
    public var unrecoverableFrames: Int
    public var pacerDrops: Int
    public var stalls: Int
    public var audioUnderruns: Int
    public var hostLatency: HostLatency?
    public var networkMilliseconds: Double?
    public var displayMilliseconds: Double?
    public var rttVarianceMilliseconds: Int?
    public var jitterMilliseconds: Double
    public var displayHz: Double?
    public var streamFps: Double?

    /// `previous` is nil for the first sample, which reports 0 fps.
    public init(current: StreamStats, previous: StreamStats?, settings: StreamSettings) {
        width = settings.width
        height = settings.height
        fps = Self.fps(current: current, previous: previous)
        bitrateMbps = settings.bitrateKbps / 1000
        measuredBitrateMbps = Self.measuredBitrateMbps(current: current, previous: previous)
        codec = settings.codec
        rttMilliseconds = current.rttMilliseconds.map { Int($0) }
        decodeMilliseconds = current.averageDecodeMilliseconds
        networkDrops = current.networkDroppedFrames
        queueDrops = current.queueDroppedFrames
        unrecoverableFrames = current.unrecoverableFrames
        pacerDrops = current.pacer.overflowDrops + current.pacer.catchUpDrops
        stalls = current.pacer.stalls
        audioUnderruns = current.audio?.underruns ?? 0
        hostLatency = Self.hostLatency(current: current, previous: previous)
        networkMilliseconds = Self.networkMilliseconds(current: current, previous: previous)
        displayMilliseconds = Self.displayMilliseconds(current: current, previous: previous)
        rttVarianceMilliseconds = current.rttVarianceMilliseconds.map { Int($0) }
        jitterMilliseconds = current.pacer.jitterMilliseconds
        displayHz = Self.rate(fromIntervalMilliseconds: current.pacer.vsyncIntervalMilliseconds)
        streamFps = Self.rate(fromIntervalMilliseconds: current.pacer.arrivalIntervalMilliseconds)
    }

    /// The presented-frame delta over the real elapsed interval, rounded to the nearest fps. A
    /// sample taken without a clock (both `sampledAt` still 0, as in tests built without it) falls
    /// back to the raw delta, which assumed a 1 s sample.
    private static func fps(current: StreamStats, previous: StreamStats?) -> Int {
        guard let previous else { return 0 }
        let delta = current.pacer.presented - previous.pacer.presented
        guard delta >= 0 else { return 0 }
        if current.sampledAt == 0, previous.sampledAt == 0 {
            return delta
        }
        let interval = current.sampledAt - previous.sampledAt
        guard interval > 0 else { return 0 }
        return Int((Double(delta) / interval).rounded())
    }

    private static func rate(fromIntervalMilliseconds interval: Double) -> Double? {
        guard interval > 0 else { return nil }
        return 1000 / interval
    }

    private static func measuredBitrateMbps(current: StreamStats, previous: StreamStats?) -> Double {
        guard let previous else { return 0 }
        let interval = current.sampledAt - previous.sampledAt
        guard interval > 0 else { return 0 }
        let deltaBytes = Double(current.receivedBytes - previous.receivedBytes)
        return deltaBytes * 8 / interval / 1_000_000
    }

    private static func hostLatency(current: StreamStats, previous: StreamStats?) -> HostLatency? {
        guard let range = current.hostLatencyRange else { return nil }
        let deltaTotal: Int
        let deltaSamples: Int
        if let previous {
            deltaTotal = current.hostLatencyTotalTenths - previous.hostLatencyTotalTenths
            deltaSamples = current.hostLatencySamples - previous.hostLatencySamples
        } else {
            deltaTotal = current.hostLatencyTotalTenths
            deltaSamples = current.hostLatencySamples
        }
        // A negative delta means the counter went backwards (a new session's stats read against a
        // stale `previous`): no window data, not a negative mean.
        guard deltaTotal >= 0, deltaSamples > 0 else { return nil }
        let mean = Double(deltaTotal) / Double(deltaSamples) / 10
        return HostLatency(mean: mean, min: range.lowerBound, max: range.upperBound)
    }

    private static func networkMilliseconds(current: StreamStats, previous: StreamStats?) -> Double? {
        let deltaTotal: Double
        let deltaSamples: Int
        if let previous {
            // Both UInt64; subtract as Double first so a counter that went backwards produces a
            // negative delta instead of trapping.
            deltaTotal = Double(current.networkReceiveTotalMicroseconds) - Double(previous.networkReceiveTotalMicroseconds)
            deltaSamples = current.networkReceiveSamples - previous.networkReceiveSamples
        } else {
            deltaTotal = Double(current.networkReceiveTotalMicroseconds)
            deltaSamples = current.networkReceiveSamples
        }
        guard deltaTotal >= 0, deltaSamples > 0 else { return nil }
        return deltaTotal / Double(deltaSamples) / 1000
    }

    private static func displayMilliseconds(current: StreamStats, previous: StreamStats?) -> Double? {
        let deltaTotal: Double
        let deltaSamples: Int
        if let previous {
            deltaTotal = current.pacer.displayWaitTotalMilliseconds - previous.pacer.displayWaitTotalMilliseconds
            deltaSamples = current.pacer.displayWaitSamples - previous.pacer.displayWaitSamples
        } else {
            deltaTotal = current.pacer.displayWaitTotalMilliseconds
            deltaSamples = current.pacer.displayWaitSamples
        }
        guard deltaTotal >= 0, deltaSamples > 0 else { return nil }
        return deltaTotal / Double(deltaSamples)
    }
}
