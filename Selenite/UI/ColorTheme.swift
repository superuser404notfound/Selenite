import SwiftUI

// Adapted from Sodalite Extensions/Color+Theme.swift. Neutral colour only: a grey, a dim or a status
// colour. Chromatic colour is `.tint`. Tokens are for flat surfaces; a shadow or gradient stop
// stays literal where it is tuned against what it sits on.
extension Color {
    enum Theme {
        /// The page behind everything, and the stream's letterbox.
        static let page = Color.black
        /// Neutral card and tile ground.
        static let surface = Color(white: 0.1)
        /// Raised neutral surface, the focused card.
        static let surfaceElevated = Color(white: 0.15)
        /// Focused ground of a row whose focus goes white.
        static let focusFill = Color.white.opacity(0.15)
        /// Resting ground of such a row.
        static let restFill = Color.white.opacity(0.08)
        /// Faintest resting ground, for a row inside an already lifted panel.
        static let restFillFaint = Color.white.opacity(0.04)
        /// Edge around unpredictable content (artwork).
        static let hairline = Color.white.opacity(0.18)
        /// Edge around a known dark or frosted panel.
        static let panelEdge = Color.white.opacity(0.12)
        /// Dim behind a panel.
        static let scrim = Color.black.opacity(0.55)
        static let scrimHeavy = Color.black.opacity(0.85)
        static let success = Color.green
        static let destructive = Color.red
        static let warning = Color.yellow
    }
}
