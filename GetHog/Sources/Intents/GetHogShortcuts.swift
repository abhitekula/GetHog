import AppIntents

/// The phrases Siri accepts without the user building a Shortcut first.
///
/// Every phrase must contain `\(.applicationName)`; iOS silently drops the ones
/// that don't, which looks like Siri "not learning" the app. Wording stays in
/// the user's vocabulary — "metric", "dashboard", "flag" — rather than PostHog's
/// API nouns, because these are spoken, not read.
struct GetHogShortcuts: AppShortcutsProvider {

    /// Matches the app tint, so the Shortcuts tile doesn't read as a stranger.
    static let shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDashboardIntent(),
            phrases: [
                "Show my \(.applicationName) dashboard",
                "Open my \(.applicationName) dashboard",
                "Open a dashboard in \(.applicationName)",
            ],
            shortTitle: "Open Dashboard",
            systemImageName: "square.grid.2x2"
        )

        AppShortcut(
            intent: GetMetricValueIntent(),
            phrases: [
                "What's my \(.applicationName) metric",
                "Check a metric in \(.applicationName)",
                "Show a \(.applicationName) insight",
            ],
            shortTitle: "Get Metric",
            systemImageName: "chart.line.uptrend.xyaxis"
        )

        AppShortcut(
            intent: SetFeatureFlagIntent(),
            phrases: [
                "Set a feature flag in \(.applicationName)",
                "Toggle a \(.applicationName) feature flag",
            ],
            shortTitle: "Set Feature Flag",
            systemImageName: "flag.2.crossed"
        )

        AppShortcut(
            intent: SearchEventsIntent(),
            phrases: [
                "Search \(.applicationName) events",
                "Find recent events in \(.applicationName)",
            ],
            shortTitle: "Search Events",
            // Not `bolt.magnifyingglass`: no such symbol, and a Shortcuts tile
            // that names one draws a blank square in an app the user never
            // opened to find out why. The magnifying-glass family has no `bolt`
            // compound at all, so the search half is what survives — and it is
            // the half the tile is about.
            systemImageName: "magnifyingglass"
        )
    }
}
