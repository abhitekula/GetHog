import GetHogKit
import GetHogUI
import SwiftUI

private struct DashboardSummaryTrigger: Equatable {
    let projectID: Int?
    let dashboardCount: Int
    let pinnedID: Int?
}

/// The complete authority for a cached pinned-preview response.
///
/// Dashboard ids are only unique within a PostHog project, and a credential
/// replacement can reuse the same project number. Keeping both values in the
/// task identity prevents an old cached response from appearing under a new
/// project or authenticated session.
struct PinnedDashboardPreviewScope: Hashable {
    let projectID: Int?
    let dashboardID: Int?
    let authSessionID: UUID?

    var canLoad: Bool {
        projectID != nil && dashboardID != nil && authSessionID != nil
    }
}

@MainActor
@Observable
final class PinnedDashboardPreviewStore {
    private struct LoadScope: Hashable {
        let projectID: Int
        let dashboardID: Int
        let authSessionID: UUID
    }

    private struct LoadFlight {
        let id: Int
        let scope: LoadScope
        let task: Task<Void, Never>
    }

    private(set) var dashboard: Dashboard?
    private(set) var isLoading = false
    private var loadedScope: LoadScope?
    private var generation = 0
    private var nextFlightID = 0
    private var loadFlight: LoadFlight?

    /// A preview is retained by `DashboardsRoot`, rather than the hub view, so
    /// a return from detail or a structural width remount joins this flight or
    /// uses its cached result. `refresh: false` keeps the preview read-only.
    func loadIfNeeded(
        client: PostHogClient?,
        projectID: Int?,
        dashboardID: Int?,
        authSessionID: UUID?
    ) async {
        let previewScope = PinnedDashboardPreviewScope(
            projectID: projectID,
            dashboardID: dashboardID,
            authSessionID: authSessionID
        )
        guard previewScope.canLoad,
              let client,
              let projectID,
              let dashboardID,
              let authSessionID
        else {
            invalidate()
            return
        }

        let scope = LoadScope(
            projectID: projectID,
            dashboardID: dashboardID,
            authSessionID: authSessionID
        )
        if loadedScope == scope, dashboard?.id == dashboardID { return }
        if let loadFlight, loadFlight.scope == scope {
            await loadFlight.task.value
            return
        }

        generation += 1
        let token = generation
        dashboard = nil
        loadedScope = nil
        isLoading = true
        nextFlightID += 1
        let flightID = nextFlightID
        let task = Task { @MainActor in
            await self.performLoad(client: client, scope: scope, token: token)
        }
        loadFlight = LoadFlight(id: flightID, scope: scope, task: task)
        await task.value
        if loadFlight?.id == flightID {
            loadFlight = nil
        }
    }

    private func invalidate() {
        generation += 1
        dashboard = nil
        loadedScope = nil
        isLoading = false
        loadFlight = nil
    }

