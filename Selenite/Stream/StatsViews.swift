import AppCore
import StreamKit
import SwiftUI

/// The full stats list (M3-A spec): three groups, each with a small secondary heading, Grid rows
/// with monospaced digits. Used by the solo overlay, every split overlay column and
/// `FullStatsPanel`. Refreshed once per second by `StreamController`.
struct OverlayStats: View {
    let stats: StreamStatsSummary
    let pacing: FramePacingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Video") {
                GridRow {
                    Text("Resolution")
                    Text(verbatim: "\(stats.width)x\(stats.height)")
                }
                GridRow {
                    Text("Frame rate")
                    Text("\(stats.fps) fps")
                }
                GridRow {
                    Text("Codec")
                    Text(stats.codec.label)
                }
                GridRow {
                    Text("Frame pacing")
                    Text(pacing.label)
                }
                GridRow {
                    Text("Bitrate")
                    Text("\(StatsFormat.megabits(stats.measuredBitrateMbps)) of \(stats.bitrateMbps) Mbps")
                }
            }
            group("Latency") {
                GridRow {
                    Text("Host")
                    hostLatency
                }
                GridRow {
                    Text("Network receive")
                    optionalMilliseconds(stats.networkMilliseconds)
                }
                GridRow {
                    Text("Decode")
                    Text("\(StatsFormat.milliseconds(stats.decodeMilliseconds)) ms")
                }
                GridRow {
                    Text("Display wait")
                    optionalMilliseconds(stats.displayMilliseconds)
                }
                GridRow {
                    Text("Round trip")
                    roundTrip
                }
            }
            group("Quality") {
                GridRow {
                    Text("Jitter")
                    Text("\(StatsFormat.milliseconds(stats.jitterMilliseconds)) ms")
                }
                GridRow {
                    Text("Dropped frames")
                    Text("\(stats.networkDrops) network, \(stats.queueDrops) queue, \(stats.pacerDrops) pacer")
                }
                GridRow {
                    Text("Unrecoverable frames")
                    Text(verbatim: "\(stats.unrecoverableFrames)")
                }
                GridRow {
                    Text("Stalls")
                    Text(verbatim: "\(stats.stalls)")
                }
                GridRow {
                    Text("Audio underruns")
                    Text(verbatim: "\(stats.audioUnderruns)")
                }
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var hostLatency: some View {
        if let latency = stats.hostLatency {
            Text("\(StatsFormat.milliseconds(latency.mean)) ms (\(StatsFormat.milliseconds(latency.min)) to \(StatsFormat.milliseconds(latency.max)))")
        } else {
            Text("n/a")
        }
    }

    @ViewBuilder private var roundTrip: some View {
        if let rtt = stats.rttMilliseconds {
            if let variance = stats.rttVarianceMilliseconds {
                Text("\(rtt) ± \(variance) ms")
            } else {
                Text("\(rtt) ms")
            }
        } else {
            Text("n/a")
        }
    }

    @ViewBuilder private func optionalMilliseconds(_ value: Double?) -> some View {
        if let value {
            Text("\(StatsFormat.milliseconds(value)) ms")
        } else {
            Text("n/a")
        }
    }

    private func group(_ heading: LocalizedStringKey, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.caption2)
                .fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                rows()
            }
        }
    }
}

/// Top right while running: fps, measured bitrate, decode time, round trip and total drops.
struct CompactStatsPill: View {
    let stats: StreamStatsSummary

    var body: some View {
        HStack(spacing: 20) {
            Text("\(stats.fps) fps")
            Text("\(StatsFormat.megabits(stats.measuredBitrateMbps)) Mbps")
            Text("\(StatsFormat.milliseconds(stats.decodeMilliseconds)) ms decode")
            if let rtt = stats.rttMilliseconds {
                Text("RTT \(rtt) ms")
            } else {
                Text("RTT n/a")
            }
            Text("\(stats.networkDrops + stats.queueDrops + stats.pacerDrops) drops")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// The Full stats level: `OverlayStats` on a glass card, for the top-right HUD (solo and per split
/// half) rather than the bottom overlay panel, which already supplies its own background.
struct FullStatsPanel: View {
    let stats: StreamStatsSummary
    let pacing: FramePacingMode

    var body: some View {
        OverlayStats(stats: stats, pacing: pacing)
            .font(.caption)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

/// The top-right stats HUD for a running stream, solo or one split half: nothing, the compact pill
/// or the full panel. At Full, a half narrower than the panel falls back to the pill instead of
/// overflowing or clipping.
struct StatsHUD: View {
    let level: StatsPreference
    let stats: StreamStatsSummary?
    let pacing: FramePacingMode

    var body: some View {
        if let stats {
            switch level {
            case .off:
                EmptyView()
            case .compact:
                CompactStatsPill(stats: stats)
            case .full:
                ViewThatFits(in: .horizontal) {
                    FullStatsPanel(stats: stats, pacing: pacing)
                    CompactStatsPill(stats: stats)
                }
            }
        }
    }
}

enum StatsFormat {
    static func milliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func megabits(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

extension VideoCodec {
    var label: LocalizedStringKey {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }
}
