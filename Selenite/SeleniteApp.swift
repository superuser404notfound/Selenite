import AppCore
import SwiftUI

@main
struct SeleniteApp: App {
    @State private var model: AppModel

    init() {
        DiagnosticLog.installMoonlightSink()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.cyan)
        }
    }
}
