import Testing
@testable import StreamKit

private func write(_ ring: AudioRing, frames: Int, value: Float) {
    let samples = [Float](repeating: value, count: frames * ring.channels)
    samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) }
}

private func read(_ ring: AudioRing, frames: Int) -> [Float] {
    var out = [Float](repeating: -1, count: frames * ring.channels)
    out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: frames) }
    return out
}

@Test func primesToTargetBeforePlaying() {
    let ring = AudioRing(channels: 2)
    write(ring, frames: 480, value: 0.5)              // 10 ms, below the 30 ms target
    #expect(read(ring, frames: 240).allSatisfy { $0 == 0 })
    write(ring, frames: 960, value: 0.5)              // now 30 ms buffered
    #expect(read(ring, frames: 240).allSatisfy { $0 == 0.5 })
}

@Test func underrunFillsSilenceAndCounts() {
    let ring = AudioRing(channels: 2)
    write(ring, frames: 1440, value: 0.25)            // 30 ms, primed on next read
    _ = read(ring, frames: 1200)
    let tail = read(ring, frames: 480)                // only 240 left
    #expect(tail.prefix(480).allSatisfy { $0 == 0.25 })
    #expect(tail.suffix(480).allSatisfy { $0 == 0 })
    #expect(ring.stats.underruns == 1)
}

@Test func catchUpCapsLatency() {
    let ring = AudioRing(channels: 1)
    write(ring, frames: 4800, value: 1)               // 100 ms, above the 80 ms cap
    _ = read(ring, frames: 48)
    #expect(ring.stats.catchUps == 1)
    #expect(abs(ring.stats.fillMilliseconds - 29) < 1.5)
}

@Test func overflowDropsNewestWhenReaderStalls() {
    let ring = AudioRing(channels: 1, capacityMilliseconds: 50)
    write(ring, frames: 4800, value: 1)               // 100 ms into a 50 ms ring
    #expect(ring.stats.overflows == 1)
    #expect(abs(ring.stats.fillMilliseconds - 50) < 1)
}

@Test func catchUpSkipsToMaxOfTargetAndFrames() {
    let ring = AudioRing(channels: 1)
    write(ring, frames: 4800, value: 1)               // 100 ms, above the 80 ms cap
    let out = read(ring, frames: 2048)                // quantum above the 30 ms target
    #expect(ring.stats.catchUps == 1)
    #expect(ring.stats.underruns == 0)
    #expect(out.allSatisfy { $0 == 1 })
}

@Test func primingUsesMaxOfTargetAndFrames() {
    let ring = AudioRing(channels: 2)
    // 1600 frames clears the 30 ms (1440-frame) target but not a 2048-frame render quantum.
    write(ring, frames: 1600, value: 0.5)
    let first = read(ring, frames: 2048)
    #expect(first.allSatisfy { $0 == 0 })
    #expect(ring.stats.underruns == 0)
    write(ring, frames: 600, value: 0.5)              // 2200 frames now buffered, above the quantum
    let second = read(ring, frames: 2048)
    #expect(second.allSatisfy { $0 == 0.5 })
    #expect(ring.stats.underruns == 0)
}
