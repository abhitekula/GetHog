import GetHogKit
import SwiftUI

// The two switches every shell needs and no shell owns. They were properties of
// `RootView` until the Mac arrived; that file is iOS-only — it reads `UIDevice`,
// the size class and the tab bar's minimize behavior — and is excluded from the
// Mac target, so a `MacRootView` that named these could not see them. Lifted
// verbatim rather than copied, for the reason `AppTab` and `OpenDetails` were:
// two mappings from tab to screen would drift the first time a screen was added
// to one of them.

/// The screen a tab names.
///
/// One switch rather than a view written into each `Tab` declaration: the iPad
/// sidebar, the Mac sidebar and the iPhone index all resolve tabs through here,
/// and a second mapping would be a second thing to keep in step.
struct TabRootView: View {
    let tab: AppTab

    var body: some View {
        switch tab {
        case .dashboards: DashboardsRoot()
        case .insights: InsightsRoot()
        case .events: EventsRoot()
        case .sessions: SessionsRoot()
        case .flags: FlagsRoot()
        case .webAnalytics: WebAnalyticsRoot()
        case .clickmap: HeatmapsRoot()
        case .people: PeopleRoot()
        case .groups: GroupsRoot()
        case .sql: SQLConsoleRoot()
        case .errorTracking: ErrorTrackingRoot()
        case .sessionSummaries: SessionSummariesRoot()
        case .llm: LLMAnalyticsRoot()
        case .tracing: TracingRoot()
        case .logs: LogsRoot()
        case .support: SupportRoot()
        case .inbox: InboxRoot()
        case .signals: SignalsRoot()
        case .health: HealthRoot()
        case .ingestion: IngestionWarningsRoot()
        case .warehouse: WarehouseRoot()
        case .pipelines: PipelinesRoot()
        case .automation: AutomationRoot()
        case .actions: ActionsRoot()
        case .annotations: AnnotationsRoot()
        case .taxonomy: TaxonomyRoot()
        case .experiments: ExperimentsRoot()
        case .surveys: SurveysRoot()
        case .earlyAccess: EarlyAccessRoot()
        case .notebooks: NotebooksRoot()
        case .max: ConversationsRoot()
        case .renders: RendersRoot()
        case .templates: DashboardTemplatesRoot()
        case .settings: SettingsRoot()
        case .search:
            // Reached through `RootView.searchTab`, which owns the stack this
            // screen's own rows push into. Nothing ever pushes `.search` itself,
            // so this case exists only to keep the switch honest.
            ProjectSearchView()
        }
    }
}

/// A sheet detail and the screen it belongs to.
///
/// `Identifiable` off the whole value rather than off the detail alone, so the
/// sheet is rebuilt when the screen changes even in the impossible case that two
/// screens' details compare equal.
struct PresentedDetail: Hashable, Identifiable {
    let tab: AppTab
    let detail: AnyHashable

    var id: Self { self }
}

/// The sheet a secondary screen has open, built from the tab that owns it.
///
/// One switch rather than a closure stored beside the value, for the reason
/// `TabRootView` is one switch: a stored `() -> AnyView` would make `OpenDetails`
/// hold view-building code for four screens, and the box has to stay a box — it
/// is shared with every screen that pushes, and with the split views that
/// adopted it first.
///
/// "Sheet" is the iOS ending only. `MacRootView` builds the same four details
/// from the same values and *pushes* them — see `DetailSheetContainer`, which is
/// what lets one detail view be both.
struct DetailSheetView: View {
    let presented: PresentedDetail

    @Environment(AppModel.self) private var model

    var body: some View {
        switch presented.tab {
        case .surveys:
            if let survey = presented.detail as? Survey {
                SurveyDetailSheet(
                    survey: survey,
                    webURL: model.webURL(path: "surveys/\(survey.id)")
                )
            }
        case .experiments:
            if let experiment = presented.detail as? Experiment {
                ExperimentDetailSheet(
                    experiment: experiment,
                    webURL: model.webURL(path: "experiments/\(experiment.id)")
                )
            }
        case .llm:
            if let trace = presented.detail as? LLMTrace {
                LLMTraceDetailSheet(
                    trace: trace,
                    webURL: model.webURL(path: "llm-analytics/traces/\(trace.id)")
                )
            }
        case .pipelines:
            if let function = presented.detail as? HogFunction {
                PipelineDetailSheet(
                    function: function,
                    webURL: model.webURL(path: pipelineWebPath(for: function))
                )
            }
        default:
            // Unreachable: `presentedDetail` only builds a `PresentedDetail` for
            // a tab whose `presentsDetailAsSheet` is true. Drawing nothing beats
            // a `fatalError` for a case a future tab could add by omission.
            EmptyView()
        }
    }
}
