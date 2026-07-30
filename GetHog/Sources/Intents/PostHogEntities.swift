import AppIntents
import CoreSpotlight
import Foundation
import GetHogKit

// The four things a user can name out loud: a project, a dashboard, an insight,
// a feature flag. Every one is `IndexedEntity`, so the same declaration serves
// Shortcuts pickers, Siri parameter resolution and Spotlight.
//
// Ids are always PostHog's own numeric ids resolved at runtime — nothing here
// is baked to a particular project or account.

// MARK: - Project

struct ProjectEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PostHog Project")
    static let defaultQuery = ProjectEntityQuery()

    let id: Int
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Project \(id)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.contentDescription = "PostHog project"
        set.keywords = ["PostHog", "project", name]
        return set
    }

    init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    init(_ project: Project) {
        self.init(id: project.id, name: project.name)
    }
}

// MARK: - Dashboard

struct DashboardEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dashboard")
    static let defaultQuery = DashboardEntityQuery()

    let id: Int
    let name: String
    let summary: String?
    let isPinned: Bool

    /// Path under `project/<id>/` in the web console. Used for Handoff.
    var webPath: String { "dashboard/\(id)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(summary ?? (isPinned ? "Pinned dashboard" : "PostHog dashboard"))"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.contentDescription = summary ?? "PostHog dashboard"
        set.keywords = ["PostHog", "dashboard", name]
        return set
    }

    init(id: Int, name: String, summary: String?, isPinned: Bool) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isPinned = isPinned
    }

    init(_ dashboard: DashboardSummary) {
        self.init(
            id: dashboard.id,
            name: dashboard.title,
            summary: dashboard.description?.isEmpty == false ? dashboard.description : nil,
            isPinned: dashboard.pinned
        )
    }
}

// MARK: - Insight

struct InsightEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Insight")
    static let defaultQuery = InsightEntityQuery()

    let id: Int
    let name: String
    /// PostHog's own query kind, e.g. `TrendsQuery`. Kept so a refusal can say
    /// *why* an insight has no single value rather than just declining.
    let kind: String

    var webPath: String { "insights/\(id)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(Self.readableKind(kind))")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.contentDescription = "PostHog insight · \(Self.readableKind(kind))"
        set.keywords = ["PostHog", "insight", "metric", name]
        return set
    }

    init(id: Int, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    init(_ insight: Insight) {
        self.init(id: insight.id, name: insight.title, kind: insight.sourceKind)
    }

    /// `TrendsQuery` → `Trends`. Spoken aloud by Siri, so it can't be raw API text.
    static func readableKind(_ kind: String) -> String {
        let trimmed = kind.hasSuffix("Query") ? String(kind.dropLast(5)) : kind
        return trimmed.isEmpty || trimmed == "Unknown" ? "Insight" : trimmed
    }
}

// MARK: - Feature flag

struct FeatureFlagEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Feature Flag")
    static let defaultQuery = FeatureFlagEntityQuery()

    let id: Int
    /// The flag key, which is what people actually say and search for.
    let key: String
    let name: String
    let isActive: Bool

    var webPath: String { "feature_flags/\(id)" }

    /// Whether this flag may be flipped from outside the app. Resolved from
    /// `FlagQuickToggle` at construction so pickers and Control Center can show
    /// the state without a second lookup.
    var allowsQuickToggle: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(key)",
            subtitle: "\(isActive ? "Enabled" : "Disabled")\(allowsQuickToggle ? "" : " · Quick toggle off")"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = key
        set.contentDescription = name == key ? "PostHog feature flag" : name
        set.keywords = ["PostHog", "feature flag", "flag", key]
        return set
    }

    init(id: Int, key: String, name: String, isActive: Bool, allowsQuickToggle: Bool) {
        self.id = id
        self.key = key
        self.name = name
        self.isActive = isActive
        self.allowsQuickToggle = allowsQuickToggle
    }

    init(_ flag: FeatureFlag) {
        self.init(
            id: flag.id,
            key: flag.key,
            name: flag.displayName,
            isActive: flag.active,
            allowsQuickToggle: FlagQuickToggle.isAllowed(flagID: flag.id)
        )
    }
}

