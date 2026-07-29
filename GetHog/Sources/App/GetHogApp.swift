import SwiftUI

@main
struct GetHogApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.bootstrap() }
        }
    }
}
