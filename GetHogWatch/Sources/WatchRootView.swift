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

    var body: some View {
        TabView(selection: $page) {
            WatchMetricsView(model: model).tag(WatchPage.metrics)
            WatchHealthView(model: model).tag(WatchPage.health)
            WatchFlagsView(model: model).tag(WatchPage.flags)
            WatchActivityView(model: model).tag(WatchPage.activity)
        }
        .tabViewStyle(.verticalPage)
        .task { await model.refresh() }
    }

    /// Always `.metrics` in a shipped build. The DEBUG branch exists so each
    /// page can be screenshotted from a single `simctl launch` without driving
    /// the crown, which is the only way to capture a watch surface that no
    /// XCUITest gesture reaches reliably.
    private static func initialPage() -> WatchPage {
        #if DEBUG
        if let raw = WatchDemoMode.initialPage, let chosen = WatchPage(rawValue: raw) {
            return chosen
        }
        #endif
        return .metrics
    }
}
