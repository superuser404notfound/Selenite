import AppCore
import HostKit
import SwiftUI

/// One screen (M1-B spec, 4.1): the header, the host row, the selected host's apps.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var focusScope

    var body: some View {
        // One vertical scroll for the whole page, so the grid never slides over the host row.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                header
                    .focusSection()
                if model.directory.hosts.isEmpty && model.discovery.discovered.isEmpty {
                    EmptyHostsView()
                } else {
                    HostRow(focusScope: focusScope)
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
    @FocusState private var focusedHostID: String?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 40) {
                ForEach(model.directory.hosts) { snapshot in
                    let isSelected = snapshot.id == model.selectedHost?.id
                    HostCard(snapshot: snapshot, isSelected: isSelected,
                             onClick: { model.hostCardClicked(snapshot) },
                             onRemove: { model.pendingRemoval = snapshot.host },
                             onPairAgain: { model.addHostRequest = .pairAgain(snapshot.host) },
                             onToggleWakeOnLAN: { model.setWakeOnLAN(snapshot.host, enabled: !snapshot.host.wakesOnLAN) })
                        .focused($focusedHostID, equals: snapshot.id)
                        // Initial focus of the scope; the row's defaultFocus covers a move into the row.
                        .prefersDefaultFocus(isSelected, in: focusScope)
                }
                ForEach(model.discovery.discovered) { host in
                    DiscoveredHostCard(host: host) { model.addHostRequest = .discovered(host) }
                }
                AddHostCard { model.addHostRequest = .new }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 12)
        }
        .scrollClipDisabled()
        .defaultFocus($focusedHostID, model.selectedHost?.id, priority: .userInitiated)
        .frame(height: 250)
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

    // Adaptive, not a fixed column count: six fixed-width columns plus their gaps and padding
    // (1740pt) exceed the width left after the page's own horizontal padding and the tvOS safe
    // area (about 1580pt), which pushed the whole page's content wider than the screen. The
    // columns take as many as fit and share the rest; each tile sits centered in its column.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: AppTile.size.width), spacing: 48, alignment: .center)]
    }

    var body: some View {
        if let snapshot = model.selectedHost {
            content(for: snapshot)
                .task(id: "\(snapshot.id)|\(String(describing: snapshot.status))") {
                    await model.loadApps(for: snapshot)
                }
        }
    }

    @ViewBuilder
    private func content(for snapshot: HostSnapshot) -> some View {
        let apps = model.catalog.apps[snapshot.id] ?? []
        if snapshot.status == .offline && HostWaker.canWake(snapshot.host) && !apps.isEmpty {
            LazyVGrid(columns: columns, alignment: .center, spacing: 56) {
                ForEach(apps) { app in
                    AppTile(host: snapshot.host, app: app, isRunning: false, isDimmed: true) {
                        model.appSelected(app)
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
                    AppTile(host: snapshot.host, app: app, isRunning: isRunning,
                            onQuit: isRunning ? { model.requestQuit(host: snapshot.host, app: app) } : nil) {
                        model.appSelected(app)
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
