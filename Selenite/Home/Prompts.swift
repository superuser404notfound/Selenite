import HostKit
import SwiftUI

struct RemoveHostPrompt: View {
    @Environment(AppModel.self) private var model
    let host: PairedHost

    var body: some View {
        PromptPanel(title: Text("Remove \(host.name)?"),
                    message: Text("Selenite forgets this host. Pair it again to stream from it.")) {
            Button("Remove", role: .destructive) { model.removeHost(host) }
            Button("Cancel") { model.pendingRemoval = nil }
        }
    }
}

/// Another game runs on the host: starting this one would quit it.
struct SwitchAppPrompt: View {
    @Environment(AppModel.self) private var model
    let prompt: AppSwitchPrompt

    var body: some View {
        PromptPanel(title: Text("Quit the running game?"), message: message) {
            Button("Quit and start \(prompt.app.title)", role: .destructive) { model.confirmSwitch(prompt) }
            Button("Cancel") { model.pendingSwitch = nil }
        }
    }

    private var message: Text {
        if let running = prompt.runningTitle {
            return Text("\(running) is running on \(prompt.host.name). Starting \(prompt.app.title) quits it.")
        }
        return Text("Another game is running on \(prompt.host.name). Starting \(prompt.app.title) quits it.")
    }
}
