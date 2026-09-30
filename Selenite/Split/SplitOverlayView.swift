import AppCore
import InputKit
import StreamKit
import SwiftUI

/// The split overlay (M2 spec, section 4): a centered glass panel over both videos, driven entirely
/// by `SplitController`'s own cursor through the Siri Remote, never UIKit focus, so gamepads keep
/// playing behind it. Every item is a plain view, highlighted when `split.cursor.item` matches it.
///
/// Columns follow the screen: position `.first` is always the left or top half, `.second` the right
/// or bottom half. `SplitController.realSide` maps a position to the side actually streaming there.
struct SplitOverlayView: View {
    let split: SplitController
    let hostName: (SplitSide) -> String

    var body: some View {
        panel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panel: some View {
        VStack(spacing: 28) {
            HStack(alignment: .top, spacing: 48) {
                column(.first)
                column(.second)
            }
            bottomRow
            Text("Swipe to move, click to choose. Menu closes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(width: 1400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
    }

    private var isStacked: Bool { split.plan.layout == .topBottom }

    private func columnTitle(_ position: SplitSide) -> LocalizedStringKey {
        switch (position, isStacked) {
        case (.first, false): "Left"
        case (.second, false): "Right"
        case (.first, true): "Top"
        case (.second, true): "Bottom"
        }
    }

    private func column(_ position: SplitSide) -> some View {
        let side = split.realSide(position)
        return VStack(alignment: .leading, spacing: 14) {
            Text(columnTitle(position))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(split.plan[side].app.title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(hostName(side))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let stats = split.streams[side]?.liveStats {
                CompactStatsPill(stats: stats)
            }
            volumeRow(position: position, side: side)
            labelCell(.primary(position), label: primaryLabel(side),
                     isDestructive: isPrimaryDestructive(side), isDimmed: isPrimaryDimmed(side))
            labelCell(.secondary(position), label: secondaryLabel(side),
                     isDestructive: isSecondaryDestructive(side), isDimmed: isSecondaryDimmed(side))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func volumeRow(position: SplitSide, side: SplitSide) -> some View {
        HStack(spacing: 16) {
            glyphCell(.volumeDown(position), systemImage: "minus")
            Text(verbatim: "\(Int(((split.volumes[side] ?? 1) * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 64)
                .multilineTextAlignment(.center)
            glyphCell(.volumeUp(position), systemImage: "plus")
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 16) {
            labelCell(.swap, label: "Swap sides")
            labelCell(.reassign, label: "Reassign controllers")
            labelCell(.endSplit, label: "End split", isDestructive: true)
            labelCell(.resume, label: "Resume")
        }
    }

    // MARK: Side labels

    /// Streaming covers the whole run from connect to running (M2 spec, section 3), so it reads
    /// "Disconnect"; a side that has not started or that just ended reads by its own state.
    private func primaryLabel(_ side: SplitSide) -> LocalizedStringKey {
        switch split.states[side] ?? .idle {
        case .streaming: "Disconnect"
        case .waking, .idle: "Cancel"
        case .ended(.quit): "Restart"
        case .ended(.suspended): "Resume"
        case .ended: "Reconnect"
        }
    }

    private func isPrimaryDestructive(_ side: SplitSide) -> Bool {
        (split.states[side] ?? .idle) == .streaming
    }

    /// `.idle` is the brief instant between "start" and a `StreamController` existing, where
    /// `primaryAction` has nothing in flight to cancel yet.
    private func isPrimaryDimmed(_ side: SplitSide) -> Bool {
        (split.states[side] ?? .idle) == .idle
    }

    private func secondaryLabel(_ side: SplitSide) -> LocalizedStringKey {
        switch split.states[side] ?? .idle {
        case .streaming: split.quitArmed == side ? "Press again to quit" : "Quit game"
        case .idle, .waking, .ended: "Choose game"
        }
    }

    private func isSecondaryDestructive(_ side: SplitSide) -> Bool {
        (split.states[side] ?? .idle) == .streaming
    }

    /// `quitGame()` is a no-op before the stream reaches `.waitingForPicture` (M1-B spec, 4.5), and
    /// `secondaryAction` does nothing at all while `.idle`: both read as "Choose game" but dimmed
    /// rather than armable, instead of a press that silently does nothing.
    private func isSecondaryDimmed(_ side: SplitSide) -> Bool {
        switch split.states[side] ?? .idle {
        case .idle: return true
        case .streaming:
            guard let phase = split.streams[side]?.phase else { return true }
            return phase == .connecting || phase == .startingGame
        default: return false
        }
    }

    // MARK: Cells

    private func labelCell(_ target: OverlayItem, label: LocalizedStringKey,
                           isDestructive: Bool = false, isDimmed: Bool = false) -> some View {
        OverlayCell(isHighlighted: split.cursor.item == target, isDestructive: isDestructive, isDimmed: isDimmed) {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
    }

    private func glyphCell(_ target: OverlayItem, systemImage: String) -> some View {
        OverlayCell(isHighlighted: split.cursor.item == target) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 44, height: 44)
        }
    }
}

/// One item in the overlay: highlighted with a tint fill and a 1.05 scale when the cursor sits on
/// it. Never a `Button`, the cursor drives selection, not UIKit focus.
private struct OverlayCell<Content: View>: View {
    let isHighlighted: Bool
    var isDestructive = false
    var isDimmed = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .foregroundStyle(isDestructive ? Color.Theme.destructive : Color.primary)
            .opacity(isDimmed ? 0.4 : 1)
            .background(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                       in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(isHighlighted ? 1.05 : 1)
    }
}
