import GetHogKit
import SwiftUI

@main
struct GetHogMacApp: App {
    @State private var model: AppModel

    /// The same single instance both window groups read — see `GetHogApp.nav`
    /// for why a second copy would be a second source of truth.
    @State private var nav = NavPreferences()

    init() {
        _model = State(initialValue: GetHogMacApp.makeModel())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // Same solo-window diagnostic the iOS app carries, and for the
                // same reason: telling a screen's layout problem apart from
                // one caused by the shell around it.
                if let target = DebugLaunch.soloWindowTarget {
                    DetachedWindowView(target: target)
                } else {
                    MacRootView()
                }
                #else
                MacRootView()
                #endif
            }
                .environment(model)
                .environment(nav)
                .insightCSVExporter()
                .tint(Theme.accent)
                .onOpenURL { LinkInbox.deliver($0) }
                .task { await model.bootstrap() }
        }

        // Tear-off windows, sharing the one AppModel — one client, one
        // rate-limit governor, one cache, exactly as on iPad.
        WindowGroup(for: WindowTarget.self) { $target in
            DetachedWindowView(target: target)
                .environment(model)
                .environment(nav)
                .insightCSVExporter()
                .tint(Theme.accent)
        }

        // Empty until Task 4 moves the settings surface in; declared now so
        // the app has the standard Settings menu item from the first build.
        Settings {
            EmptyView()
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

        // Live end-to-end runs against a real project without going through
        // onboarding each launch; in-memory on purpose so the key dies with
        // the process. See GetHogApp.makeModel.
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
