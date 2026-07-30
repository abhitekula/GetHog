import AppIntents
import GetHogKit
import SwiftUI
import WidgetKit

// MARK: - Flag toggle

/// Control Center's copy of the widget configuration. A separate intent type
/// because controls configure themselves through `ControlConfigurationIntent`,
/// but it resolves against the same opted-in list: a flag the user has not
/// allowed quick toggling for cannot reach Control Center, where there is no
/// confirmation step and a mis-tap is one swipe away from the Lock Screen.
struct SelectFlagControlIntent: ControlConfigurationIntent {

    static var title: LocalizedStringResource { "Select Feature Flag" }
    static var description: IntentDescription {
        IntentDescription("Choose a flag you have allowed to be toggled from outside the app.")
    }

    @Parameter(title: "Feature Flag")
    var flag: WidgetFlagEntity?

    init() {}

    init(flag: WidgetFlagEntity?) {
        self.flag = flag
    }
}

struct FlagControlValue {
    /// `nil` when nothing is synced or the flag's opt-in has been revoked. The
    /// control then renders as unavailable instead of implying it can toggle
    /// something it cannot.
    let flag: SharedSnapshot.Flag?

    var key: String { flag?.key ?? "No flag" }
    var isOn: Bool { flag?.active ?? false }
    var isAvailable: Bool { flag != nil }

    /// The toggle's target. Nil when unavailable, so a press records nothing.
    var entity: WidgetFlagEntity? { flag.map(WidgetFlagEntity.init) }
}

struct FlagControlProvider: AppIntentControlValueProvider {

    func previewValue(configuration: SelectFlagControlIntent) -> FlagControlValue {
        FlagControlValue(
            flag: .init(id: 0, key: configuration.flag?.key ?? "new-onboarding", active: true, quickToggleAllowed: true)
        )
    }

    /// Reads the snapshot. As everywhere in this extension, no network call.
    func currentValue(configuration: SelectFlagControlIntent) async throws -> FlagControlValue {
        FlagControlValue(flag: WidgetCache.quickToggleFlag(id: configuration.flag?.id))
    }
}

struct FlagControl: ControlWidget {

    static let kind = "app.gethog.control.flag"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: FlagControlProvider()
        ) { value in
            ControlWidgetToggle(
                value.key,
                isOn: value.isOn,
                action: ToggleFlagFromWidgetIntent(flag: value.entity, value: !value.isOn)
            ) { isOn in
                // Symbol *and* label: Control Center renders monochrome, so the
                // fill state alone would be the only clue and colour none at all.
                Label(
                    value.isAvailable ? (isOn ? "Enabled" : "Disabled") : "Not available",
                    systemImage: isOn ? "flag.pattern.checkered" : "flag.slash"
                )
            }
            .tint(WidgetPalette.accent)
        }
        .displayName("Feature Flag")
        .description("Toggle a PostHog feature flag you have allowed quick toggling for. GetHog opens to make the change.")
    }
}

// MARK: - Open a dashboard

/// The dashboard the button opens.
///
/// The choosable set is the metrics in the snapshot, because that is the whole
/// of what this extension knows — it cannot list dashboards it has never been
/// told about, and it will not go and ask. With nothing chosen the button opens
/// the dashboards home, which is a useful default rather than a dead end.
struct SelectDashboardControlIntent: ControlConfigurationIntent {

    static var title: LocalizedStringResource { "Select Dashboard" }
    static var description: IntentDescription {
        IntentDescription("Choose which metric's dashboard the button opens.")
    }

    @Parameter(title: "Metric")
    var metric: WidgetMetricEntity?

    init() {}

    init(metric: WidgetMetricEntity?) {
        self.metric = metric
    }
}

struct OpenMetricFromControlIntent: AppIntent {

    static var title: LocalizedStringResource { "Open Dashboard" }
    static var description: IntentDescription {
        IntentDescription("Opens GetHog at a dashboard.")
    }

    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Metric")
    var metricID: String?

    init() {}

    init(metricID: String?) {
        self.metricID = metricID
    }

    func perform() async throws -> some IntentResult {
        // Advisory: the app reads this to choose a landing screen. If it never
        // does, the button still opens the app, which is most of the value.
        WidgetCache.store.requestOpen(PendingOpen(metricID: metricID, requestedAt: Date()))
        return .result()
    }
}

struct DashboardControlValue {
    let title: String
    /// `nil` opens the dashboards home.
    let metricID: String?

    static let home = DashboardControlValue(title: "Dashboards", metricID: nil)
}

struct DashboardControlProvider: AppIntentControlValueProvider {

    func previewValue(configuration: SelectDashboardControlIntent) -> DashboardControlValue {
        guard let metric = configuration.metric else { return .home }
        return DashboardControlValue(title: metric.title, metricID: metric.id)
    }

    func currentValue(configuration: SelectDashboardControlIntent) async throws -> DashboardControlValue {
        // Resolve through the snapshot: a metric that has since disappeared
        // should send the user to the dashboards home, not to a dead screen.
        guard let id = configuration.metric?.id,
              let metric = WidgetCache.snapshot()?.metric(id: id) else { return .home }
        return DashboardControlValue(title: metric.title, metricID: metric.id)
    }
}

struct OpenDashboardControl: ControlWidget {

    static let kind = "app.gethog.control.dashboard"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: DashboardControlProvider()
        ) { value in
            ControlWidgetButton(action: OpenMetricFromControlIntent(metricID: value.metricID)) {
                Label(value.title, systemImage: "chart.xyaxis.line")
            }
        }
        .displayName("Open Dashboard")
        .description("Opens GetHog at a dashboard.")
    }
}
