import GetHogKit
import GetHogUI
import SwiftUI

private struct DashboardSummaryTrigger: Equatable {
    let projectID: Int?
    let dashboardCount: Int
    let pinnedID: Int?
}

/// The complete authority for a cached dashboard-preview response.
/// Dashboard ids repeat across projects and hosts, and a replacement
/// credential may reuse both, so all three authority components are load
/// identity rather than metadata.
struct DashboardPreviewScope: Hashable, Sendable {
    let authority: ResourceRequestAuthority
    let dashboardID: Int
}

@MainActor
@Observable
final class DashboardPreviewStore {
    private struct LoadFlight {
        let id: UInt64
        let scope: DashboardPreviewScope
        let task: Task<Void, Never>
    }

    private static let reuseInterval: TimeInterval = 5 * 60

    private(set) var state: QuickPreviewEnrichment<Dashboard> = .idle
    private let now: @MainActor () -> Date
    private var activeScope: DashboardPreviewScope?
    private var operationToken: UInt64 = 0
    private var nextFlightID: UInt64 = 0
    private var loadFlight: LoadFlight?

    init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
    }

    /// The root retains each store across preview remounts. A remounted caller
    /// joins the store-owned task; a deliberate activation after five minutes
    /// spends one new cached request, never a compute request.
    func activate(
        client: PostHogClient?,
        scope: DashboardPreviewScope?
    ) async {
        guard let client, let scope, client.region == scope.authority.region else {
            invalidate()
            return
        }

        if let loadFlight, loadFlight.scope == scope {
            await loadFlight.task.value
            return
        }
        if activeScope == scope,
           case .loaded(let dashboard, let loadedAt) = state,
           dashboard.id == scope.dashboardID,
           now().timeIntervalSince(loadedAt) < Self.reuseInterval {
            return
        }

        let retained: (dashboard: Dashboard?, loadedAt: Date?)
        if activeScope == scope {
            retained = retainedValue
        } else {
            loadFlight?.task.cancel()
            retained = (nil, nil)
        }

        operationToken &+= 1
        let token = operationToken
        activeScope = scope
        state = .loading(previous: retained.dashboard, loadedAt: retained.loadedAt)
        nextFlightID += 1
        let flightID = nextFlightID
        let task = Task { @MainActor in
            await self.performLoad(
                client: client,
                scope: scope,
                token: token,
                previous: retained.dashboard,
                previousLoadedAt: retained.loadedAt
            )
        }
        loadFlight = LoadFlight(id: flightID, scope: scope, task: task)
        await task.value
        if loadFlight?.id == flightID {
            loadFlight = nil
        }
    }

    func invalidate() {
        operationToken &+= 1
        loadFlight?.task.cancel()
        loadFlight = nil
        activeScope = nil
        state = .idle
    }

    /// The state a surface may render for its current request authority.
    /// SwiftUI can recompute with a new project or authentication session
    /// before the replacement `.task` begins, so publication fencing alone is
    /// not enough: an unqualified retained value must be hidden synchronously.
    func state(for scope: DashboardPreviewScope?) -> QuickPreviewEnrichment<Dashboard> {
        guard let scope, activeScope == scope else { return .idle }
        return state
    }

    private func performLoad(
        client: PostHogClient,
        scope: DashboardPreviewScope,
        token: UInt64,
        previous: Dashboard?,
        previousLoadedAt: Date?
    ) async {
        do {
            let loaded: Dashboard = try await client.sendCached(
                PostHogAPI.dashboard(
                    projectID: scope.authority.projectID,
                    dashboardID: scope.dashboardID,
                    refresh: false
                ),
                ttl: Self.reuseInterval
            )
            guard owns(scope: scope, token: token), !Task.isCancelled else { return }
            state = .loaded(loaded, loadedAt: now())
        } catch is CancellationError {
            // Changing or closing a preview is ordinary interaction. The new
            // activation (or invalidation) already owns the visible state.
        } catch {
            guard owns(scope: scope, token: token), !Task.isCancelled else { return }
            if let previous, let previousLoadedAt {
                state = .stale(previous, loadedAt: previousLoadedAt)
            } else {
                state = .unavailable
            }
        }
    }

    private var retainedValue: (dashboard: Dashboard?, loadedAt: Date?) {
        switch state {
        case .loaded(let dashboard, let loadedAt),
             .stale(let dashboard, let loadedAt):
            (dashboard, loadedAt)
        case .loading(let dashboard, let loadedAt):
            (dashboard, loadedAt)
        case .idle, .unavailable:
            (nil, nil)
        }
    }

    private func owns(scope: DashboardPreviewScope, token: UInt64) -> Bool {
        activeScope == scope && operationToken == token
    }
}

/// The project signal shown at the top of the dashboard hub.
///
/// It previously showed `ContentUnavailableView("Select a dashboard")` across
/// two thirds of a 13-inch canvas — a placeholder occupying the largest, most
/// prominent surface in the app. This replaces it with the most useful thing
/// that can be shown for free.
///
/// **Cost:** the dashboard list is already loaded by the time this appears, so
/// the pinned section, the recency list and the counts are free. The pinned
/// dashboard's tiles cost exactly one request — the same request opening that
/// dashboard would make, served from the same cache, so landing here and then
/// tapping in does not pay twice.
struct ProjectOverviewContent<RecentRow: View>: View {
    let dashboards: [DashboardSummary]
    let recentDashboards: [DashboardSummary]
    let pinnedPreviewStore: DashboardPreviewStore
    @ViewBuilder let recentRow: (DashboardSummary) -> RecentRow

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var pinnedPreviewMinimumColumnWidth: CGFloat {
        // Tiles stay legible at 230pt; AX titles and chart legends need the
        // wider 390pt measure.
        dynamicTypeSize.isAccessibilitySize
            ? 390
            : 230
    }

