import AppCore
import SwiftUI

/// The full-screen stream (spec 4.4): the surface, the loading view until the first frame, the
/// compact stats and poor-connection indicators, and the overlay.
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
                StreamIndicators(controller: controller, showsStats: model.settings.preferences.stats == .compact)
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

/// Top right while running: the poor-connection symbol while it lasts, and the compact stats pill.
private struct StreamIndicators: View {
    let controller: StreamController
    let showsStats: Bool

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
                if showsStats, let stats = controller.liveStats {
                    CompactStatsPill(stats: stats)
                }
            }
            Spacer()
        }
        .padding(48)
        .allowsHitTesting(false)
    }
}

struct CompactStatsPill: View {
    let stats: StreamStatsSummary

    var body: some View {
        HStack(spacing: 20) {
            Text("\(stats.fps) fps")
            Text("\(StatsFormat.milliseconds(stats.decodeMilliseconds)) ms decode")
            if let rtt = stats.rttMilliseconds {
                Text("RTT \(rtt) ms")
            } else {
                Text("RTT n/a")
            }
            Text("\(stats.networkDrops + stats.pacerDrops) drops")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

enum StatsFormat {
    static func milliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
