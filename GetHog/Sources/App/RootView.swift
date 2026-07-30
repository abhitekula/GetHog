import GetHogKit
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case dashboards, events, sessions, flags
    case webAnalytics, people, sql
    case errorTracking
    case experiments, surveys
    case llm, warehouse, pipelines
    case settings

    var title: String {
        switch self {
        case .dashboards: "Dashboards"
        case .events: "Events"
        // Deliberately "Sessions", not "Replays": the tab must never promise
        // video before the player has loaded, and mobile-source recordings can
        // never be played at all.
        case .sessions: "Sessions"
        case .flags: "Flags"
        case .webAnalytics: "Web"
        case .people: "People"
        case .sql: "SQL"
        case .errorTracking: "Errors"
        case .experiments: "Experiments"
        case .surveys: "Surveys"
        case .llm: "LLM"
        case .warehouse: "Warehouse"
        case .pipelines: "Pipelines"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboards: "square.grid.2x2"
        case .events: "bolt"
        case .sessions: "rectangle.stack"
        case .flags: "flag"
        case .webAnalytics: "globe"
        case .people: "person.2"
        case .sql: "terminal"
        case .errorTracking: "exclamationmark.triangle"
        case .experiments: "flask"
        case .surveys: "list.clipboard"
        case .llm: "brain"
        case .warehouse: "cylinder.split.1x2"
        case .pipelines: "arrow.triangle.branch"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("selectedTab") private var selectedTab: AppTab = .dashboards

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Connecting…")
                .controlSize(.large)

        case .onboarding:
            OnboardingView()

        case .ready:
            // `.sidebarAdaptable` is the whole iPad story: a bottom tab bar on
            // iPhone and a collapsible sidebar on iPad from one declaration.
            //
            // The four primary tabs stay loose so they occupy the iPhone tab bar
            // directly; everything else is grouped into sections, which iPhone
            // folds under "More" and iPad lays out in the sidebar. That keeps the
            // surface growable without ever crowding the phone.
            TabView(selection: $selectedTab) {
                Tab(AppTab.dashboards.title, systemImage: AppTab.dashboards.systemImage, value: AppTab.dashboards) {
                    DashboardsRoot()
                }
                Tab(AppTab.events.title, systemImage: AppTab.events.systemImage, value: AppTab.events) {
                    EventsRoot()
                }
                Tab(AppTab.sessions.title, systemImage: AppTab.sessions.systemImage, value: AppTab.sessions) {
                    SessionsRoot()
                }
                Tab(AppTab.flags.title, systemImage: AppTab.flags.systemImage, value: AppTab.flags) {
                    FlagsRoot()
                }

                TabSection("Analyze") {
                    Tab(AppTab.webAnalytics.title, systemImage: AppTab.webAnalytics.systemImage, value: AppTab.webAnalytics) {
                        WebAnalyticsRoot()
                    }
                    Tab(AppTab.people.title, systemImage: AppTab.people.systemImage, value: AppTab.people) {
                        PeopleRoot()
                    }
                    Tab(AppTab.sql.title, systemImage: AppTab.sql.systemImage, value: AppTab.sql) {
                        SQLConsoleRoot()
                    }
                }

                TabSection("Monitor") {
                    Tab(AppTab.errorTracking.title, systemImage: AppTab.errorTracking.systemImage, value: AppTab.errorTracking) {
                        ErrorTrackingRoot()
                    }
                    Tab(AppTab.llm.title, systemImage: AppTab.llm.systemImage, value: AppTab.llm) {
                        LLMAnalyticsRoot()
                    }
                }

                TabSection("Data") {
                    Tab(AppTab.warehouse.title, systemImage: AppTab.warehouse.systemImage, value: AppTab.warehouse) {
                        WarehouseRoot()
                    }
                    Tab(AppTab.pipelines.title, systemImage: AppTab.pipelines.systemImage, value: AppTab.pipelines) {
                        PipelinesRoot()
                    }
                }

                TabSection("Experiment") {
                    Tab(AppTab.experiments.title, systemImage: AppTab.experiments.systemImage, value: AppTab.experiments) {
                        ExperimentsRoot()
                    }
                    Tab(AppTab.surveys.title, systemImage: AppTab.surveys.systemImage, value: AppTab.surveys) {
                        SurveysRoot()
                    }
                }

                Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                    SettingsRoot()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }
}

/// Always-visible project context.
///
/// Showing one project's numbers under another project's name is a correctness
/// bug, not a cosmetic one, so this sits in the toolbar of every root screen.
struct ProjectSwitcher: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Project", selection: Binding(
                    get: { model.selectedProject?.id ?? -1 },
                    set: { id in
                        model.selectedProject = model.projects.first { $0.id == id }
                    }
                )) {
                    ForEach(model.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                if let org = model.me?.organization?.name {
                    Divider()
                    Text(org)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedProject?.name ?? "Project")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            .accessibilityLabel("Current project: \(model.selectedProject?.name ?? "none"). Double tap to switch.")
        }
    }
}
