import AppCore
import HostKit
import SwiftUI

/// The last games across all hosts (M1-C spec, section 5); hidden while empty.
struct RecentsRow: View {
    @Environment(AppModel.self) private var model
    @State private var leading = AppTile.Columns.inset

    var body: some View {
        let entries = model.recents.entries.filter { model.directory.snapshot(id: $0.hostID) != nil }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text("Recently played")
                    .font(.title3)
                    .fontWeight(.bold)
                    .padding(.leading, leading - AppTile.Columns.inset)
                // Eager stack (at most RecentsStore.limit tiles): a lazy one built tiles only as they
                // crossed the scroll view's edge, so they popped instead of peeking into the margin.
                ScrollView(.horizontal) {
                    HStack(spacing: AppTile.Columns.gap) {
                        ForEach(entries) { entry in
                            if let snapshot = model.directory.snapshot(id: entry.hostID) {
                                let isRunning = snapshot.currentGame == entry.app.id
                                AppTile(host: snapshot.host, app: entry.app,
                                        isRunning: isRunning,
                                        isDimmed: snapshot.status == .offline,
                                        subtitle: snapshot.host.name,
                                        onQuit: isRunning ? { model.requestQuit(host: snapshot.host, app: entry.app) } : nil,
                                        onRemove: { model.recents.remove(entry) },
                                        action: { model.recentSelected(entry) })
                            }
                        }
                    }
                    // The app grid's column edges, so the first and (scrolled to the end) the last
                    // tile line up with the centered grid below.
                    .padding(.vertical, AppTile.Columns.inset)
                    .padding(.horizontal, leading)
                }
                .scrollClipDisabled()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                leading = AppTile.Columns.leading(in: width)
            }
        }
    }
}
