import SwiftUI

@main
struct SeleniteApp: App {
    @State private var model = HarnessModel()

    var body: some Scene {
        WindowGroup {
            HarnessView()
                .environment(model)
        }
    }
}
