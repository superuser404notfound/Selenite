import AppCore
import HostKit
import SwiftUI

/// One saved host in Settings: shows whether it has stream settings of its own and opens the same
/// panel as the host card's long press.
struct HostSettingsRow: View {
    @Environment(AppModel.self) private var model
    let host: PairedHost

    @State private var isEditing = false
    @FocusState private var focused: Bool

    var body: some View {
        let hasOverrides = model.hostSettings.hasOverrides(hostID: host.id)
        HStack(spacing: 36) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 36))
                .frame(width: 64)
                .foregroundStyle(.tint)
            Text(host.name)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(hasOverrides ? "Own settings" : "Global")
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(hasOverrides ? AnyShapeStyle(.tint) : AnyShapeStyle(focused ? .primary : .secondary))
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 16).fill(focused ? Color.Theme.focusFill : Color.Theme.restFillFaint))
        .focusStroke(cornerRadius: 16, isFocused: focused)
        .focusResponse(.row, isFocused: focused)
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused) { isEditing = true }
        .menuPresentation(isPresented: $isEditing) {
            HostSettingsView(host: host).environment(model)
        }
    }
}
