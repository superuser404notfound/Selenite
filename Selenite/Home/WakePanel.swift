import AppCore
import SwiftUI

/// "Waking…" while a sleeping host is asked to come up. Menu or Cancel stops waking.
struct WakePanel: View {
    @Environment(AppModel.self) private var model
    let hostName: String
    let forGame: Bool

    var body: some View {
        PromptPanel(title: Text("Waking \(hostName)…"),
                    message: forGame ? Text("The game starts as soon as the PC answers.")
                        : Text("Selenite continues as soon as the PC answers.")) {
            ProgressView()
            Button("Cancel") { model.cancelWake() }
        }
    }
}
