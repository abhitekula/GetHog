import GetHogKit
import SwiftUI

/// What the iPad detail pane shows before a dashboard is chosen.
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
struct ProjectOverview: View {
    let dashboards: [DashboardSummary]

    @Environment(AppModel.self) private var model
    @State private var pinnedDetail: Dashboard?
    @State private var isLoadingPinned = false

    private var pinned: DashboardSummary? { dashboards.first(where: \.pinned) }

    /// Dashboards whose results have actually been computed, newest first.
    ///
    /// Deliberately not "recently created": a dashboard nobody has ever opened
    /// is not a useful shortcut, and most of this project's list has never been
    /// computed at all.
    private var recentlyComputed: [DashboardSummary] {
        dashboards
            .compactMap { summary in summary.lastRefresh.map { (summary, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
    }

    private var generatedCount: Int {
        dashboards.filter { $0.creationMode == .template }.count
    }

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            header

            if let pinned {
                pinnedSection(pinned)
            }

            if !recentlyComputed.isEmpty {
                recentSection
            }
        }
        .task(id: pinned?.id) { await loadPinned() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Project", systemImage: "building.2")

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip {
                MetricTile(
                    label: "Dashboards",
                    value: "\(dashboards.count)",
                    compact: true
                )
                MetricTile(
                    label: "Computed",
                    value: "\(recentlyComputed.count)",
                    compact: true
                )
                // Named rather than hidden: half this project's dashboards are
                // feature-flag by-products, and a count of 10 that is really
                // 5 real ones plus 5 artefacts misrepresents the project.
                if generatedCount > 0 {
                    MetricTile(
                        label: "Generated",
                        value: "\(generatedCount)",
                        compact: true
                    )
                }
            }
            .padding(.horizontal, -Theme.Space.l)
        }
    }

    private func pinnedSection(_ summary: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Pinned", systemImage: "pin.fill")

            if let pinnedDetail {
                // Two columns of real tiles. Capped at four: this is a preview
                // that should invite a tap, not a second copy of the dashboard
                // one tap away.
                MasonryLayout(columns: 2, spacing: Theme.Space.l) {
                    ForEach(Array(orderedTiles(pinnedDetail).prefix(4))) { tile in
                        TileCard(tile: tile, model: tile.renderModel)
                            .allowsHitTesting(false)
                    }
                }
            } else if isLoadingPinned {
                Card {
                    HStack(spacing: Theme.Space.m) {
                        ProgressView()
                        Text("Loading \(summary.title)…")
                            .font(Theme.Typography.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Recently computed", systemImage: "clock.arrow.circlepath")

            VStack(spacing: Theme.Space.s) {
                ForEach(recentlyComputed) { summary in
                    Card(padding: Theme.Space.m) {
                        DataRow(
                            glyph: summary.creationMode == .template
                                ? "wand.and.stars" : "square.grid.2x2",
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

    private func loadPinned() async {
        guard let pinned, let client = model.client, let projectID = model.projectID else { return }
        isLoadingPinned = true
        defer { isLoadingPinned = false }
        // `refresh: false` so this reads the cache and never escalates to
        // recomputation. An overview that recomputed a dashboard just by being
        // looked at would spend the org's shared budget on a glance.
        pinnedDetail = try? await client.send(
            PostHogAPI.dashboard(projectID: projectID, dashboardID: pinned.id, refresh: false)
        )
    }
}
