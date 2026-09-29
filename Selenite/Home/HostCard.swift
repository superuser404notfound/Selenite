import AppCore
import HostKit
import SwiftUI

/// One saved host: name and live status. Focus only highlights it; a click selects it and wakes it
/// when it sleeps; a long press offers Pair again and Remove. The selected host carries a check.
struct HostCard: View {
    let snapshot: HostSnapshot
    let isSelected: Bool
    let onClick: () -> Void
    let onRemove: () -> Void
    let onPairAgain: () -> Void
    let onToggleWakeOnLAN: () -> Void

    var body: some View {
        FocusableCard(action: onClick, longPressOpensMenu: true) { focused in
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
            .overlay(HostRowCardEdge(isFocused: focused))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .padding(16)
                }
            }
        }
        .contextMenu {
            Button("Pair again", systemImage: "key") { onPairAgain() }
            if snapshot.host.macAddress.flatMap(MACAddress.init) != nil {
                Button(snapshot.host.wakesOnLAN ? "Wake-on-LAN: On" : "Wake-on-LAN: Off", systemImage: "power") {
                    onToggleWakeOnLAN()
                }
            }
            Button("Remove", systemImage: "trash", role: .destructive) { onRemove() }
        }
    }

    private var statusText: LocalizedStringKey {
        switch snapshot.status {
        case .unknown: "Checking…"
        case .offline: HostWaker.canWake(snapshot.host) ? "Asleep" : "Offline"
        case .online: "Online"
        case .busy: "Busy"
        }
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .unknown: .gray
        case .offline: HostWaker.canWake(snapshot.host) ? .gray : Color.Theme.destructive
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
            .overlay(HostRowCardEdge(isFocused: focused))
        }
    }
}

/// The edge of every card in the host row: the tint border marks focus, not selection.
struct HostRowCardEdge: View {
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.Theme.panelEdge),
                          lineWidth: isFocused ? 3 : 1)
    }
}
