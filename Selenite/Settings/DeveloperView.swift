import SwiftUI

/// The M0/M1-A harness, reachable from Settings so split screen stays testable until M2 replaces
/// it (spec, section 2). It keeps its own model and controller wiring.
struct DeveloperView: View {
    @State private var harness = HarnessModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HarnessView()
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
