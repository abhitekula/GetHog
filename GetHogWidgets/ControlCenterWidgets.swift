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
        // Read by `RootView.routePendingLinks()`, which lands on Dashboards and
        // clears it. That was not true when this was written — the comment here
        // called it "advisory" and nothing consumed it, so `openAppWhenRun`
        // brought the app forward onto whatever screen it was last left on. A
        // control labelled with a metric that lands you in Settings is the
        // control failing at its only job.
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

// MARK: - Project health

/// A control whose *label* is the answer.
///
/// Worth a slot for a reason the other two are not: Control Center is one swipe
/// from the Lock Screen and can be bound to the Action Button, so this is the
/// shortest path in the system to "is anything wrong". Pressing it opens the
/// app, but the press is the second-best part — a user who reads "Nothing to
/// report" and puts the phone back in their pocket got what they came for
/// without launching anything, which is the cheapest possible outcome for a
/// rate-limit budget that belongs to somebody's production integrations.
///
/// Unconfigurable on purpose. There is nothing to choose, and a control that let
/// you pick which half of the health check to display would be a way to hide the
/// failing half.
struct HealthControlValue {
    let verdict: SharedSnapshot.HealthVerdict
    let headline: String
    /// How old the answer is, in the same compact form the widgets use. Shown in
    /// the control because a verdict with no age attached is the one thing this
    /// app refuses to put on screen.
    let age: String

    static func from(_ snapshot: SharedSnapshot?, now: Date = Date()) -> HealthControlValue {
        guard let snapshot else {
            return HealthControlValue(verdict: .unchecked, headline: "Not synced", age: "never")
        }
        return HealthControlValue(
            verdict: snapshot.healthVerdict,
            headline: snapshot.healthHeadline,
            age: WidgetFreshness(capturedAt: snapshot.capturedAt, now: now).shortLabel
        )
    }

    /// Control Center gives one line and no subtitle, so the age rides with the
    /// verdict rather than being dropped.
    var title: String { "\(headline) · \(age)" }
}

struct HealthControlProvider: ControlValueProvider {

    var previewValue: HealthControlValue { .from(WidgetCache.sample) }

    /// Reads the snapshot. As everywhere in this extension, no network call.
    func currentValue() async throws -> HealthControlValue { .from(WidgetCache.snapshot()) }
}

struct OpenHealthFromControlIntent: AppIntent {

    static var title: LocalizedStringResource { "Open GetHog Health" }
    static var description: IntentDescription {
        IntentDescription("Opens GetHog so you can see what the warning is about.")
    }

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult { .result() }
}

struct ProjectHealthControl: ControlWidget {

    static let kind = "app.gethog.control.health"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: HealthControlProvider()) { value in
            ControlWidgetButton(action: OpenHealthFromControlIntent()) {
                // Glyph *and* words, and the words name the state on their own —
                // Control Center renders monochrome, so a control whose verdict
                // lived in its tint would have no verdict at all.
                Label(value.title, systemImage: value.verdict.symbolName)
            }
            .tint(WidgetPalette.tint(for: value.verdict))
        }
        .displayName("Project Health")
        .description("Ingestion warnings and quota from your last GetHog sync, with the age of the answer.")
    }
}
