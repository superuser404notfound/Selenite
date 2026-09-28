import AppCore
import SwiftUI

/// Home, and everything presented over it.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        // The cover never clears activeStream itself: a system dismissal only asks the stream to
        // disconnect, and streamEnded clears it once the session has stopped. A plain binding let
        // tvOS drop a running controller, which kept its session and slot alive unseen.
        let stream = Binding<StreamController?>(
            get: { model.activeStream },
            set: {
                guard $0 == nil, let stream = model.activeStream else { return }
                DiagnosticLog.note("[menu] the system dismissed the stream cover; disconnecting")
                stream.disconnect()
            }
        )
        HomeView()
            .fullScreenCover(item: stream, onDismiss: { model.streamCoverDismissed() }) { controller in
                // The container is a GCEventViewController around the whole stream screen and
                // swallows every Menu press, so none reaches this cover's presentation.
                StreamContainer(controller: controller, model: model)
                    .ignoresSafeArea()
            }
            .menuPresentation(item: $model.pendingRemoval) { host in
                RemoveHostPrompt(host: host).environment(model)
            }
            .menuPresentation(item: $model.pendingSwitch, onDismiss: { model.presentationDismissed() }) { prompt in
                SwitchAppPrompt(prompt: prompt).environment(model)
            }
            .menuPresentation(item: $model.errorPanel, onDismiss: { model.presentationDismissed() }) { panel in
                ErrorPanel(panel: panel).environment(model)
            }
            .menuPresentation(item: $model.addHostRequest) { request in
                AddHostFlowView(request: request).environment(model)
            }
            .menuPresentation(isPresented: $model.isShowingSettings) {
                SettingsView().environment(model)
            }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(phase)
            }
    }
}
