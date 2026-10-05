import AppCore
import HostKit
import SwiftUI

/// Developer tools for the real app, reachable from Settings.
struct DeveloperView: View {
    @State private var wakeReport: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
        .frame(maxWidth: 1300, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 60)
        .padding(.top, 40)
        // Opaque: the cover sits over Settings and Home, which otherwise showed through.
        .background(Color.Theme.page.ignoresSafeArea())
        .onExitCommand { dismiss() }
    }
}
