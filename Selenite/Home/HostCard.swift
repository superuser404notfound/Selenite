import HostKit
import SwiftUI

/// One saved host: name and live status. Focus selects it; a long press offers Pair again and Remove.
struct HostCard: View {
    let snapshot: HostSnapshot
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onPairAgain: () -> Void

    var body: some View {
        FocusableCard(action: onSelect, longPressOpensMenu: true, onFocusChange: { focused in
            if focused { onSelect() }
        }) { focused in
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 40))
                Text(snapshot.host.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 14, height: 14)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(width: 320, height: 170, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.Theme.surfaceElevated : Color.Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.Theme.panelEdge),
                                  lineWidth: isSelected ? 3 : 1)
            )
        }
        .contextMenu {
            Button("Pair again", systemImage: "key") { onPairAgain() }
            Button("Remove", systemImage: "trash", role: .destructive) { onRemove() }
        }
    }

    private var statusText: LocalizedStringKey {
        switch snapshot.status {
        case .unknown: "Checking…"
        case .offline: "Offline"
        case .online: "Online"
        case .busy: "Busy"
        }
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .unknown: .gray
        case .offline: Color.Theme.destructive
        case .online: Color.Theme.success
        case .busy: Color.Theme.warning
        }
    }
}

/// A Sunshine PC found on the network that is not paired yet; selecting it pairs.
struct DiscoveredHostCard: View {
    let host: DiscoveredHost
    let action: () -> Void

    var body: some View {
        FocusableCard(action: action) { focused in
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 40))
                Text(verbatim: host.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Circle()
                        .fill(.tint)
                        .frame(width: 14, height: 14)
                    Text("New")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(width: 320, height: 170, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.Theme.surfaceElevated : Color.Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
        }
    }
}
