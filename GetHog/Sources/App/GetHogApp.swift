import GetHogKit
import GetHogUI
import SwiftUI

@main
struct GetHogApp: App {
    @State private var model: AppModel

    /// Which four screens the tab bar holds.
    ///
    /// Owned here, beside `model`, and injected into both window groups from the
    /// same instance - a second `NavPreferences` would be a second object, and a
    /// tear-off window reading a different copy of the arrangement is the class
    /// of bug the shared `AppModel` above exists to avoid.
    @State private var nav = NavPreferences()

    /// Exists for one reason: home screen quick actions have no other way in.
    /// `GetHogAppDelegate` names a scene delegate, which is the only object
    /// iOS will hand a `UIApplicationShortcutItem` to once a scene manifest is
    /// present. See `LinkInbox.swift`.
    @UIApplicationDelegateAdaptor(GetHogAppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = GetHogApp.makeModel()
        _model = State(initialValue: model)
    }

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
                .environment(
                    \.projectChartTimeZone,
                    ProjectChartTimeZone.resolve(model.selectedProject?.timezone)
                )
                // Injected here, above `RootView` entirely, for the reason
                // `AppModel` is: `RootView` presents sheets, and a `.sheet`
                // attached *outside* an `.environment` is not in that subtree -
                // a non-optional `@Environment(NavPreferences.self)` in sheet
                // content would trap on presentation, with no GetHog frame in
                // the crash report.
                .environment(nav)
                // "Save to Files" is triggered from menu content, which is torn
                // down the instant the menu closes — the sheet has to be owned
                // by something that outlives it.
                .insightCSVExporter()
                .tint(Theme.accent)
                // Both the `gethog://` scheme and a posthog.com URL shared
                // into the app. Posted rather than routed here: on a cold launch
                // this fires before `bootstrap()` has found a project to resolve
                // the link against, so `RootView` takes it once it is ready.
                .onOpenURL { LinkInbox.deliver($0) }
                // PostHog Cloud OAuth callback, when this build configures
                // one. A different activity type from Handoff, so the two
                // never compete; an unconsumed activity simply falls through.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    _ = OAuthActivityRouter.route(activity, directory: OAuthDirectory.resolve())
                }
                // The inbound half of Handoff, and the reason
                // `NSUserActivityTypes` in the Info.plist is not a one-way
                // claim. `HandoffModifier` publishes the console URL for the
                // screen being looked at; a second device running GetHog
                // continues it here and lands on that object's *own* screen,
                // because the continued `webpageURL` is exactly the posthog.com
                // URL `LinkInbox` and `PostHogLinkParser` already accept from a
                // paste or a share. Anything else — a Mac with no GetHog —
                // opens the same URL in a browser, which is what `webpageURL`
                // means and needs no code here at all.
                //
                // Declared without it, the plist key would still make iOS offer
                // this app as a continuation target and then leave the user on
                // whatever screen the app happened to open on.
                .onContinueUserActivity(HandoffActivity.browsing) { activity in
                    guard let url = HandoffActivity.continuationURL(from: activity) else { return }
                    LinkInbox.deliver(url)
                }
                .task {
                    #if DEBUG
                    // Staged into the same inbox a real link uses, so a
                    // screenshot run exercises the production routing rather
                    // than a parallel path that could pass while it is broken.
                    if let url = DebugLaunch.openURL { LinkInbox.deliver(url) }
                    #endif
                    AppTips.configure()
                    await model.bootstrap()
                    if let projectID = model.projectID {
                        await SpotlightIndexer.reindex(projectID: projectID)
                    }
                    QuickActions.refresh(projectID: model.projectID)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // A widget or Control Center toggle can only record its
                        // intent; the write itself needs the keychain, the rate-limit
                        // governor and somewhere to surface a 403 — all of which
                        // exist here and not in the extension.
                        Task { await model.consumePendingIntentWork() }
                    default:
                        break
                    }
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
                .environment(
                    \.projectChartTimeZone,
                    ProjectChartTimeZone.resolve(model.selectedProject?.timezone)
                )
                // The same instance as the main window's, not a second one.
                .environment(nav)
                .insightCSVExporter()
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
