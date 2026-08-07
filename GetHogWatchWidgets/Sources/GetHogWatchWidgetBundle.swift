import SwiftUI
import WidgetKit

/// The watchOS complications and the Smart Stack card.
///
/// Three widgets, and the set is deliberate rather than a subset of the phone's:
///
/// - **Metric** — the number the user configured, on all four accessory
///   families, because a complication's whole job is one number at a glance.
/// - **Health** — the user's own `MetricWatch` thresholds, firing or quiet.
///   Watch-local evaluation only; see `WatchHealthEntry` for why this is not
///   `SharedSnapshot.healthVerdict`.
/// - **Alerts** — the rectangular Smart Stack card, the one surface that asks
///   the system to promote it while something is over its line.
///
/// There is **no flag widget**, and that is not an omission. Every flag the
/// watch app writes carries `quickToggleAllowed: false` — the per-flag opt-in
/// is an iOS setting with no watch UI to grant it — so `quickToggleFlags` is
/// always empty on the wrist and a flag complication could only ever offer a
/// toggle the user never allowed.
///
/// The rule the iOS, Mac and Vision bundles document holds here unchanged:
/// **this process reads the App Group snapshot and never calls the PostHog
/// API.** See `WatchWidgetCache`.
@main
struct GetHogWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchMetricComplication()
        WatchHealthComplication()
        WatchStackWidget()
    }
}
