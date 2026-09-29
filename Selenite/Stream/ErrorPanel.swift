import AppCore
import SwiftUI

/// A failed start or a lost connection, back on Home (spec 4.5).
struct ErrorPanel: View {
    @Environment(AppModel.self) private var model
    let panel: ErrorPanelModel

    var body: some View {
        PromptPanel(title: panel.failure.isWakeFailure ? Text("Host did not wake up") : Text("Stream ended"),
                    message: Text(verbatim: panel.failure.message)) {
            if panel.canRetry {
                Button("Try again") { model.retryLastLaunch() }
            }
            Button("OK") { model.errorPanel = nil }
        }
    }
}

private extension StreamFailure {
    var isWakeFailure: Bool {
        if case .hostDidNotWake = self { true } else { false }
    }
}
