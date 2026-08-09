import GetHogKit
import GetHogUI
import SwiftUI

private struct DashboardSummaryTrigger: Equatable {
    let projectID: Int?
    let dashboardCount: Int
    let pinnedID: Int?
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

    @Environment(AppModel.self) private var model
    @State private var pinnedDetail: Dashboard?
    @State private var isLoadingPinned = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            summaryScene

            if !facts.recentlyComputed.isEmpty {
                recentSection
            }
        }
        .task(id: facts.pinned?.id) { await loadPinned() }
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
                        pinnedPreview.frame(maxWidth: .infinity, alignment: .leading)
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
                if let pinnedDetail {
                    // Two columns of real tiles. Capped at four: this is a preview
                    // that should invite a tap, not a second copy of the dashboard
                    // one tap away.
                    MasonryLayout(columns: 2, spacing: Theme.Space.l) {
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
                } else if isLoadingPinned {
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

    private func loadPinned() async {
        guard let pinned = facts.pinned,
              let client = model.client,
              let projectID = model.projectID
        else { return }
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
