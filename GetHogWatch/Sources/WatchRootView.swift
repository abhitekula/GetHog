import GetHogKit
import GetHogUI
import SwiftUI

enum WatchPage: String, CaseIterable, Hashable {
    case metrics, health, flags, activity
}

/// The whole shell: four vertical pages, which is the watchOS idiom for a set
/// of peer screens with no hierarchy between them.
///
/// Each page owns a zero-depth `NavigationStack` for its title bar and nothing
/// pushes deeper than one screen anywhere on the watch — a wrist has no room
/// for a back stack, and every question this app answers on it fits on one
/// page by design.
struct WatchRootView: View {
    let model: WatchModel
    @State private var page: WatchPage = WatchRootView.initialPage()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $page) {
            WatchMetricsView(model: model).tag(WatchPage.metrics)
            WatchHealthView(model: model).tag(WatchPage.health)
            WatchFlagsView(model: model).tag(WatchPage.flags)
            WatchActivityView(model: model).tag(WatchPage.activity)
        }
        .tabViewStyle(.verticalPage)
        .task { await model.refresh() }
        .task { await adoptHandoffs() }
        // A watch app is suspended the moment the wrist drops and resumed on
        // the next raise, without the scene being rebuilt — so `.task` fires
        // once and only once, and every glance after the first was rendering
        // whatever the launch had fetched. The 15-minute throttle is what
        // makes this safe to attach: a resume asks the store how old the
        // snapshot is before it asks PostHog anything.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.reconcile(WatchHandoff.current())
                    await model.refresh()
                }
                return
            }
            // Leaving the wrist is the moment to ask for the next unattended
            // wake: the app is about to stop being able to refresh itself, and
            // `WatchRefresh` will decline if there is no credential or a
            // request is already outstanding.
            guard phase == .background else { return }
            WatchRefresh.scheduleNextWake(
                hasCredential: model.hasCredential,
                lastRefreshedAt: model.snapshot?.capturedAt
            )
        }
    }

    /// Adopts a hand-off that landed while the app was running.
    ///
    /// The `WCSession` callback writes the keychain, the watch list and the
    /// defaults from a background queue and posts; this is the only thing
    /// listening, and it re-reads all three rather than trusting a payload —
    /// so a running app and a fresh launch resolve their state identically.
    private func adoptHandoffs() async {
        let applied = NotificationCenter.default.notifications(
            named: .gethogWatchKeyTransferApplied
        )
        // Subscription exists before this read. If activation delivered and
        // committed a transfer before the view was built, its notification is
        // gone but its higher committed revision and stores remain; reconcile
        // adopts them before waiting for the next notification.
        await model.reconcile(WatchHandoff.current())
        for await _ in applied {
            await model.reconcile(WatchHandoff.current())
        }
    }

    /// Always `.metrics` in a shipped build. The DEBUG branch isolates each
    /// page for deterministic render checks and manual screenshots; the UI
    /// suite separately proves the real vertical pager with bounded right-edge
    /// swipes on both the 46 mm and 40 mm simulators.
    private static func initialPage() -> WatchPage {
        #if DEBUG
        if let raw = WatchDemoMode.initialPage, let chosen = WatchPage(rawValue: raw) {
            return chosen
        }
        #endif
        return .metrics
    }
}
