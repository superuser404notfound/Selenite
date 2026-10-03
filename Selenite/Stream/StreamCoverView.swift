import AppCore
import QuartzCore
import StreamKit
import SwiftUI

/// The full-screen stream (spec 4.4): the surface, the loading view until the first frame, the
/// compact stats and poor-connection indicators, and the overlay. Hosted by `StreamContainer`,
/// which owns every Menu press on this screen.
struct StreamCoverView: View {
    @Environment(AppModel.self) private var model
    let controller: StreamController

    var body: some View {
        ZStack {
            StreamSurface(controller: controller, isOverlayOpen: controller.isOverlayOpen)
                .ignoresSafeArea()
            if isLoading {
                StreamLoadingView(controller: controller)
                    .transition(.opacity)
            }
            if controller.phase == .running, controller.ending == nil {
                StreamIndicators(controller: controller, level: model.settings.preferences.stats)
            }
            if controller.isOverlayOpen {
                StreamOverlayView(controller: controller)
                    .transition(.opacity)
            }
        }
        .background(Color.Theme.page.ignoresSafeArea())
        .animation(.easeOut(duration: 0.4), value: controller.phase)
        .animation(.easeOut(duration: 0.4), value: controller.ending)
        .animation(.easeInOut(duration: 0.2), value: controller.isOverlayOpen)
    }

    /// Also while ending: the loading view says what the stop is waiting for.
    private var isLoading: Bool {
        if controller.ending != nil { return true }
        return switch controller.phase {
        case .connecting, .startingGame, .waitingForPicture: true
        case .running, .ended: false
        }
    }
}

/// Top right while running: the poor-connection symbol while it lasts, and the stats HUD. The HUD
/// yields to the Menu overlay while it is open (same stats, no point behind it); the poor-connection
/// symbol stays, it means something different.
private struct StreamIndicators: View {
    let controller: StreamController
    let level: StatsPreference

    var body: some View {
        VStack {
            HStack(spacing: 16) {
                Spacer()
                if controller.isPoorConnection {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(Color.Theme.warning)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                }
                if !controller.isOverlayOpen {
                    StatsHUD(level: level, stats: controller.liveStats, pacing: controller.settings.pacing)
                }
            }
            Spacer()
        }
        .padding(48)
        .allowsHitTesting(false)
    }
}
