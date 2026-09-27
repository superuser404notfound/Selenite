import AppCore
import HostKit
import SwiftUI

/// One screen (M1-B spec, 4.1): the header, the host row, the selected host's apps.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var focusScope

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            header
            if model.directory.hosts.isEmpty {
                EmptyHostsView()
            } else {
                HostRow(focusScope: focusScope)
                AppSection()
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// The saved hosts, then the "Add host" card. Focus selects a host.
private struct HostRow: View {
    @Environment(AppModel.self) private var model
    let focusScope: Namespace.ID

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 40) {
                ForEach(model.directory.hosts) { snapshot in
                    let isSelected = snapshot.id == model.selectedHost?.id
                    HostCard(snapshot: snapshot, isSelected: isSelected,
                             onSelect: { model.select(snapshot.id) },
                             onRemove: { model.pendingRemoval = snapshot.host },
                             onPairAgain: { model.addHostRequest = .pairAgain(snapshot.host) })
                        .prefersDefaultFocus(isSelected, in: focusScope)
                }
                AddHostCard { model.addHostRequest = .new }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 12)
        }
        .scrollClipDisabled()
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
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
        }
    }
}

/// The selected host's apps, or why there are none.
private struct AppSection: View {
    @Environment(AppModel.self) private var model

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(AppTile.size.width), spacing: 48), count: 6)
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
        if snapshot.status == .offline {
            notice(systemImage: "wifi.slash", text: Text("\(snapshot.host.name) is offline."))
        } else if apps.isEmpty && model.catalog.failedHosts.contains(snapshot.id) {
            notice(systemImage: "exclamationmark.triangle", text: Text("The app list could not be loaded."))
        } else if apps.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                    ForEach(apps) { app in
                        AppTile(host: snapshot.host, app: app, isRunning: app.id == snapshot.currentGame) {
                            model.appSelected(app)
                        }
                    }
                }
                .padding(30)
            }
            .scrollClipDisabled()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// No hosts at all: one large "Add host" entry instead of the page body.
private struct EmptyHostsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
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
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
