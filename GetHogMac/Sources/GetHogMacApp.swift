import GetHogKit
import SwiftUI

@main
struct GetHogMacApp: App {
    @State private var model: AppModel

    /// The same single instance both window groups read — see `GetHogApp.nav`
    /// for why a second copy would be a second source of truth.
    @State private var nav = NavPreferences()

    @Environment(\.scenePhase) private var scenePhase

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
                // The inbound half of Handoff. An iPhone publishing the console
                // URL for the screen it is on is continued here, and lands on
                // that object's own screen — see `HandoffModifier`.
                .onContinueUserActivity(HandoffActivity.browsing) { activity in
                    guard let url = HandoffActivity.continuationURL(from: activity) else { return }
                    LinkInbox.deliver(url)
                }
                .task {
                    #if DEBUG
                    // Staged into the same inbox a real link uses, so a
                    // screenshot run exercises the production routing.
                    if let url = DebugLaunch.openURL { LinkInbox.deliver(url) }
                    #endif
                    AppTips.configure()
                    await model.bootstrap()
                    // After bootstrap, because the schedule stands every wake
                    // down while there is no credential and the model only
                    // knows whether it has one once it has looked.
                    MacBackgroundRefresh.shared.start(model: model)
                    if let projectID = model.projectID {
                        await SpotlightIndexer.reindex(projectID: projectID)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // A widget-recorded toggle needs the keychain, the governor
                    // and somewhere to show a 403 — all here, none in an
                    // extension. Inert until phase 2 ships one, cheap now.
                    if phase == .active {
                        Task { await model.consumePendingIntentWork() }
                        // Idempotent by construction, which is what lets a
                        // sign-in mid-session re-arm the clock that sign-out
                        // invalidated without anybody tracking which happened.
                        MacBackgroundRefresh.shared.start(model: model)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: IntentDependencies.selectedProjectDidChangeNotification
                    )
                ) { _ in
                    model.adoptExternallySelectedProject()
                }
        }
        // Wide enough for a sidebar and a two-column screen beside it. The
        // system's own default came up 900×450, which puts the seven split-view
        // screens into their narrowest shape on first launch.
        .defaultSize(width: 1_280, height: 820)
        // The menu bar. Attached to the main window group but app-wide by
        // nature; every item reads the key window's focused values, so the
        // tear-off and Settings scenes participate exactly as much as they
        // publish (see FocusedCommandValues.swift).
        .commands { MacCommands() }

        // Tear-off windows, sharing the one AppModel — one client, one
        // rate-limit governor, one cache, exactly as on iPad.
        WindowGroup(for: WindowTarget.self) { $target in
            DetachedWindowView(target: target)
                .environment(model)
                .environment(nav)
                .insightCSVExporter()
                .tint(Theme.accent)
        }

        // ⌘, — the same section views and stores as iOS Settings, regrouped
        // into panes. Scenes inherit no environment from each other, so the
        // model and preferences are injected again here.
        Settings {
            MacSettingsRoot()
                .environment(model)
                .environment(nav)
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
