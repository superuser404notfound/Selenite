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
    // Host latency keeps a rolling 1-second-bucket pair (current + previous) instead of draining
    // on read, so a caller that polls stats() without pacing (e.g. the first-frame wait loop)
    // doesn't erase the window before anyone sees it.
    private var currentBucket: UInt64?
    private var currentMinTenths: UInt16?
    private var currentMaxTenths: UInt16?
    private var previousMinTenths: UInt16?
    private var previousMaxTenths: UInt16?

    /// `overflowsSoFar` is the slot's decode-queue overflow count since this session started: the
    /// first gap after a new overflow is the frames moonlight-common-c flushed on the client.
    mutating func receive(frameNumber: Int32, bytes: Int, hostLatencyTenths: UInt16,
                          receiveMicroseconds: UInt64, enqueueMicroseconds: UInt64, overflowsSoFar: Int) {
        if lastFrameNumber != 0, frameNumber > lastFrameNumber + 1 {
            let missing = Int(frameNumber - lastFrameNumber - 1)
            if overflowsSoFar > overflowsAttributed {
                queueDrops += missing
                overflowsAttributed = overflowsSoFar
            } else {
                networkDrops += missing
            }
        }
        lastFrameNumber = frameNumber
        self.bytes += bytes
        if hostLatencyTenths > 0 {
            hostLatencyTotalTenths += Int(hostLatencyTenths)
            hostLatencySamples += 1
            // A frame with no receive timestamp joins whatever bucket is already current.
            let bucket = receiveMicroseconds > 0 ? receiveMicroseconds / 1_000_000 : (currentBucket ?? 0)
            if let current = currentBucket, bucket > current {
                if bucket == current + 1 {
                    previousMinTenths = currentMinTenths
                    previousMaxTenths = currentMaxTenths
                } else {
                    previousMinTenths = nil
                    previousMaxTenths = nil
                }
                currentBucket = bucket
                currentMinTenths = hostLatencyTenths
                currentMaxTenths = hostLatencyTenths
            } else if currentBucket == nil {
                currentBucket = bucket
                currentMinTenths = hostLatencyTenths
                currentMaxTenths = hostLatencyTenths
            } else {
                currentMinTenths = min(currentMinTenths ?? hostLatencyTenths, hostLatencyTenths)
                currentMaxTenths = max(currentMaxTenths ?? hostLatencyTenths, hostLatencyTenths)
            }
        }
        if receiveMicroseconds > 0, enqueueMicroseconds >= receiveMicroseconds {
            receiveTotalMicroseconds += enqueueMicroseconds - receiveMicroseconds
            receiveSamples += 1
        }
    }

    /// The host latency range over the current and previous 1-second bucket, in milliseconds; nil
    /// when neither bucket has a sample. Reading this never mutates the buckets.
    var hostLatencyRange: ClosedRange<Double>? {
        var low: UInt16?
        var high: UInt16?
        if let currentMinTenths, let currentMaxTenths {
            low = currentMinTenths
            high = currentMaxTenths
        }
        if let previousMinTenths, let previousMaxTenths {
            low = min(low ?? previousMinTenths, previousMinTenths)
            high = max(high ?? previousMaxTenths, previousMaxTenths)
        }
        guard let low, let high else { return nil }
        return Double(low) / 10...Double(high) / 10
    }
}
