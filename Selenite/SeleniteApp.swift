import AppCore
import SwiftUI

@main
struct SeleniteApp: App {
    @State private var model = HarnessModel()

    init() {
        DiagnosticLog.installMoonlightSink()
    }

    var body: some Scene {
        WindowGroup {
            HarnessView()
                .environment(model)
        }
    }
}
