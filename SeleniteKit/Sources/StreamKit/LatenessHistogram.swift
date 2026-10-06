import Foundation

/// Lateness values over a sliding window, kept as a histogram in `slices` slices (a ring indexed
/// by slice number) so old values expire without being stored, and read back as quantiles. A
/// slice expires when a later value is added, never on a read.
struct LatenessHistogram {
    let window: Double
    let slices: Int
    /// Bin width, seconds; values are rounded up into a bin and clamped to the last one.
    let bin: Double
    let bins: Int

    private var rows: [[Int]]
    private var counts: [Int]
    private(set) var total = 0
    private var slice = 0

    init(window: Double, slices: Int, bin: Double, bins: Int) {
        self.window = window
        self.slices = slices
        self.bin = bin
        self.bins = bins
        rows = Array(repeating: Array(repeating: 0, count: bins), count: slices)
        counts = Array(repeating: 0, count: bins)
    }

    mutating func add(_ lateness: Double, at time: Double) {
        let current = Int(time / (window / Double(slices)))
        if current > slice {
            for skipped in 1...min(slices, current - slice) {
                let expired = (slice + skipped) % slices
                for (index, count) in rows[expired].enumerated() where count > 0 {
                    counts[index] -= count
                    total -= count
                    rows[expired][index] = 0
                }
            }
            slice = current
        }
        let index = min(bins - 1, max(0, Int((lateness / bin).rounded(.up))))
        rows[slice % slices][index] += 1
        counts[index] += 1
        total += 1
    }

    /// The smallest bin value at or below which `quantile` of the window lies, seconds.
    func quantile(_ quantile: Double) -> Double {
        var seen = 0
        for (index, count) in counts.enumerated() {
            seen += count
            if Double(seen) >= Double(total) * quantile { return Double(index) * bin }
        }
        return Double(bins - 1) * bin
    }

    /// The largest value in the window, seconds; 0 when empty.
    var largest: Double {
        (counts.lastIndex { $0 > 0 }).map { Double($0) * bin } ?? 0
    }
}
