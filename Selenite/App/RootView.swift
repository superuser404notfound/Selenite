import AppCore
import SwiftUI

/// Home, and everything presented over it.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        HomeView()
            .menuPresentation(item: $model.pendingRemoval) { host in
                RemoveHostPrompt(host: host).environment(model)
            }
            .menuPresentation(item: $model.pendingSwitch, onDismiss: { model.presentationDismissed() }) { prompt in
                SwitchAppPrompt(prompt: prompt).environment(model)
            }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(phase)
            }
    }
}
