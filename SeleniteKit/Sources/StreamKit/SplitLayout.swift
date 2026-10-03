/// How the two halves share the screen (M2 spec, section 3).
public enum SplitLayout: String, Codable, Sendable, CaseIterable {
    case sideBySide, topBottom
}

/// What each half asks its host for: the whole half, or the largest 16:9 picture inside it.
public enum SplitFormat: String, Codable, Sendable, CaseIterable {
    case fillHalf, sixteenByNine
}
