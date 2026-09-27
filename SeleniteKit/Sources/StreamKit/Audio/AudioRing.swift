import Foundation
import Synchronization

public struct AudioRingStats: Sendable, Equatable {
    public var underruns = 0
    public var catchUps = 0
    public var overflows = 0
    public var fillMilliseconds: Double = 0

    /// Public so AppCore's tests can build stats; `AudioRing.stats` keeps using every argument.
    public init(underruns: Int = 0, catchUps: Int = 0, overflows: Int = 0, fillMilliseconds: Double = 0) {
        self.underruns = underruns
        self.catchUps = catchUps
        self.overflows = overflows
        self.fillMilliseconds = fillMilliseconds
    }
}

/// Lock-free single-producer single-consumer ring of interleaved Float32 frames between
/// moonlight's audio thread (writer) and the audio render thread (reader). The reader owns
/// priming, catch-up and underrun handling, so the writer never touches the read side.
public final class AudioRing: @unchecked Sendable {
    public let channels: Int
    private let sampleRate: Int
    private let capacity: Int
    private let target: Int
    private let maximum: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let underruns = Atomic<Int>(0)
    private let catchUps = Atomic<Int>(0)
    private let overflows = Atomic<Int>(0)
    private var primed = false   // reader-owned

    public init(channels: Int, sampleRate: Int = 48000, targetMilliseconds: Int = 30,
                maxMilliseconds: Int = 80, capacityMilliseconds: Int = 250) {
        self.channels = channels
        self.sampleRate = sampleRate
        capacity = sampleRate * capacityMilliseconds / 1000
        target = sampleRate * targetMilliseconds / 1000
        maximum = sampleRate * maxMilliseconds / 1000
        storage = .allocate(capacity: capacity * channels)
        storage.initialize(repeating: 0, count: capacity * channels)
    }

    deinit { storage.deallocate() }

    public func write(_ samples: UnsafePointer<Float>, frames: Int) {
        let w = written.load(ordering: .relaxed)
        let free = capacity - (w - consumed.load(ordering: .acquiring))
        let count = min(frames, free)
        if count < frames { overflows.add(1, ordering: .relaxed) }
        for i in 0..<count {
            let slot = (w + i) % capacity
            (storage + slot * channels).update(from: samples + i * channels, count: channels)
        }
        written.store(w + count, ordering: .releasing)
    }

    public func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        var r = consumed.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        var available = w - r
        if !primed {
            // A render quantum can exceed the target (tvOS may ignore the preferred IO buffer
            // duration), so priming on `target` alone would underrun on every read once the
            // quantum is larger than it.
            guard available >= max(target, frames) else {
                out.initialize(repeating: 0, count: frames * channels)
                return
            }
            primed = true
        }
        if available > maximum {
            // Same reasoning as priming: skipping ahead to exactly `target` underruns on the very
            // next read once the render quantum is larger than the target. Capping at `available`
            // keeps the read index from ever moving backwards: when this read alone drains at
            // least as much as is buffered, there is nothing to catch up on.
            let resume = min(available, max(target, frames))
            if resume < available {
                r = w - resume
                available = resume
                catchUps.add(1, ordering: .relaxed)
            }
        }
        let count = min(frames, available)
        for i in 0..<count {
            let slot = (r + i) % capacity
            (out + i * channels).update(from: storage + slot * channels, count: channels)
        }
        if count < frames {
            (out + count * channels).initialize(repeating: 0, count: (frames - count) * channels)
            underruns.add(1, ordering: .relaxed)
            primed = false
        }
        consumed.store(r + count, ordering: .releasing)
    }

    public var stats: AudioRingStats {
        let fill = written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring)
        return AudioRingStats(underruns: underruns.load(ordering: .relaxed),
                              catchUps: catchUps.load(ordering: .relaxed),
                              overflows: overflows.load(ordering: .relaxed),
                              fillMilliseconds: max(0, Double(fill) * 1000 / Double(sampleRate)))
    }
}
