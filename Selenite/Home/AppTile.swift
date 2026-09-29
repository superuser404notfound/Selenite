import AppCore
import HostKit
import SwiftUI

/// An app of the selected host: box art, or its title on the neutral ground when the host has
/// none. The app the host is running carries a "Running" badge; choosing it resumes. A long press
/// offers "Quit game" when `onQuit` is set (the running game) and "Remove from list" when
/// `onRemove` is set (a recent).
struct AppTile: View {
    static let size = CGSize(width: 240, height: 320)

    let host: PairedHost
    let app: AppEntry
    let isRunning: Bool
    var isDimmed = false
    var subtitle: String? = nil
    var onQuit: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    let action: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        if onQuit != nil || onRemove != nil {
            card.contextMenu {
                if let onQuit {
                    Button("Quit game", systemImage: "xmark.circle", role: .destructive) { onQuit() }
                }
                if let onRemove {
                    Button("Remove from list", systemImage: "minus.circle", role: .destructive) { onRemove() }
                }
            }
        } else {
            card
        }
    }

    private var card: some View {
        FocusableCard(action: action, longPressOpensMenu: onQuit != nil || onRemove != nil) { focused in
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    AsyncCachedImage(key: "\(host.id)/\(app.id)",
                                     load: { await model.catalog.boxArt(for: host, appID: app.id) }) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack {
                            ArtworkTileSurface()
                            ArtworkTileLabel(title: app.title)
                        }
                    }
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipped()
                    if isRunning {
                        Text("Running")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.tint, in: Capsule())
                            .padding(12)
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .opacity(isDimmed ? 0.5 : 1)
                .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
                .contentShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
                .overlay(RoundedRectangle(cornerRadius: ArtworkCorner.radius).strokeBorder(Color.Theme.hairline, lineWidth: 1))
                .overlay(FocusRing(cornerRadius: ArtworkCorner.radius, isFocused: focused))
                Text(app.title)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: Self.size.width, alignment: .leading)
                    .foregroundStyle(focused ? .primary : .secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(width: Self.size.width, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
