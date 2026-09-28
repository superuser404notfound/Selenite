import SwiftUI

// Adapted from Sodalite Components/FocusResponse.swift, StableTap.swift and FocusableCard.swift,
// trimmed to the roles Selenite uses and without Sodalite's accent system (focus uses `.tint`).

/// The motion half of the focus gesture: how far a control lifts, how it settles, and the shadow
/// it casts while up. A scale is only comparable among controls of the same role.
struct FocusResponse: Equatable {
    struct Shadow: Equatable {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }

    let scale: CGFloat
    let shadow: Shadow?
    let animation: Animation

    static let settle = Animation.easeInOut(duration: 0.15)
    /// Cards that lift off the page: host cards, app tiles.
    static let card = FocusResponse(scale: 1.05, shadow: Shadow(opacity: 0.4, radius: 20, y: 10), animation: settle)
    /// A row standing as its own panel in a list: a settings row.
    static let row = FocusResponse(scale: 1.015, shadow: Shadow(opacity: 0.3, radius: 14, y: 6), animation: settle)
}

extension View {
    func focusResponse(_ response: FocusResponse, isFocused: Bool) -> some View {
        scaleEffect(isFocused ? response.scale : 1)
            .shadow(color: .black.opacity(isFocused ? (response.shadow?.opacity ?? 0) : 0),
                    radius: response.shadow?.radius ?? 0,
                    y: response.shadow?.y ?? 0)
            .animation(response.animation, value: isFocused)
    }

    /// The tinted focus stroke, drawn inside a row's or panel's own edge.
    func focusStroke(cornerRadius: CGFloat, isFocused: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
    }

    /// Stable-focus-gated tap; pass the view's focus state. Set `longPressOpensMenu` on a view that
    /// carries a `.contextMenu`.
    func stableTap(isFocused: Bool, longPressOpensMenu: Bool = false, perform action: @escaping () -> Void) -> some View {
        modifier(StableTapModifier(isFocused: isFocused, longPressOpensMenu: longPressOpensMenu, action: action))
    }
}

/// Siri Remote finger drift in the last frames of a click can move focus to a neighbour and fire
/// the wrong tile, so a press only counts once focus has been steady for 80 ms. On a view whose
/// hold opens a context menu the press decides on release and counts only when shorter than the
/// hold, so the view does not act on the way into its own menu.
struct StableTapModifier: ViewModifier {
    let isFocused: Bool
    let longPressOpensMenu: Bool
    let action: () -> Void

    static let stableFocusWindow: TimeInterval = 0.08
    static let clickHoldLimit: TimeInterval = 0.4

    @State private var focusAcquiredAt: Date?
    @State private var pressStartedAt: Date?
    @State private var pressBeganOnStableFocus = false

    func body(content: Content) -> some View {
        let tracked = content
            .onAppear {
                if isFocused { focusAcquiredAt = Date() }
            }
            .onChange(of: isFocused) { _, focused in
                focusAcquiredAt = focused ? Date() : nil
            }
        return Group {
            if longPressOpensMenu {
                tracked.onLongPressGesture(minimumDuration: Self.clickHoldLimit) {
                    // Reaching the limit is the menu's press; the release below stays out of the way.
                } onPressingChanged: { pressing in
                    if pressing {
                        pressStartedAt = Date()
                        pressBeganOnStableFocus = isFocusStable(at: Date())
                    } else {
                        let started = pressStartedAt
                        pressStartedAt = nil
                        guard let started, pressBeganOnStableFocus,
                              Date().timeIntervalSince(started) < Self.clickHoldLimit else { return }
                        action()
                    }
                }
            } else {
                tracked.onLongPressGesture(minimumDuration: 0.01) {
                    if isFocusStable(at: Date()) { action() }
                }
            }
        }
    }

    private func isFocusStable(at moment: Date) -> Bool {
        guard let acquired = focusAcquiredAt else { return false }
        return moment.timeIntervalSince(acquired) >= Self.stableFocusWindow
    }
}

/// A focusable card without tvOS's white button halo: lifts on focus, fires through `stableTap`.
struct FocusableCard<Content: View>: View {
    let action: () -> Void
    var longPressOpensMenu = false
    var onFocusChange: ((Bool) -> Void)? = nil
    @ViewBuilder let content: (_ isFocused: Bool) -> Content

    @FocusState private var isFocused: Bool

    var body: some View {
        content(isFocused)
            .focusable()
            .focused($isFocused)
            .stableTap(isFocused: isFocused, longPressOpensMenu: longPressOpensMenu) { action() }
            .focusResponse(.card, isFocused: isFocused)
            .onChange(of: isFocused) { _, focused in onFocusChange?(focused) }
    }
}
