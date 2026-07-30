import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets plus the iOS 18 Control Center controls.
///
/// Everything in this bundle renders from the `SharedSnapshot` the app writes to
/// the App Group container. No surface here calls the PostHog API: rate limits
/// are organisation-wide and shared with the user's own integrations, so N
/// widgets fetching independently would spend a budget that isn't ours, from
/// processes the user never launched. See `WidgetCache` for the full reasoning.
@main
struct GetHogWidgetBundle: WidgetBundle {

    var body: some Widget {
        MetricWidget()
        FlagWidget()
        FlagControl()
        OpenDashboardControl()
    }
}