    private var facts: DashboardOverviewFacts {
        DashboardOverviewFacts(dashboards: dashboards)
    }

    private var recentFacts: DashboardOverviewFacts {
        DashboardOverviewFacts(dashboards: recentDashboards)
    }

    private var summaryTrigger: DashboardSummaryTrigger {
        DashboardSummaryTrigger(
            projectID: model.projectID,
            dashboardCount: facts.dashboardCount,
            pinnedID: facts.pinned?.id
        )
    }

    private var pinnedPreviewScope: DashboardPreviewScope? {
        guard
            let client = model.client,
            let projectID = model.projectID,
            let dashboardID = facts.pinned?.id,
            let authSessionID = model.authSessionID
        else { return nil }
        return DashboardPreviewScope(
            authority: ResourceRequestAuthority(
                projectID: projectID,
                region: client.region,
                authSessionID: authSessionID
            ),
            dashboardID: dashboardID
        )
    }

    private var pinnedPreviewState: QuickPreviewEnrichment<Dashboard> {
        pinnedPreviewStore.state(for: pinnedPreviewScope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            summaryScene

            if !recentFacts.recentlyComputed.isEmpty {
                recentSection
            }
        }
        .task(id: pinnedPreviewScope) {
            await loadPinnedPreview()
        }
    }

    // MARK: - Sections

    private var summaryScene: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SignalRule(mark: .dashboard)
            projectSummary
            if facts.pinned != nil {
                pinnedPreview
            }
        }
        .padding(.leading, Theme.Space.m)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.SignalChrome.teal)
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .signalConfirmation(trigger: summaryTrigger)
    }

    private var projectSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Project signal", productMark: .dashboard)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xxl) {
                    projectTitle
                    Spacer(minLength: Theme.Space.xl)
                    projectMetrics
                }
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    projectTitle
                    projectMetrics
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gethog.dashboard-project-summary")
    }

    private var projectTitle: some View {
        Text(model.selectedProject?.name ?? "PostHog")
            .font(.largeTitle.weight(.semibold))
    }

    private var projectMetrics: some View {
        // These are three short labels and values. Keeping them in the strip at
        // AX5 preserves enough of the initial viewport to show one complete
        // pinned signal; the charts still collapse to their measured one-column
        // layout, while standard type keeps its accepted two-column preview.
        StatStrip {
            MetricTile(
                label: "Dashboards",
                value: "\(facts.dashboardCount)",
                compact: true
            )
            MetricTile(
                label: "Computed",
                value: "\(facts.computedCount)",
                compact: true
            )
            // Named rather than hidden: half this project's dashboards are
            // feature-flag by-products, and a count of 10 that is really
            // 5 real ones plus 5 artefacts misrepresents the project.
            if facts.generatedCount > 0 {
                MetricTile(
                    label: "Generated",
                    value: "\(facts.generatedCount)",
                    compact: true
                )
            }
        }
        .padding(.horizontal, -Theme.Space.l)
    }

    @ViewBuilder
    private var pinnedPreview: some View {
        if let pinned = facts.pinned {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Pinned", productMark: .dashboard)
                if let pinnedDetail = pinnedPreviewState.value {
                    // Two columns of real tiles. Capped at four: this is a preview
                    // that should invite a tap, not a second copy of the dashboard
                    // one tap away.
                    MasonryLayout(
                        columns: 2,
                        spacing: Theme.Space.l,
                        minColumnWidth: pinnedPreviewMinimumColumnWidth
                    ) {
                        ForEach(Array(orderedTiles(pinnedDetail).prefix(4))) { tile in
                            TileCard(
                                presentation: DashboardRenderedTile(
                                    tile: tile,
                                    model: tile.renderModel
                                )
                            )
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier(
                                    "gethog.dashboard-pinned-tile.\(tile.id)"
                                )
                                .allowsHitTesting(false)
                        }
                    }
                } else if case .loading = pinnedPreviewState {
                    HStack(spacing: Theme.Space.m) {
                        ProgressView()
                        Text("Loading \(pinned.title)…")
                    }
                } else if case .unavailable = pinnedPreviewState {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Label(
                            "Couldn't load pinned dashboard preview",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.headline)
                        Text("More details are temporarily unavailable.")
                            .font(.callout)
                            .foregroundStyle(Theme.Ink.secondary)
                        Button("Try again") {
                            Task { await loadPinnedPreview() }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("gethog.dashboard-pinned-failure")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("gethog.dashboard-pinned-preview")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Recently computed", systemImage: "clock.arrow.circlepath")

            VStack(spacing: Theme.Space.s) {
                ForEach(recentFacts.recentlyComputed) { summary in
                    recentRow(summary)
                        .accessibilityIdentifier(
                            "gethog.dashboard-recent-card.\(summary.id)"
                        )
                }
            }
        }
    }

    // MARK: - Loading

    private func orderedTiles(_ dashboard: Dashboard) -> [Tile] {
        dashboard.tiles.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    private func loadPinnedPreview() async {
        await pinnedPreviewStore.activate(
            client: model.client,
            scope: pinnedPreviewScope
        )
    }

}
