import SwiftUI

// Adapted from Sodalite Components/ArtworkTile.swift, LayoutMetrics.swift (ArtworkCorner) and
// MediaFocusRing.swift, without the accent palette.

enum ArtworkCorner {
    static let radius: CGFloat = 12
}

/// The neutral ground behind artwork that is loading or missing.
struct ArtworkTileSurface: View {
    var body: some View {
        LinearGradient(colors: [Color.Theme.surface, Color.Theme.surfaceElevated],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A tile's name drawn on the tile, for artwork that is missing.
struct ArtworkTileLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .shadow(radius: 4)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// The ring drawn just outside artwork on focus. It sits `outset` points outside the content, so
/// its radius is the content's plus the outset, or the corners would show a dark crescent.
struct FocusRing: View {
    let cornerRadius: CGFloat
    let isFocused: Bool

    static let outset: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius + Self.outset)
            .strokeBorder(.tint, lineWidth: Self.outset)
            .padding(-Self.outset)
            .opacity(isFocused ? 1 : 0)
            .animation(FocusResponse.card.animation, value: isFocused)
            .accessibilityHidden(true)
    }
}
