import GetHogKit
import GetHogUI
import SwiftUI

/// The tvOS entry point: `GetHogVisionApp` minus everything that needs a second
/// window, a browser or a background wake.
///
/// One `WindowGroup`, because `openWindow` is unavailable on tvOS and there is
/// one screen to put a window on. No `insightCSVExporter()` — the exporter it
/// hosts is compiled to the identity here, since `.fileExporter` does not exist
/// on the platform. The one `onOpenURL` route belongs to Top Shelf and lands on
/// Dashboards; there is no Handoff continuation or intent plumbing because
/// tvOS delivers neither. No refresh scheduler: this shell schedules no
/// background wake, which is why `BackgroundRefresh`'s twin in `TVAdaptations`
/// is a true no-op rather than a stub.
@main
struct GetHogTVApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    /// Created and handed down even though this shell reads no tab-slot
    /// preference: several ridden screens take it out of the environment, and a
    /// missing `@Observable` environment is a crash rather than a nil.
    @State private var nav = NavPreferences()

    init() {
        _model = State(initialValue: GetHogTVApp.makeModel())
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .environment(nav)
                .tint(Theme.accent)
                .task {
                    AppTips.configure()
                    await model.bootstrap()
                }
                // The shelf is only visible after the app leaves the screen;
                // by `.background` the snapshot write has settled.
                .onChange(of: scenePhase) { _, phase in
                    TVTopShelfRefresh.notifyIfNeeded(for: phase)
                }
        }
    }

    private static func makeModel() -> AppModel {
        #if DEBUG
        // Demo mode drives the real UI from recorded API responses, so every
        // screen can be exercised and screenshotted without a live credential.
        if DemoTransport.isEnabled {
            return AppModel(
                store: InMemoryTokenStore(
                    credential: StoredCredential(key: "demo", region: .usCloud)
                ),
                transport: DemoTransport()
            )
        }

        // Live end-to-end runs against a real project without going through key
        // entry each launch; in-memory on purpose so the key dies with the
        // process. See `GetHogApp.makeModel`.
        let env = ProcessInfo.processInfo.environment
        if let key = env["GETHOG_API_KEY"], !key.isEmpty {
            let region: PostHogRegion = switch env["GETHOG_REGION"]?.lowercased() {
            case "eu": .euCloud
            case let host? where host.hasPrefix("http"):
                URL(string: host).map { PostHogRegion.selfHosted($0) } ?? .usCloud
            default: .usCloud
            }
            return AppModel(
                store: InMemoryTokenStore(
                    credential: StoredCredential(key: key, region: region)
                )
            )
        }
        #endif
        return AppModel()
    }
}
