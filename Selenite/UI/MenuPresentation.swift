import SwiftUI

// Adapted from Sodalite Components/MenuPresentation.swift (its tvOS branch).

/// What the cover supplies around a panel.
enum MenuPanelStyle {
    /// The cover draws the card: material, rounded corner, the 10-foot inset.
    case card
    /// Scrim only, for content that brings its own panel.
    case plain
}

extension View {
    /// Presents a panel as a cover that draws its own scrim and eases it in over 0.35 s. A tvOS
    /// `.sheet` darkens the page on UIKit's curve, which is a step rather than a fade (measured in
    /// Sodalite: 51% of the drop inside the first 83 ms). Menu dismisses the panel unless deeper
    /// content handles Menu itself.
    func menuPresentation<Content: View>(
        isPresented: Binding<Bool>,
        panel: MenuPanelStyle = .card,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            MenuPanelCover(panel: panel, dismiss: { isPresented.wrappedValue = false }, content: content)
        }
    }

    /// `item:` form, for panels that carry their subject in the binding.
    func menuPresentation<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        panel: MenuPanelStyle = .card,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { value in
            MenuPanelCover(panel: panel, dismiss: { item.wrappedValue = nil }) { content(value) }
        }
    }
}

private struct MenuPanelCover<Content: View>: View {
    let panel: MenuPanelStyle
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var shown = false

    var body: some View {
        ZStack {
            // Only the scrim animates: rows at alpha 0 while tvOS commits first focus get none.
            Color.Theme.scrim
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
            switch panel {
            case .card:
                content()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
            case .plain:
                content()
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.35)) { shown = true }
        }
        .onExitCommand { dismiss() }
    }
}
