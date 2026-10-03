import AppCore
import HostKit
import StreamKit
import SwiftUI

/// One host's stream settings (M3-A spec, section 3): each row either follows the global value or
/// overrides it. Pacing and stats stay device-wide and are not listed.
struct HostSettingsView: View {
    @Environment(AppModel.self) private var model
    let host: PairedHost

    private enum Choice<Value: Hashable>: Hashable {
        case global
        case value(Value)
    }

    var body: some View {
        let global = model.settings.preferences
        let overrides = model.hostSettings.overrides(for: host.id)
        VStack(alignment: .leading, spacing: 20) {
            Text("Stream settings for \(host.name)")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.bottom, 12)
            row(icon: "rectangle.on.rectangle", title: "Resolution", all: ResolutionPreference.allCases,
                current: overrides.resolution, global: global.resolution, label: \.label, text: \.text) { value in
                    update { $0.resolution = value }
                }
            row(icon: "speedometer", title: "Frame rate", all: FrameRatePreference.allCases,
                current: overrides.frameRate, global: global.frameRate, label: \.label, text: \.text) { value in
                    update { $0.frameRate = value }
                }
            row(icon: "antenna.radiowaves.left.and.right", title: "Bitrate", all: StreamPreferences.bitrateChoicesMbps,
                current: overrides.bitrateMbps, global: global.bitrateMbps, label: { "\($0) Mbps" },
                text: { String(localized: "\($0) Mbps") }) { value in
                    update { $0.bitrateMbps = value }
                }
            row(icon: "film", title: "Codec", all: CodecPreference.allCases,
                current: overrides.codec, global: global.codec, label: \.label, text: \.text) { value in
                    update { $0.codec = value }
                }
            row(icon: "speaker.wave.3", title: "Audio", all: AudioPreference.allCases,
                current: overrides.audio, global: global.audio, label: \.label, text: \.text) { value in
                    update { $0.audio = value }
                }
            if model.hostSettings.hasOverrides(hostID: host.id) {
                Button("Reset to global") { model.hostSettings.set(HostOverrides(), for: host.id) }
                    .padding(.top, 24)
            }
            Text("In split screen only the codec applies; the bitrate there is half the global one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 48)
        .frame(width: 1300)
    }

    private func update(_ change: (inout HostOverrides) -> Void) {
        var overrides = model.hostSettings.overrides(for: host.id)
        change(&overrides)
        model.hostSettings.set(overrides, for: host.id)
    }

    /// `label` is the row-list text per option; `text` is the plain string used to spell out the
    /// global value inside "Use global (…)", since `LocalizedStringKey` cannot be read back as a
    /// `String`.
    private func row<Value: Hashable>(icon: String, title: LocalizedStringKey, all: [Value], current: Value?,
                                      global: Value, label: @escaping (Value) -> LocalizedStringKey,
                                      text: @escaping (Value) -> String,
                                      onSelect: @escaping (Value?) -> Void) -> some View {
        let options: [Choice<Value>] = [.global] + all.map { .value($0) }
        return ValuePickerRow(icon: icon, title: title, options: options,
                              selection: current.map { .value($0) } ?? .global,
                              label: { choice in
                                  switch choice {
                                  case .global: "Use global (\(text(global)))"
                                  case .value(let value): label(value)
                                  }
                              }, isHighlighted: current != nil) { choice in
            switch choice {
            case .global: onSelect(nil)
            case .value(let value): onSelect(value)
            }
        }
    }
}
