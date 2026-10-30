import AppCore
import HostKit
import SwiftUI

/// One screen (M1-B spec, 4.1): the header, the host row, the selected host's apps.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var focusScope
    @State private var hostForSettings: PairedHost?

    var body: some View {
        // One vertical scroll for the whole page, so the grid never slides over the host row.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                header
                    .focusSection()
                if model.directory.hosts.isEmpty && model.discovery.discovered.isEmpty {
                    EmptyHostsView()
                } else {
                    HostRow(focusScope: focusScope, hostForSettings: $hostForSettings)
                        .focusSection()
                    RecentsRow()
                        .focusSection()
                    if !model.directory.hosts.isEmpty {
                        AppSection()
                            .focusSection()
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 40)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollClipDisabled()
        .background(Color.Theme.page.ignoresSafeArea())
        .focusScope(focusScope)
        .menuPresentation(item: $hostForSettings) { host in
            HostSettingsView(host: host).environment(model)
        }
        .onAppear { model.homeAppeared() }
        .onDisappear { model.homeDisappeared() }
    }

    private var header: some View {
        HStack {
            Text("Selenite")
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            // The header's only control, so this HStack is not a row of buttons.
            Button {
                model.isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

/// The saved hosts, then the "Add host" card. Focus only highlights; a click selects a host. Focus
/// entering the row lands on the selected host.
private struct HostRow: View {
    @Environment(AppModel.self) private var model
    let focusScope: Namespace.ID
    @Binding var hostForSettings: PairedHost?
    @FocusState private var focusedHostID: String?

    var body: some View {
        // Eager like the recents row: a lazy stack left the cards past the edge unbuilt, so they
        // popped in and out instead of peeking into the page margin.
        ScrollView(.horizontal) {
            HStack(spacing: 40) {
                ForEach(model.directory.hosts) { snapshot in
                    let isSelected = snapshot.id == model.selectedHost?.id
                    HostCard(snapshot: snapshot, isSelected: isSelected,
                             onClick: { model.hostCardClicked(snapshot) },
                             onRemove: { model.pendingRemoval = snapshot.host },
                             onPairAgain: { model.addHostRequest = .pairAgain(snapshot.host) },
                             onToggleWakeOnLAN: { model.setWakeOnLAN(snapshot.host, enabled: !snapshot.host.wakesOnLAN) },
                             hasOverrides: model.hostSettings.hasOverrides(hostID: snapshot.host.id),
                             onStreamSettings: { hostForSettings = snapshot.host })
                        .focused($focusedHostID, equals: snapshot.id)
                        // Initial focus of the scope; the row's defaultFocus covers a move into the row.
                        .prefersDefaultFocus(isSelected, in: focusScope)
                }
                ForEach(model.discovery.discovered) { host in
                    DiscoveredHostCard(host: host) { model.addHostRequest = .discovered(host) }
                }
                AddHostCard { model.addHostRequest = .new }
                if model.directory.hosts.count >= 2 {
                    SplitCard { model.openSplitWizard() }
                }
                if let plan = quickSplitPlan {
                    QuickSplitCard(plan: plan,
                                   firstHostName: hostName(plan.first.hostID),
                                   secondHostName: hostName(plan.second.hostID)) {
                        model.startQuickSplit()
                    }
                }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 12)
        }
        .scrollClipDisabled()
        .defaultFocus($focusedHostID, model.selectedHost?.id, priority: .userInitiated)
        .frame(height: 250)
    }

    /// The last split, only while both of its hosts are still paired.
    private var quickSplitPlan: SplitPlan? {
        guard let plan = model.splitStore.plan,
              model.directory.hosts.contains(where: { $0.id == plan.first.hostID }),
              model.directory.hosts.contains(where: { $0.id == plan.second.hostID }) else { return nil }
        return plan
    }

    private func hostName(_ hostID: String) -> String {
        model.directory.snapshot(id: hostID)?.host.name ?? ""
    }
}

private struct SplitCard: View {
    let action: () -> Void

    var body: some View {
        FocusableCard(action: action) { focused in
            VStack(spacing: 16) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 44, weight: .semibold))
                Text("Split screen")
                    .font(.headline)
            }
            .frame(width: 240, height: 170)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.Theme.surfaceElevated : Color.Theme.surface))
            .overlay(HostRowCardEdge(isFocused: focused))
        }
    }
}

