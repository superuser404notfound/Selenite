import Foundation

public struct PacerStats: Sendable, Equatable {
    public var presented = 0
    /// Ticks with nothing to show: the stutter metric.
    public var stalls = 0
    /// A third frame arrived while two were buffered; the oldest was discarded.
    public var overflowDrops = 0
    /// A standing one-frame lag was cut by skipping to the newest frame.
    public var catchUpDrops = 0
    /// Ticks that presented a frame while another waited: one frame of latency paid.
    public var bufferedTicks = 0
    /// Sample standard deviation of frame inter-arrival time.
    public var jitterMilliseconds: Double = 0

    public init() {}
}

/// Hand-off between the decoder and the vsync tick. Keeps at most two frames in arrival order, so
/// frames that arrive bunched inside one refresh are shown on consecutive ticks instead of dropped,
/// and cuts a lag that stands for `catchUpTicks` ticks so latency cannot creep.
public final class FramePacer<Frame>: @unchecked Sendable {
    public static var capacity: Int { 2 }

    private let catchUpTicks: Int
    private let lock = NSLock()
    private var queue: [Frame] = []
    private var backlogTicks = 0
    private var counters = PacerStats()
    private var lastArrival: Double?
    private var intervalCount = 0
    private var intervalMean = 0.0
    private var intervalM2 = 0.0

    public init(catchUpTicks: Int = 3) {
        self.catchUpTicks = catchUpTicks
        queue.reserveCapacity(Self.capacity + 1)
    }

    public func put(_ frame: Frame, arrival: Double) {
        lock.withLock {
            if let last = lastArrival {
                let interval = (arrival - last) * 1000
                intervalCount += 1
                let delta = interval - intervalMean
                intervalMean += delta / Double(intervalCount)
                intervalM2 += delta * (interval - intervalMean)
            }
            lastArrival = arrival
            if queue.count == Self.capacity {
                queue.removeFirst()
                counters.overflowDrops += 1
            }
            queue.append(frame)
        }
    }

    public func tick() -> Frame? {
        lock.withLock {
            guard !queue.isEmpty else {
                counters.stalls += 1
                backlogTicks = 0
                return nil
            }
            var frame = queue.removeFirst()
            if queue.isEmpty {
                backlogTicks = 0
            } else {
                backlogTicks += 1
                if backlogTicks >= catchUpTicks {
                    frame = queue.removeFirst()
                    counters.catchUpDrops += 1
                    backlogTicks = 0
                } else {
                    counters.bufferedTicks += 1
                }
            }
            counters.presented += 1
            return frame
        }
    }

    public var stats: PacerStats {
        lock.withLock {
            var snapshot = counters
            snapshot.jitterMilliseconds = intervalCount > 1 ? (intervalM2 / Double(intervalCount - 1)).squareRoot() : 0
            return snapshot
        }
    }
}
