import GetHogKit
import SwiftUI

@main
struct GetHogApp: App {
    @State private var model = GetHogApp.makeModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // Renders one screen outside the tab bar and split view, to tell
                // a layout problem in a screen apart from one caused by the
                // containers around it.
                if let target = DebugLaunch.soloWindowTarget {
                    DetachedWindowView(target: target)
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .environment(model)
                .tint(Theme.accent)
                .task {
                    await model.bootstrap()
                    if let projectID = model.projectID {
                        await SpotlightIndexer.reindex(projectID: projectID)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // A widget or Control Center toggle can only record its
                    // intent; the write itself needs the keychain, the rate-limit
                    // governor and somewhere to surface a 403 — all of which
                    // exist here and not in the extension.
                    Task { await model.consumePendingIntentWork() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: IntentDependencies.selectedProjectDidChangeNotification
                    )
                ) { _ in
                    // A Focus filter can switch projects while the app is running.
                    model.adoptExternallySelectedProject()
                }
        }

        // Tear-off windows for iPad and Stage Manager. They share the one
        // `AppModel`, and therefore one client, one rate-limit governor and one
        // cache: a window that built its own stack would double this app's draw
        // on a request budget that belongs to the whole organisation.
        WindowGroup(for: WindowTarget.self) { $target in
            DetachedWindowView(target: target)
                .environment(model)
                .tint(Theme.accent)
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
        // onboarding each launch. Supplied per-launch via the environment so the
        // key is never written to the repo, a plist, or the Keychain:
        //
        //   xcrun simctl launch --console <udid> app.gethog.GetHog \
        //     GETHOG_API_KEY=phx_… GETHOG_REGION=us
        //
        // DEBUG-only, and deliberately an in-memory store so it dies with the run.
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
