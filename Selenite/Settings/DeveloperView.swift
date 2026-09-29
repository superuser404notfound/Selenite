import AppCore
import HostKit
import SwiftUI

/// The M0/M1-A harness, reachable from Settings so split screen stays testable until M2 replaces
/// it (spec, section 2). It keeps its own model and controller wiring. Above it sit the
/// experimental switches for the real app's streams.
struct DeveloperView: View {
    let settings: SettingsStore
    @State private var harness = HarnessModel()
    @State private var wakeReport: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !harness.isStreaming {
                VStack(alignment: .leading, spacing: 20) {
                    ValuePickerRow(icon: "bolt", title: "Present on arrival (experimental)",
                                   options: [false, true], selection: settings.preferences.directPresent,
                                   label: { $0 ? "On" : "Off" }) { settings.set(\.directPresent, $0) }
                    Button("Send Wake-on-LAN to saved hosts") {
                        Task {
                            let report = await Task.detached { () -> String in
                                HostStore().all().map { host in
                                    let results = WakeOnLAN.wake(host)
                                    let detail = results.isEmpty ? "no MAC"
                                        : results.map { "\($0.destination) \($0.errorCode.map { "errno \($0)" } ?? "ok")" }
                                            .joined(separator: ", ")
                                    return "\(host.name) (\(host.macAddress ?? "-")): \(detail)"
                                }.joined(separator: "\n")
                            }.value
                            DiagnosticLog.note("wake test: \(report)")
                            wakeReport = report
                        }
                    }
                    if let wakeReport {
                        Text(verbatim: wakeReport)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
