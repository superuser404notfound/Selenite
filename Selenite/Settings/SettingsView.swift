import AppCore
import StreamKit
import SwiftUI

/// Global stream settings (spec 4.3). Every row shows its value and opens a list of buttons.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsDeveloper = false

    var body: some View {
        let preferences = model.settings.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.bottom, 12)
                ValuePickerRow(icon: "rectangle.on.rectangle", title: "Resolution",
                               options: ResolutionPreference.allCases, selection: preferences.resolution,
                               label: \.label) { model.settings.set(\.resolution, $0) }
                ValuePickerRow(icon: "speedometer", title: "Frame rate",
                               options: FrameRatePreference.allCases, selection: preferences.frameRate,
                               label: \.label) { model.settings.set(\.frameRate, $0) }
                ValuePickerRow(icon: "metronome", title: "Frame pacing",
                               options: FramePacingMode.allCases, selection: preferences.pacing,
                               label: \.label) { model.settings.set(\.pacing, $0) }
                ValuePickerRow(icon: "antenna.radiowaves.left.and.right", title: "Bitrate",
                               options: StreamPreferences.bitrateChoicesMbps, selection: preferences.bitrateMbps,
                               label: { "\($0) Mbps" }) { model.settings.set(\.bitrateMbps, $0) }
                ValuePickerRow(icon: "film", title: "Codec",
                               options: CodecPreference.allCases, selection: preferences.codec,
                               label: \.label) { model.settings.set(\.codec, $0) }
                ValuePickerRow(icon: "speaker.wave.3", title: "Audio",
                               options: AudioPreference.allCases, selection: preferences.audio,
                               label: \.label) { model.settings.set(\.audio, $0) }
                ValuePickerRow(icon: "chart.bar", title: "Stream stats",
                               options: StatsPreference.allCases, selection: preferences.stats,
                               label: \.label) { model.settings.set(\.stats, $0) }
                about
                // Visually quiet, at the very bottom: experimental switches for the real streams.
                Button("Developer") { showsDeveloper = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 60)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 48)
        }
        .frame(width: 1300)
        // A host paired in the harness is saved to the same store; reload so Home shows it now.
        .fullScreenCover(isPresented: $showsDeveloper, onDismiss: { model.directory.reload() }) {
            DeveloperView(settings: model.settings)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selenite \(Self.version)")
                .fontWeight(.semibold)
            Text("Free software under the GNU GPLv3. Streaming is built on moonlight-common-c by the Moonlight Game Streaming Project, also GPLv3.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

extension ResolutionPreference {
    var label: LocalizedStringKey {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        case .matchDisplay: "Match display"
        }
    }

    var text: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        case .matchDisplay: "Match display"
        }
    }
}

extension FrameRatePreference {
    var label: LocalizedStringKey {
        switch self {
        case .fps30: "30 fps"
        case .fps60: "60 fps"
        case .matchDisplay: "Match display"
        }
    }

    var text: String {
        switch self {
        case .fps30: "30 fps"
        case .fps60: "60 fps"
        case .matchDisplay: "Match display"
        }
    }
}

extension FramePacingMode {
    var label: LocalizedStringKey {
        switch self {
        case .lowLatency: "Lowest latency"
        case .smooth: "Smooth"
        }
    }
}

extension CodecPreference {
    var label: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }

    var text: String {
        switch self {
        case .automatic: "Automatic"
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }
}

extension AudioPreference {
    var label: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic (5.1 when available)"
        case .stereo: "Stereo"
        }
    }

    var text: String {
        switch self {
        case .automatic: "Automatic (5.1 when available)"
        case .stereo: "Stereo"
        }
    }
}

extension StatsPreference {
    var label: LocalizedStringKey {
        switch self {
        case .off: "Off"
        case .compact: "Compact"
        }
    }
}
