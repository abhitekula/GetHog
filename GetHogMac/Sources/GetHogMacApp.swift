import GetHogKit
import GetHogUI
import SwiftUI

#if DEBUG
/// Builds launch-time models for deterministic DEBUG automation.
///
/// The force-keyless branch is first and uses both an empty, process-local
/// credential store and the bundled synthetic transport. It therefore ignores
/// credentials left in the Keychain and cannot make a network request.
@MainActor
enum MacAppModelFactory {
    static func makeModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        demoModeEnabled: Bool = DemoTransport.isEnabled
    ) -> AppModel {
        if environment["GETHOG_FORCE_KEYLESS"] == "1" {
            return AppModel(store: InMemoryTokenStore(), transport: DemoTransport())
        }

        // Demo mode drives the real UI from recorded API responses, so every
        // screen can be exercised and screenshotted without a live credential.
        if demoModeEnabled {
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

@main
struct GetHogMacApp: App {
    @State private var model: AppModel

    /// The same single instance both window groups read — see `GetHogApp.nav`
    /// for why a second copy would be a second source of truth.
    @State private var nav = NavPreferences()

    /// The menu bar's reader of the snapshot file; one for the process, owned
    /// here so the label and the popover observe the same reloads.
    @State private var menuBar = MacMenuBarController()

    /// Owns the last-window-closed rules — see `MenuBarWindowPolicy`. SwiftUI
    /// alone cannot express them: `applicationShouldTerminateAfterLastWindowClosed`
    /// has no scene-level equivalent, and the activation-policy drop is AppKit
    /// by nature.
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    init() {
        _model = State(initialValue: GetHogMacApp.makeModel())
    }

    var body: some Scene {
        // Named, because the menu bar extra opens this group by id — see
        // `MacMenuBar.openMainWindow`. One saved window frame resets on the
        // first launch after the id landed, since the autosave identity is
        // derived from it; `defaultSize` below still governs.
        WindowGroup(id: MacMenuBar.mainWindowID) {
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
                .frame(minWidth: 560, minHeight: 420)
                .environment(model)
                .environment(
                    \.projectChartTimeZone,
                    ProjectChartTimeZone.resolve(model.selectedProject?.timezone)
                )
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
                    menuBar.adoptAuthSession(model.authSessionID)
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
                .onChange(of: model.authSessionID, initial: true) { _, authSessionID in
                    // This lives above MacRootView's phase switch. Sign-out can
                    // replace that whole subtree in the same actor turn, but it
                    // cannot remove this observer before the menu bar's
                    // in-memory snapshot loses its old write authority.
                    menuBar.adoptAuthSession(authSessionID)
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
        .defaultSize(width: 1_200, height: 780)
        .windowResizability(.contentMinSize)
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
                .environment(
                    \.projectChartTimeZone,
                    ProjectChartTimeZone.resolve(model.selectedProject?.timezone)
                )
                .environment(nav)
                .insightCSVExporter()
                .tint(Theme.accent)
        }
        // Enough for a dashboard's tile grid or a replay stage beside its
        // inspector, without dwarfing the main window it was torn off from.
        // The system's own 900×450 gave a torn-off dashboard one tile column.
        .defaultSize(width: 1_000, height: 700)

        // ⌘, — the same section views and stores as iOS Settings, regrouped
        // into panes. Scenes inherit no environment from each other, so the
        // model and preferences are injected again here.
        Settings {
            MacSettingsRoot()
                .environment(model)
                .environment(nav)
                .tint(Theme.accent)
        }

        // The ambient layer (spec §4): a window-style extra whose label is the
        // user's headline metric. Reads the same snapshot file the widgets do;
        // its one refresh affordance routes through the app's own machinery,
        // and nothing in it calls the API.
        MenuBarExtra {
            MacMenuBarPopover(controller: menuBar)
                .environment(model)
                .environment(nav)
                .tint(Theme.accent)
        } label: {
            MacMenuBarLabel(controller: menuBar, authSessionID: model.authSessionID)
        }
        .menuBarExtraStyle(.window)
    }

    private static func makeModel() -> AppModel {
        #if DEBUG
        return MacAppModelFactory.makeModel()
        #else
        // DEBUG launch environment seams do not exist in the shipped binary.
        return AppModel()
        #endif
    }
}
