import GetHogKit
import GetHogUI
import SwiftUI

#if DEBUG
/// Builds launch-time models for deterministic DEBUG automation.
///
/// The force-keyless branch is first and uses both an empty, process-local
/// credential store and the bundled synthetic transport. It therefore ignores
/// credentials left in the simulator Keychain and cannot make a network request.
@MainActor
enum TVAppModelFactory {
    static func makeModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        demoModeEnabled: Bool = DemoTransport.isEnabled
    ) -> AppModel {
        if environment["GETHOG_FORCE_KEYLESS"] == "1" {
            return AppModel(store: InMemoryTokenStore(), transport: DemoTransport())
        }

        if demoModeEnabled {
            return AppModel(
                store: InMemoryTokenStore(
                    credential: StoredCredential(key: "demo", region: .usCloud)
                ),
                transport: DemoTransport()
            )
        }

        if let key = environment["GETHOG_API_KEY"], !key.isEmpty {
            let region: PostHogRegion = switch environment["GETHOG_REGION"]?.lowercased() {
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

        return AppModel()
    }
}
#endif

/// The tvOS entry point: `GetHogVisionApp` minus everything that needs a second
/// window, a browser or a background wake.
///
/// One `WindowGroup`, because `openWindow` is unavailable on tvOS and there is
/// one screen to put a window on. No `insightCSVExporter()` — the exporter it
/// hosts is compiled to the identity here, since `.fileExporter` does not exist
/// on the platform. The one `onOpenURL` route belongs to Top Shelf and lands on
/// Dashboards; there is no Handoff continuation or intent plumbing because
/// tvOS delivers neither. No background scheduler: this shell schedules no
/// unattended wake, which is why `BackgroundRefresh`'s twin in
/// `TVAdaptations` is a true no-op rather than a stub. Foreground and Ambient
/// refreshes are still real app-owned requests, coalesced below through the
/// same shared policy and `RateLimitGovernor` as every other shell.
@main
struct GetHogTVApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var snapshotRefresh = TVSnapshotRefreshCoordinator()

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
                .environment(
                    \.projectChartTimeZone,
                    ProjectChartTimeZone.resolve(model.selectedProject?.timezone)
                )
                .environment(nav)
                .environment(snapshotRefresh)
                .tint(Theme.accent)
                .task {
                    AppTips.configure()
                    await model.bootstrap()
                }
                // The shelf is only visible after the app leaves the screen;
                // by `.background` the snapshot write has settled.
                .onChange(of: scenePhase) { _, phase in
                    TVTopShelfRefresh.notifyIfNeeded(for: phase)
                    if phase != .active {
                        snapshotRefresh.cancel()
                    }
                }
                // A foreground return is a chance to replace a stale shared
                // snapshot. `AppModel` performs the fetch through its one
                // session governor; the TV coordinator adds attempt-level
                // coalescing so this trigger cannot race Ambient's clock.
                .task(id: scenePhase) {
                    guard scenePhase == .active, model.phase == .ready else { return }
                    let now = Date()
                    _ = await snapshotRefresh.refreshIfDue(
                        now: now,
                        lastSnapshotAt: model.lastSnapshotDate
                    ) {
                        await model.performBackgroundRefresh(now: now)
                    }
                }
        }
    }

    private static func makeModel() -> AppModel {
        #if DEBUG
        return TVAppModelFactory.makeModel()
        #else
        // DEBUG launch environment seams do not exist in the shipped binary.
        return AppModel()
        #endif
    }
}
