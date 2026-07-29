import GetHogKit
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case dashboards, events, sessions, flags, settings

    var title: String {
        switch self {
        case .dashboards: "Dashboards"
        case .events: "Events"
        // Deliberately "Sessions", not "Replays": the tab must never promise
        // video before the player has loaded, and mobile-source recordings can
        // never be played at all.
        case .sessions: "Sessions"
        case .flags: "Flags"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboards: "square.grid.2x2"
        case .events: "bolt"
        case .sessions: "rectangle.stack"
        case .flags: "flag"
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
            TabView(selection: $selectedTab) {
                Tab(AppTab.dashboards.title, systemImage: AppTab.dashboards.systemImage, value: .dashboards) {
                    DashboardsRoot()
                }
                Tab(AppTab.events.title, systemImage: AppTab.events.systemImage, value: .events) {
                    EventsRoot()
                }
                Tab(AppTab.sessions.title, systemImage: AppTab.sessions.systemImage, value: .sessions) {
                    SessionsRoot()
                }
                Tab(AppTab.flags.title, systemImage: AppTab.flags.systemImage, value: .flags) {
                    FlagsRoot()
                }
                Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: .settings) {
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
