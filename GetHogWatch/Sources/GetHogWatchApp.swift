import SwiftUI

/// The watchOS entry point.
///
/// The model is built here rather than in a `@State` initialiser on the root
/// view because `App.init()` is the one main-actor place that runs before any
/// scene exists — and because the `WCSession` delegate has to be installed
/// before the system can deliver a hand-off the phone queued while the watch
/// app was not running.
@main
struct GetHogWatchApp: App {
    @State private var model: WatchModel

    init() {
        _model = State(initialValue: WatchModel.live())
        WatchSessionListener.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
        }
    }
}
