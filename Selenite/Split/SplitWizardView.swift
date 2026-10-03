import AppCore
import HostKit
import InputKit
import StreamKit
import SwiftUI

/// The wizard that builds a `SplitPlan` (M2 spec, section 4): host and game for Player 1, the same
/// for Player 2, then layout. `wizard.replacing != nil` is the one-side wizard for a side that
/// ended: it skips the layout step and finishes as soon as the game is chosen.
struct SplitWizardView: View {
    let wizard: SplitWizardModel
    @Environment(AppModel.self) private var model
    @Namespace private var focusScope

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: AppTile.size.width), spacing: 48, alignment: .center)]
    }

    var body: some View {
        // One vertical scroll for the whole page, as on Home, so the title scrolls away with a long
        // game grid instead of staying behind it.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                header
                step
                    .focusSection()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollClipDisabled()
        // A fresh scroll view per step: the offset of a long game grid must not carry over into
        // the next, shorter step and leave its title above the screen.
        .id(String(describing: wizard.step))
        .background(Color.Theme.page.ignoresSafeArea())
        .focusScope(focusScope)
        // One-side mode has no layout step: the plan is already complete once the game is chosen.
        .onChange(of: wizard.step) { _, newStep in
            if wizard.replacing != nil, newStep == .layout {
                model.splitWizardFinished(wizard)
            }
        }
        // Deeper than MenuPanelCover's own onExitCommand, so this one runs instead of the default
        // dismiss: Menu steps back a step, and only closes the wizard once there is nowhere to go.
        .onExitCommand {
            if !wizard.back() { model.splitWizard = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split screen")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(stepTitle)
                .font(.largeTitle)
                .fontWeight(.bold)
        }
    }

    private var stepTitle: LocalizedStringKey {
        switch wizard.step {
        case .host(.first): "Player 1: choose a host"
        case .game(.first): "Player 1: choose a game"
        case .host(.second): "Player 2: choose a host"
        case .game(.second): "Player 2: choose a game"
        case .layout: "Layout"
        }
    }

    @ViewBuilder
    private var step: some View {
        switch wizard.step {
        case .host(let side):
            hostStep(side: side)
        case .game(let side):
            gameStep(side: side)
        case .layout:
            layoutStep
        }
    }

    // MARK: Host step

    private func hostStep(side: SplitSide) -> some View {
        let usedBy = side.other
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 40) {
                ForEach(model.directory.hosts) { snapshot in
                    let selectable = wizard.isHostSelectable(snapshot.id)
                    WizardHostCard(snapshot: snapshot, isSelectable: selectable,
                                   usedByLabel: alreadyUsedNote(usedBy)) {
                        wizard.chooseHost(snapshot.id)
                    }
                }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 12)
        }
        .scrollClipDisabled()
    }

    private func alreadyUsedNote(_ side: SplitSide) -> LocalizedStringKey {
        side == .first ? "Already used by Player 1" : "Already used by Player 2"
    }

    // MARK: Game step

    private func gameStep(side: SplitSide) -> some View {
        Group {
            if let hostID = wizard.hostIDs[side], let snapshot = model.directory.snapshot(id: hostID) {
                gameGrid(for: snapshot)
                .task(id: "\(snapshot.id)|\(String(describing: snapshot.status))") {
                    await model.loadApps(for: snapshot)
                }
            }
        }
    }

    @ViewBuilder
    private func gameGrid(for snapshot: HostSnapshot) -> some View {
        let apps = model.catalog.apps[snapshot.id] ?? []
        if snapshot.status == .offline && HostWaker.canWake(snapshot.host) && !apps.isEmpty {
            LazyVGrid(columns: columns, alignment: .center, spacing: 56) {
                ForEach(apps) { app in
                    AppTile(host: snapshot.host, app: app, isRunning: false, isDimmed: true) {
                        wizard.chooseGame(app)
                    }
                }
            }
            .padding(30)
        } else if snapshot.status == .offline {
            notice(systemImage: "wifi.slash", text: Text("\(snapshot.host.name) is offline."))
        } else if apps.isEmpty && model.catalog.failedHosts.contains(snapshot.id) {
            notice(systemImage: "exclamationmark.triangle", text: Text("The app list could not be loaded."))
        } else if apps.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 400)
        } else {
            LazyVGrid(columns: columns, alignment: .center, spacing: 56) {
                ForEach(apps) { app in
                    let isRunning = app.id == snapshot.currentGame
                    AppTile(host: snapshot.host, app: app, isRunning: isRunning) {
                        wizard.chooseGame(app)
                    }
                }
            }
            .padding(30)
        }
    }

    private func notice(systemImage: String, text: Text) -> some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            text
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: Layout step

    private var layoutStep: some View {
        VStack(alignment: .leading, spacing: 48) {
            layoutChoiceGroup(title: "Screen split") {
                WizardChoiceButton(isSelected: wizard.layout == .sideBySide, label: "Side by side") {
                    wizard.layout = .sideBySide
                }
                WizardChoiceButton(isSelected: wizard.layout == .topBottom, label: "Top and bottom") {
                    wizard.layout = .topBottom
                }
            }
            layoutChoiceGroup(title: "Picture format") {
                WizardChoiceButton(isSelected: wizard.format == .fillHalf, label: "Fill half") {
                    wizard.format = .fillHalf
                }
                WizardChoiceButton(isSelected: wizard.format == .sixteenByNine, label: "16:9") {
                    wizard.format = .sixteenByNine
                }
            }
            Button("Continue") { model.splitWizardFinished(wizard) }
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    private func layoutChoiceGroup<Content: View>(
        title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                content()
            }
        }
    }
}

/// One paired host in the host step: a click selects it. The other side's host shows as disabled
/// with a note instead of its live status; sleeping hosts stay selectable.
private struct WizardHostCard: View {
    let snapshot: HostSnapshot
    let isSelectable: Bool
    let usedByLabel: LocalizedStringKey
    let onClick: () -> Void

    var body: some View {
        FocusableCard(action: onClick) { focused in
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 40))
                Text(snapshot.host.name)
                    .font(.headline)
                    .lineLimit(1)
                if isSelectable {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(snapshot.statusColor)
                            .frame(width: 14, height: 14)
                        Text(snapshot.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(usedByLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(width: 320, height: 170, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.Theme.surfaceElevated : Color.Theme.surface))
            .overlay(HostRowCardEdge(isFocused: focused))
            .opacity(isSelectable ? 1 : 0.45)
        }
    }
}

/// One option in the layout or format choice group: a checkmark marks the current selection.
private struct WizardChoiceButton: View {
    let isSelected: Bool
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
