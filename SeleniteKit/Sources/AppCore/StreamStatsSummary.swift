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
/// the stream started, frames per second is the difference of presented frames. The window fields
/// (`networkMilliseconds`, `displayMilliseconds`, `hostLatency`) average just the samples that
/// arrived since `previous`, falling back to the running totals of `current` when there is none.
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

    /// `previous` is nil for the first sample, which reports 0 fps.
    public init(current: StreamStats, previous: StreamStats?, settings: StreamSettings) {
        width = settings.width
        height = settings.height
        fps = previous.map { max(0, current.pacer.presented - $0.pacer.presented) } ?? 0
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
        guard deltaSamples > 0 else { return nil }
        let mean = Double(deltaTotal) / Double(deltaSamples)
        return HostLatency(mean: mean, min: range.lowerBound, max: range.upperBound)
    }

    private static func networkMilliseconds(current: StreamStats, previous: StreamStats?) -> Double? {
        let deltaTotal: Double
        let deltaSamples: Int
        if let previous {
            deltaTotal = Double(current.networkReceiveTotalMicroseconds - previous.networkReceiveTotalMicroseconds)
            deltaSamples = current.networkReceiveSamples - previous.networkReceiveSamples
        } else {
            deltaTotal = Double(current.networkReceiveTotalMicroseconds)
            deltaSamples = current.networkReceiveSamples
        }
        guard deltaSamples > 0 else { return nil }
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
        guard deltaSamples > 0 else { return nil }
        return deltaTotal / Double(deltaSamples)
    }
}