// MARK: - Fetching

/// One place that turns PostHog collections into entities.
///
/// Shared by the queries below and by `SpotlightIndexer`, so a change to what
/// "the flags in this project" means lands everywhere at once.
enum PostHogEntityFetch {

    static func projects() async throws -> [ProjectEntity] {
        let client = try IntentDependencies.makeClient()
        let me: MeResponse = try await client.send(PostHogAPI.me())
        let projects = me.projects.isEmpty ? [me.currentProject].compactMap { $0 } : me.projects
        return projects.map(ProjectEntity.init)
    }

    static func dashboards(projectID: Int? = nil) async throws -> [DashboardEntity] {
        let deps = try await IntentDependencies.resolve(projectID: projectID)
        let page: Page<DashboardSummary> = try await deps.client.send(
            PostHogAPI.dashboards(projectID: deps.projectID)
        )
        return page.results.map(DashboardEntity.init)
    }

    static func insights(projectID: Int? = nil) async throws -> [InsightEntity] {
        let deps = try await IntentDependencies.resolve(projectID: projectID)
        let page: Page<Insight> = try await deps.client.send(
            PostHogAPI.insights(projectID: deps.projectID)
        )
        return page.results.map(InsightEntity.init)
    }

    static func flags(projectID: Int? = nil) async throws -> [FeatureFlagEntity] {
        let deps = try await IntentDependencies.resolve(projectID: projectID)
        let page: Page<FeatureFlag> = try await deps.client.send(
            PostHogAPI.featureFlags(projectID: deps.projectID)
        )
        // Deleted flags still come back from the API; offering one in a picker
        // would produce a write that can never succeed.
        return page.results.filter { !$0.deleted && !$0.archived }.map(FeatureFlagEntity.init)
    }
}

// MARK: - Queries

struct ProjectEntityQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [ProjectEntity] {
        let wanted = Set(identifiers)
        return try await PostHogEntityFetch.projects().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        let needle = string.lowercased()
        return try await PostHogEntityFetch.projects()
            .filter { $0.name.lowercased().contains(needle) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        try await PostHogEntityFetch.projects()
    }
}

struct DashboardEntityQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [DashboardEntity] {
        let wanted = Set(identifiers)
        return try await PostHogEntityFetch.dashboards().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [DashboardEntity] {
        let needle = string.lowercased()
        return try await PostHogEntityFetch.dashboards().filter {
            $0.name.lowercased().contains(needle)
                || ($0.summary?.lowercased().contains(needle) ?? false)
        }
    }

    func suggestedEntities() async throws -> [DashboardEntity] {
        let all = try await PostHogEntityFetch.dashboards()
        // Pinned first: that is the user's own statement about what matters.
        let pinned = all.filter(\.isPinned)
        return pinned.isEmpty ? Array(all.prefix(12)) : pinned
    }
}

struct InsightEntityQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [InsightEntity] {
        let wanted = Set(identifiers)
        return try await PostHogEntityFetch.insights().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [InsightEntity] {
        let needle = string.lowercased()
        return try await PostHogEntityFetch.insights()
            .filter { $0.name.lowercased().contains(needle) }
    }

    func suggestedEntities() async throws -> [InsightEntity] {
        Array(try await PostHogEntityFetch.insights().prefix(12))
    }
}

struct FeatureFlagEntityQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [FeatureFlagEntity] {
        let wanted = Set(identifiers)
        return try await PostHogEntityFetch.flags().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FeatureFlagEntity] {
        let needle = string.lowercased()
        return try await PostHogEntityFetch.flags().filter {
            $0.key.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
        }
    }

    /// Quick-toggle flags first. They are the only ones a Shortcut can actually
    /// change, so burying them under 100 read-only flags would be dishonest.
    func suggestedEntities() async throws -> [FeatureFlagEntity] {
        let all = try await PostHogEntityFetch.flags()
        let togglable = all.filter(\.allowsQuickToggle)
        return togglable.isEmpty ? Array(all.prefix(12)) : togglable
    }
}