    private func performLoad(
        client: PostHogClient,
        scope: LoadScope,
        token: Int
    ) async {
        defer {
            if token == generation { isLoading = false }
        }
        do {
            let loaded: Dashboard = try await client.send(
                PostHogAPI.dashboard(
                    projectID: scope.projectID,
                    dashboardID: scope.dashboardID,
                    refresh: false
                )
            )
            guard token == generation, !Task.isCancelled else { return }
            dashboard = loaded
            loadedScope = scope
        } catch {
            // A newer project/auth scope already owns the preview surface. Its
            // response must remain empty until that scope's own request settles.
            guard token == generation, !Task.isCancelled else { return }
        }
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
struct ProjectOverviewContent: View {
    let dashboards: [DashboardSummary]
    let pinnedPreviewStore: PinnedDashboardPreviewStore

    @Environment(AppModel.self) private var model

    /// Tiles stay legible at this measured minimum. The horizontal summary only
    /// fits when it can retain two of these columns plus their actual gap.
    private static let pinnedPreviewMinimumColumnWidth: CGFloat = 230

    private var pinnedPreviewTwoColumnWidth: CGFloat {
        (Self.pinnedPreviewMinimumColumnWidth * 2) + Theme.Space.l
    }

    private var facts: DashboardOverviewFacts {
        DashboardOverviewFacts(dashboards: dashboards)
    }

    private var summaryTrigger: DashboardSummaryTrigger {
        DashboardSummaryTrigger(
            projectID: model.projectID,
            dashboardCount: facts.dashboardCount,
            pinnedID: facts.pinned?.id
        )
    }

    private var pinnedPreviewScope: PinnedDashboardPreviewScope {
        PinnedDashboardPreviewScope(
            projectID: model.projectID,
            dashboardID: facts.pinned?.id,
            authSessionID: model.authSessionID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            summaryScene

            if !facts.recentlyComputed.isEmpty {
                recentSection
            }
        }
        .task(id: pinnedPreviewScope) {
            await pinnedPreviewStore.loadIfNeeded(
                client: model.client,
                projectID: pinnedPreviewScope.projectID,
                dashboardID: pinnedPreviewScope.dashboardID,
                authSessionID: pinnedPreviewScope.authSessionID
            )
        }
    }

    // MARK: - Sections

    private var summaryScene: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SignalRule(mark: .dashboard)
            if facts.pinned != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.xxl) {
                        projectSummary.frame(
                            minWidth: 320,
                            idealWidth: 360,
                            maxWidth: 360,
                            alignment: .leading
                        )
                        pinnedPreview.frame(
                            minWidth: pinnedPreviewTwoColumnWidth,
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        projectSummary
                        pinnedPreview
                    }
                }
            } else {
                projectSummary
            }
        }
        .padding(.leading, Theme.Space.m)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.SignalChrome.teal)
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("gethog.signal-summary.dashboard")
        .signalConfirmation(trigger: summaryTrigger)
    }

    private var projectSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Project signal", productMark: .dashboard)

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip(stacksAtAccessibilitySizes: true) {
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
    }

    @ViewBuilder
    private var pinnedPreview: some View {
        if let pinned = facts.pinned {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Pinned", productMark: .dashboard)
                if let pinnedDetail = pinnedPreviewStore.dashboard {
                    // Two columns of real tiles. Capped at four: this is a preview
                    // that should invite a tap, not a second copy of the dashboard
                    // one tap away.
                    MasonryLayout(
                        columns: 2,
                        spacing: Theme.Space.l,
                        minColumnWidth: Self.pinnedPreviewMinimumColumnWidth
                    ) {
                        ForEach(Array(orderedTiles(pinnedDetail).prefix(4))) { tile in
                            TileCard(
                                presentation: DashboardRenderedTile(
                                    tile: tile,
                                    model: tile.renderModel
                                )
                            )
                                .allowsHitTesting(false)
                        }
                    }
                } else if pinnedPreviewStore.isLoading {
                    HStack(spacing: Theme.Space.m) {
                        ProgressView()
                        Text("Loading \(pinned.title)…")
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Recently computed", systemImage: "clock.arrow.circlepath")

            VStack(spacing: Theme.Space.s) {
                ForEach(facts.recentlyComputed) { summary in
                    Card(padding: Theme.Space.m) {
                        DataRow(
                            glyph: summary.creationMode == .template
                                ? "wand.and.stars" : "square.grid.2x2",
                            brandGlyph: DashboardBrandAppearance.glyph(
                                for: summary.creationMode
                            ),
                            tint: summary.creationMode == .template
                                ? Theme.accentWarm : Theme.accent,
                            title: summary.title,
                            footnote: summary.lastRefresh.map {
                                "Updated \($0.formatted(.relative(presentation: .named)))"
                            },
                            accessory: .none
                        )
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func orderedTiles(_ dashboard: Dashboard) -> [Tile] {
        dashboard.tiles.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

}
