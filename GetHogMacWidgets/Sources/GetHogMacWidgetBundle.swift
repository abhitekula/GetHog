import SwiftUI
import WidgetKit

/// Desktop widgets: the same three portable widgets iOS ships, rendering the
/// same `SharedSnapshot` files. The Control Center controls are absent because
/// the surface is — `ControlWidget` does not exist on macOS, and
/// `ControlCenterWidgets.swift` is excluded from this target for that reason,
/// not seamed. The Lock Screen accessory families are gone for the same kind of
/// reason: the SDK marks every one of them `@available(macOS, unavailable)`.
///
/// Everything here renders from the snapshot the app writes to the App Group
/// container. No surface in this process calls the PostHog API: rate limits are
/// organisation-wide and shared with the user's own integrations, so N widgets
/// fetching independently would spend a budget that isn't ours, from a process
/// the user never launched. The entitlements make that structural rather than
/// merely intended — this target carries no `com.apple.security.network.client`
/// at all. See `WidgetCache`: the rule and its consequences are identical on
/// every platform that grows a widget.
@main
struct GetHogMacWidgetBundle: WidgetBundle {

    var body: some Widget {
        MetricWidget()
        HealthWidget()
        FlagWidget()
    }
}
