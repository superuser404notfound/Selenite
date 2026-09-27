import AppCore
import SwiftUI

/// Until the first frame, and while a stream ends: the app's box art blurred behind its name and
/// the current step.
struct StreamLoadingView: View {
    @Environment(AppModel.self) private var model
    let controller: StreamController

    var body: some View {
        ZStack {
            Color.Theme.page
            AsyncCachedImage(key: "\(controller.host.id)/\(controller.app.id)",
                             load: { await model.catalog.boxArt(for: controller.host, appID: controller.app.id) }) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60)
                    .opacity(0.5)
            } placeholder: {
                Color.clear
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            VStack(spacing: 28) {
                ProgressView()
                Text(controller.app.title)
                    .font(.title)
                    .fontWeight(.bold)
                Text(statusLine)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
    }

    private var statusLine: LocalizedStringKey {
        switch controller.ending {
        case .quittingGame: return "Quitting game…"
        case .disconnecting: return "Disconnecting…"
        case nil: break
        }
        return switch controller.phase {
        case .connecting: "Connecting…"
        case .startingGame: "Starting game…"
        case .waitingForPicture, .running, .ended: "Waiting for picture…"
        }
    }
}
