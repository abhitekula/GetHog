import GetHogKit

struct DashboardOverviewFacts {
    let dashboardCount: Int
    let computedCount: Int
    let generatedCount: Int
    let pinned: DashboardSummary?
    let recentlyComputed: [DashboardSummary]

    init(dashboards: [DashboardSummary]) {
        dashboardCount = dashboards.count
        generatedCount = dashboards.filter { $0.creationMode == .template }.count
        pinned = dashboards.first(where: \.pinned)
        recentlyComputed = dashboards
            .compactMap { summary in summary.lastRefresh.map { (summary, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
        computedCount = recentlyComputed.count
    }
}

enum DashboardBrandAppearance {
    static func glyph(for mode: DashboardCreationMode) -> BrandObjectGlyph {
        mode == .template ? .generatedDashboard : .dashboard
    }
}
