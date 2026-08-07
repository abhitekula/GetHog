import SwiftUI
import WidgetKit

/// Vision widgets: the same three portable widgets iOS and the Mac ship,
/// rendering the same `SharedSnapshot` files, in their default treatments —
/// no mounting style, level of detail or spatial texture is adopted, because
/// nothing here needs one to be honest.
///
/// The Control Center controls are absent because the surface is: the SDK
/// marks `ControlWidget` `@available(visionOS, unavailable)`, so
/// `ControlCenterWidgets.swift` is excluded from this target outright rather
/// than seamed — exactly what the Mac target does, for the same annotation on
/// its own platform. The Lock Screen accessory families go the same way and
/// need no seam of their own: visionOS `WidgetFamily` declares only the
/// `system*` cases, so the `#else` arm the shared widgets already take on
/// macOS is the arm that compiles here too.
///
/// Everything renders from the snapshot the app writes to the App Group
/// container. No surface in this process calls the PostHog API: rate limits
/// are organisation-wide and shared with the user's own integrations, so N
/// widgets fetching independently would spend a budget that isn't ours, from a
/// process the user never launched. The entitlements make that structural
/// rather than merely intended — this target carries no
/// `com.apple.security.network.client` at all. See `WidgetCache`: the rule and
/// its consequences are identical on every platform that grows a widget.
@main
struct GetHogVisionWidgetBundle: WidgetBundle {

    var body: some Widget {
        MetricWidget()
        HealthWidget()
        FlagWidget()
    }
}
