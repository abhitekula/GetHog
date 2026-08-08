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
enum VisionAppModelFactory {
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

/// The visionOS entry point: `GetHogMacApp` minus everything AppKit gave it —
/// no delegate adaptor, no `Settings` scene, no `MenuBarExtra`, no `.commands`
/// — plus the iOS background-refresh wiring, because visionOS speaks
/// `BGTaskScheduler` rather than `NSBackgroundActivityScheduler`.
@main
struct GetHogVisionApp: App {
    @State private var model: AppModel

    /// The same single instance both window groups read — see `GetHogApp.nav`
    /// for why a second copy would be a second source of truth.
    @State private var nav = NavPreferences()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = GetHogVisionApp.makeModel()
        _model = State(initialValue: model)
        // `BGTaskScheduler` requires every handler to be registered before the
        // app finishes launching, so this cannot wait for a `.task` on a view.
        VisionRefresh.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // The same solo-window diagnostic the other two shells carry,
                // for the same reason: telling a screen's layout problem apart
                // from one caused by the shell around it.
                if let target = DebugLaunch.soloWindowTarget {
                    DetachedWindowView(target: target)
                } else {
                    VisionRootView()
                }
                #else
                VisionRootView()
                #endif
            }
                .environment(model)
                .environment(
                    \.projectChartTimeZone,
                    ProjectChartTimeZone.resolve(model.selectedProject?.timezone)
                )
                .environment(nav)
                // "Save to Files" is triggered from menu content, which is torn
                // down the instant the menu closes — the sheet has to be owned
                // by something that outlives it.
                .insightCSVExporter()
                .tint(Theme.accent)
                // Posted rather than routed here: on a cold launch this fires
                // before `bootstrap()` has found a project to resolve the link
                // against, so the shell takes it once it is ready.
                .onOpenURL { LinkInbox.deliver($0) }
                // The inbound half of Handoff. A phone publishing the console
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
                    if let projectID = model.projectID {
                        await SpotlightIndexer.reindex(projectID: projectID)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // A widget or intent toggle can only record its intent;
                        // the write itself needs the keychain, the rate-limit
                        // governor and somewhere to surface a 403 — all of which
                        // exist here and not in an extension.
                        Task { await model.consumePendingIntentWork() }
                    case .background:
                        // The only moment the system accepts a request for the
                        // next wake — the same discipline as iOS. Dated from the
                        // snapshot the app has just been keeping current, so a
                        // session spent looking at live data does not also buy a
                        // background refresh of it.
                        VisionRefresh.schedule(model: model, refreshedAt: model.lastSnapshotDate)
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
        // Wide enough for a sidebar and a two-column screen beside it — the
        // Mac's measured number, reused because the screens are the same ones.
        // A size, not a placement: where a window opens in space is the
        // system's business.
        .defaultSize(width: 1_280, height: 820)

        // Tear-off windows, sharing the one `AppModel` — and therefore one
        // client, one rate-limit governor and one cache, exactly as on iPad and
        // the Mac.
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
        // Enough for a dashboard's tile grid or a replay stage beside its
        // inspector, without dwarfing the window it was torn off from.
        .defaultSize(width: 1_000, height: 700)
    }

    private static func makeModel() -> AppModel {
        #if DEBUG
        return VisionAppModelFactory.makeModel()
        #else
        // DEBUG launch environment seams do not exist in the shipped binary.
        return AppModel()
        #endif
    }
}
