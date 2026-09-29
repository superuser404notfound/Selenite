import AppCore
import HostKit
import SwiftUI

/// The last games across all hosts (M1-C spec, section 5); hidden while empty.
struct RecentsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.recents.entries.filter { model.directory.snapshot(id: $0.hostID) != nil }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text("Recently played")
                    .font(.title3)
                    .fontWeight(.bold)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 48) {
                        ForEach(entries) { entry in
                            if let snapshot = model.directory.snapshot(id: entry.hostID) {
                                AppTile(host: snapshot.host, app: entry.app,
                                        isRunning: snapshot.currentGame == entry.app.id,
                                        isDimmed: snapshot.status == .offline,
                                        subtitle: snapshot.host.name,
                                        onRemove: { model.recents.remove(entry) },
                                        action: { model.recentSelected(entry) })
                            }
                        }
                    }
                    .padding(30)
                }
                .scrollClipDisabled()
            }
        }
    }
}
