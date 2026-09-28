import StreamKit

/// One overlay refresh: `current` against the sample one second earlier. Counters are totals since
/// the stream started, frames per second is the difference of presented frames.
public struct StreamStatsSummary: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateMbps: Int
    public var rttMilliseconds: Int?
    public var decodeMilliseconds: Double
    public var networkDrops: Int
    public var pacerDrops: Int
    public var stalls: Int
    public var audioUnderruns: Int

    /// `previous` is nil for the first sample, which reports 0 fps.
    public init(current: StreamStats, previous: StreamStats?, settings: StreamSettings) {
        width = settings.width
        height = settings.height
        fps = previous.map { max(0, current.pacer.presented - $0.pacer.presented) } ?? 0
        bitrateMbps = settings.bitrateKbps / 1000
        rttMilliseconds = current.rttMilliseconds.map { Int($0) }
        decodeMilliseconds = current.averageDecodeMilliseconds
        networkDrops = current.networkDroppedFrames
        pacerDrops = current.pacer.overflowDrops + current.pacer.catchUpDrops
        stalls = current.pacer.stalls
        audioUnderruns = current.audio?.underruns ?? 0
    }
}
