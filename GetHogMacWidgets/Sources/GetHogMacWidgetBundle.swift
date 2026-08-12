import Foundation
import GetHogUI
import SwiftUI
import WidgetKit

#if GETHOG_UNSHARED_MAC_WIDGETS

/// One cache-free provider for the two teamless Debug cards. Placeholder,
/// snapshot and timeline all carry the same neutral entry, so the installed
/// widget can always leave redaction for an explicit unavailable state.
private struct MacDebugUnavailableEntry: TimelineEntry {
    let date: Date
}

private struct MacDebugUnavailableProvider: TimelineProvider {

    func placeholder(in context: Context) -> MacDebugUnavailableEntry {
        MacDebugUnavailableEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (MacDebugUnavailableEntry) -> Void
    ) {
        completion(MacDebugUnavailableEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<MacDebugUnavailableEntry>) -> Void
    ) {
        let now = Date()
        completion(WidgetRefresh.timeline(from: now) { MacDebugUnavailableEntry(date: $0) })
    }
}

/// These Debug-only widgets use distinct kinds because their static schema is
/// intentionally different from the signed widgets' App Intent schema. Reusing
/// a production kind would rely on an undocumented persisted-state migration
/// and could preserve the stale redacted instance this boundary removes.
private struct MacDebugMetricWidget: Widget {
    static let kind = "app.gethog.widget.debug.metric-unshared"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: MacDebugUnavailableProvider()) { _ in
            NoDataView(message: WidgetCache.noDataMessage)
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("Metric")
        .description("This Debug build can't share app data with widgets. Signed builds let you select a synced metric.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct MacDebugFlagWidget: Widget {
    static let kind = "app.gethog.widget.debug.flag-unshared"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: MacDebugUnavailableProvider()) { _ in
            NoDataView(message: WidgetCache.noDataMessage)
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("Feature Flag")
        .description("This Debug build can't share app data with widgets. Signed builds let you select an allowed flag.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#endif

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
        #if GETHOG_UNSHARED_MAC_WIDGETS
        MacDebugMetricWidget()
        HealthWidget()
        MacDebugFlagWidget()
        #else
        MetricWidget()
        HealthWidget()
        FlagWidget()
        #endif
    }
}
