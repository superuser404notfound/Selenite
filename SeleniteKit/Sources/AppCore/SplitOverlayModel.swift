import InputKit

public enum OverlayItem: Hashable, Sendable {
    case volumeDown(SplitSide), volumeUp(SplitSide)
    /// Disconnect while a side streams; Reconnect, Resume or Restart once it ended; Cancel while it wakes.
    case primary(SplitSide)
    /// Quit game while a side streams (press twice); Choose game once it ended.
    case secondary(SplitSide)
    case swap, reassign, endSplit, resume
}

public enum OverlayDirection: Sendable {
    case up, down, left, right
}

/// Where the Siri Remote points in the split overlay (M2 spec, section 4).
public struct OverlayCursor: Equatable, Sendable {
    public static let rows: [[OverlayItem]] = [
        [.volumeDown(.first), .volumeUp(.first), .volumeDown(.second), .volumeUp(.second)],
        [.primary(.first), .primary(.second)],
        [.secondary(.first), .secondary(.second)],
        [.swap, .reassign, .endSplit, .resume],
    ]

    public private(set) var item: OverlayItem

    public init(item: OverlayItem = .resume) {
        self.item = item
    }

    public mutating func move(_ direction: OverlayDirection) {
        guard let (row, column) = Self.position(of: item) else { return }
        let items = Self.rows[row]
        switch direction {
        case .left: item = items[max(column - 1, 0)]
        case .right: item = items[min(column + 1, items.count - 1)]
        case .up, .down:
            let target = direction == .up ? row - 1 : row + 1
            guard Self.rows.indices.contains(target) else { return }
            let centre = (Double(column) + 0.5) / Double(items.count)
            let candidates = Self.rows[target]
            let best = candidates.indices.min { a, b in
                let da = abs((Double(a) + 0.5) / Double(candidates.count) - centre)
                let db = abs((Double(b) + 0.5) / Double(candidates.count) - centre)
                return da < db - 1e-9 || (abs(da - db) <= 1e-9 && a < b)
            } ?? 0
            item = candidates[best]
        }
    }

    static func position(of item: OverlayItem) -> (Int, Int)? {
        for (row, items) in rows.enumerated() {
            if let column = items.firstIndex(of: item) { return (row, column) }
        }
        return nil
    }
}
