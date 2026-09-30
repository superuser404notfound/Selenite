import AppCore
import SwiftUI

/// Home, and everything presented over it.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        let streaming = model.activeStream != nil || model.activeSplit != nil
        ZStack {
            HomeView()
                // Out of focus reach while a stream runs, so focus can only be on the stream.
                .disabled(streaming)
                .opacity(streaming ? 0 : 1)
            // In place, never presented: tvOS dismisses any presentation on the Siri Remote's
            // Menu. streamEnded clears activeStream once the session has stopped.
            if let stream = model.activeStream {
                StreamContainer(controller: stream, model: model)
                    .ignoresSafeArea()
                    .id(ObjectIdentifier(stream))
            }
            if let split = model.activeSplit {
                SplitContainer(split: split, model: model)
                    .ignoresSafeArea()
                    .id(ObjectIdentifier(split))
            }
        }
        .onChange(of: streaming) { _, isStreaming in
            if !isStreaming { model.streamCoverDismissed() }
        }
        .onChange(of: model.activeSplit == nil) { _, isGone in
            if isGone { model.splitCoverDismissed() }
        }
            .menuPresentation(item: $model.pendingRemoval) { host in
                RemoveHostPrompt(host: host).environment(model)
            }
            .menuPresentation(item: $model.pendingSwitch, onDismiss: { model.presentationDismissed() }) { prompt in
                SwitchAppPrompt(prompt: prompt).environment(model)
            }
            .menuPresentation(item: $model.pendingQuit, onDismiss: { model.quitPromptDismissed() }) { prompt in
                QuitGamePrompt(prompt: prompt).environment(model)
            }
            .menuPresentation(item: $model.errorPanel, onDismiss: { model.presentationDismissed() }) { panel in
                ErrorPanel(panel: panel).environment(model)
            }
            .menuPresentation(item: $model.addHostRequest) { request in
                AddHostFlowView(request: request).environment(model)
            }
            .menuPresentation(isPresented: $model.isShowingWake, onDismiss: { model.wakePanelDismissed() }) {
                WakePanel(hostName: model.wakingHostName, forGame: model.isWakingForGame).environment(model)
            }
            .menuPresentation(item: $model.splitWizard, panel: .plain, onDismiss: { model.splitWizardDismissed() }) { wizard in
                SplitWizardView(wizard: wizard).environment(model)
            }
            .menuPresentation(isPresented: $model.isShowingSettings) {
                SettingsView().environment(model)
            }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(phase)
            }
    }
}
