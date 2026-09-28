import AppCore
import SwiftUI

/// The M0/M1-A harness, reachable from Settings so split screen stays testable until M2 replaces
/// it (spec, section 2). It keeps its own model and controller wiring. Above it sit the
/// experimental switches for the real app's streams.
struct DeveloperView: View {
    let settings: SettingsStore
    @State private var harness = HarnessModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !harness.isStreaming {
                ValuePickerRow(icon: "bolt", title: "Present on arrival (experimental)",
                               options: [false, true], selection: settings.preferences.directPresent,
                               label: { $0 ? "On" : "Off" }) { settings.set(\.directPresent, $0) }
                    .frame(maxWidth: 1300)
                    .padding(.horizontal, 60)
                    .padding(.top, 40)
            }
            HarnessView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Opaque: the cover sits over Settings and Home, which otherwise showed through.
        .background(Color.Theme.page.ignoresSafeArea())
        .environment(harness)
        // While the harness streams, its stage consumes Menu and ends the stream first.
        .onExitCommand {
            if !harness.isStreaming { dismiss() }
        }
        .onDisappear {
            Task { await harness.stop() }
        }
    }
}
