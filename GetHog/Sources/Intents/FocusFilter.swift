import AppIntents
import Foundation

/// Binds GetHog's active project to a Focus mode.
///
/// The use it exists for: a Work Focus pins the production project, a Personal
/// Focus pins the side project, and nobody has to remember which one the app was
/// last left on. iOS runs this when the Focus changes, so the switch has to
/// happen through shared storage rather than through `AppModel`, which may not
/// exist at that moment.
struct ProjectFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Select PostHog Project"
    static let description = IntentDescription(
        "Choose which PostHog project GetHog shows while this Focus is on."
    )

    /// Optional so a Focus can be configured before a project is picked, and so
    /// clearing the filter is expressible.
    @Parameter(title: "Project")
    var project: ProjectEntity?

    var displayRepresentation: DisplayRepresentation {
        guard let project else {
            return DisplayRepresentation(
                title: "PostHog project",
                subtitle: "No project chosen"
            )
        }
        return DisplayRepresentation(
            title: "\(project.name)",
            subtitle: "GetHog shows this project"
        )
    }

    /// One suggestion per project the credential can reach, so the Focus setup
    /// sheet is useful on first open instead of an empty picker.
    static func suggestedFocusFilters(
        for context: FocusFilterSuggestionContext
    ) async -> [ProjectFocusFilter] {
        guard let projects = try? await PostHogEntityFetch.projects() else { return [] }
        return projects.map { project in
            let filter = ProjectFocusFilter()
            filter.project = project
            return filter
        }
    }

    func perform() async throws -> some IntentResult {
        // A Focus with no project chosen must leave the current selection alone;
        // resetting it would make turning a Focus on destructive.
        guard let project else { return .result() }

        IntentDependencies.persistSelectedProject(project.id)
        NotificationCenter.default.post(
            name: IntentDependencies.selectedProjectDidChangeNotification,
            object: nil
        )
        return .result()
    }
}
