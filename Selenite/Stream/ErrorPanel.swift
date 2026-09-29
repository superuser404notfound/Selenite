import AppCore
import SwiftUI

/// A failed start or a lost connection, back on Home (spec 4.5).
struct ErrorPanel: View {
    @Environment(AppModel.self) private var model
    let panel: ErrorPanelModel

    var body: some View {
        PromptPanel(title: title,
                    message: Text(verbatim: panel.failure.message)) {
            if panel.canRetry {
                Button("Try again") { model.retryLastLaunch() }
            }
            Button("OK") { model.errorPanel = nil }
        }
    }

    private var title: Text {
        if panel.failure.isWakeFailure { return Text("Host did not wake up") }
        if panel.failure == .quitFailed { return Text("Game did not quit") }
        return Text("Stream ended")
    }
}

private extension StreamFailure {
    var isWakeFailure: Bool {
        if case .hostDidNotWake = self { true } else { false }
    }
}
