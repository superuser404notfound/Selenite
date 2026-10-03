/// What one slot's decode units say about the network (M3-A spec, section 4). Not thread-safe;
/// `VideoPipeline` owns one and guards it with its lock.
struct FrameIntake {
    private(set) var bytes = 0
    private(set) var networkDrops = 0
    private(set) var queueDrops = 0
    private(set) var hostLatencyTotalTenths = 0
    private(set) var hostLatencySamples = 0
    private(set) var receiveTotalMicroseconds: UInt64 = 0
    private(set) var receiveSamples = 0
    private var lastFrameNumber: Int32 = 0
    private var overflowsAttributed = 0
    private var windowMinTenths: UInt16?
    private var windowMaxTenths: UInt16?

    /// `overflowsSoFar` is the slot's decode-queue overflow count since this session started: the
    /// first gap after a new overflow is the frames moonlight-common-c flushed on the client.
    mutating func receive(frameNumber: Int32, bytes: Int, hostLatencyTenths: UInt16,
                          receiveMicroseconds: UInt64, enqueueMicroseconds: UInt64, overflowsSoFar: Int) {
        if lastFrameNumber != 0, frameNumber > lastFrameNumber + 1 {
            let missing = Int(frameNumber - lastFrameNumber - 1)
            if overflowsSoFar > overflowsAttributed {
                queueDrops += missing
            } else {
                networkDrops += missing
            }
        }
        overflowsAttributed = overflowsSoFar
        lastFrameNumber = frameNumber
        self.bytes += bytes
        if hostLatencyTenths > 0 {
            hostLatencyTotalTenths += Int(hostLatencyTenths)
            hostLatencySamples += 1
            windowMinTenths = min(windowMinTenths ?? hostLatencyTenths, hostLatencyTenths)
            windowMaxTenths = max(windowMaxTenths ?? hostLatencyTenths, hostLatencyTenths)
        }
        if receiveMicroseconds > 0, enqueueMicroseconds >= receiveMicroseconds {
            receiveTotalMicroseconds += enqueueMicroseconds - receiveMicroseconds
            receiveSamples += 1
        }
    }

    /// The host latency range since the last call, in milliseconds; nil when the host sent none.
    mutating func takeHostLatencyRange() -> ClosedRange<Double>? {
        defer { windowMinTenths = nil; windowMaxTenths = nil }
        guard let low = windowMinTenths, let high = windowMaxTenths else { return nil }
        return Double(low) / 10...Double(high) / 10
    }
}