/// Starts the last split again: the two games on their two hosts.
private struct QuickSplitCard: View {
    let plan: SplitPlan
    let firstHostName: String
    let secondHostName: String
    let action: () -> Void

    var body: some View {
        FocusableCard(action: action) { focused in
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 40))
                Text("\(plan.first.app.title) + \(plan.second.app.title)")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(firstHostName) + \(secondHostName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(24)
            .frame(width: 320, height: 170, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.Theme.surfaceElevated : Color.Theme.surface))
            .overlay(HostRowCardEdge(isFocused: focused))
        }
    }
}

private struct AddHostCard: View {
    let action: () -> Void

    var body: some View {
        FocusableCard(action: action) { focused in
            VStack(spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .semibold))
                Text("Add host")
                    .font(.headline)
            }
            .frame(width: 240, height: 170)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.Theme.surfaceElevated : Color.Theme.surface))
            .overlay(HostRowCardEdge(isFocused: focused))
        }
    }
}

/// The selected host's apps, or why there are none.
private struct AppSection: View {
    @Environment(AppModel.self) private var model

    // Fixed-width columns with the recents row's 48pt gap, as many as the measured width holds,
    // left-aligned: adaptive columns shared the leftover width and centered each tile in its
    // column, so the grid's edge inset and gaps drifted from the recents row above it.
    @State private var columnCount = 1
    private static let gap: CGFloat = 48
    private static let inset: CGFloat = 30

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(AppTile.size.width), spacing: Self.gap, alignment: .leading),
              count: columnCount)
    }

    var body: some View {
        if let snapshot = model.selectedHost {
            content(for: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                    let usable = width - 2 * Self.inset + Self.gap
                    columnCount = max(1, Int(usable / (AppTile.size.width + Self.gap)))
                }
                .task(id: "\(snapshot.id)|\(String(describing: snapshot.status))") {
                    await model.loadApps(for: snapshot)
                }
        }
    }

    @ViewBuilder
    private func content(for snapshot: HostSnapshot) -> some View {
        let apps = model.catalog.apps[snapshot.id] ?? []
        if snapshot.status == .offline && HostWaker.canWake(snapshot.host) && !apps.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(apps) { app in
                    AppTile(host: snapshot.host, app: app, isRunning: false, isDimmed: true) {
                        model.appSelected(app)
                    }
                }
            }
            .padding(Self.inset)
        } else if snapshot.status == .offline {
            notice(systemImage: "wifi.slash", text: Text("\(snapshot.host.name) is offline."))
        } else if apps.isEmpty && model.catalog.failedHosts.contains(snapshot.id) {
            notice(systemImage: "exclamationmark.triangle", text: Text("The app list could not be loaded."))
        } else if apps.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 400)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(apps) { app in
                    let isRunning = app.id == snapshot.currentGame
                    AppTile(host: snapshot.host, app: app, isRunning: isRunning,
                            onQuit: isRunning ? { model.requestQuit(host: snapshot.host, app: app) } : nil) {
                        model.appSelected(app)
                    }
                }
            }
            .padding(Self.inset)
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
}

/// No hosts at all: one large "Add host" entry instead of the page body.
private struct EmptyHostsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            FocusableCard(action: { model.addHostRequest = .new }) { focused in
                VStack(spacing: 24) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.tint)
                    Text("Add host")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Pair Selenite with a PC running Sunshine.")
                        .foregroundStyle(.secondary)
                }
                .padding(60)
                .frame(width: 720)
                .background(RoundedRectangle(cornerRadius: 28).fill(focused ? Color.Theme.surfaceElevated : Color.Theme.surface))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 700)
    }
}
