import AppCore
import SwiftUI

/// A failed start or a lost connection, back on Home (spec 4.5).
struct ErrorPanel: View {
    @Environment(AppModel.self) private var model
    let panel: ErrorPanelModel

    var body: some View {
        PromptPanel(title: Text("Stream ended"), message: Text(verbatim: panel.failure.message)) {
            if panel.canRetry {
                Button("Try again") { model.retryLastLaunch() }
            }
            Button("OK") { model.errorPanel = nil }
        }
    }
}
