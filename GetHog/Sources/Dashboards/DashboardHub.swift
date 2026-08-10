import GetHogKit
import GetHogUI
import SwiftUI

func filteredDashboards(
    _ dashboards: [DashboardSummary],
    matching search: String
) -> [DashboardSummary] {
    guard !search.isEmpty else { return dashboards }
    return dashboards.filter { $0.title.localizedCaseInsensitiveContains(search) }
}

/// The single regular-width surface for a project's dashboard signal and list.
struct DashboardHub<RowContent: View>: View {
    let dashboards: [DashboardSummary]
    let pinned: [DashboardSummary]
    let others: [DashboardSummary]
    let loadedAt: Date?
    let pinnedPreviewStore: PinnedDashboardPreviewStore
    @Binding var search: String
    @ViewBuilder let row: (DashboardSummary) -> RowContent

    private let columns = [
        GridItem(.adaptive(minimum: 280), spacing: Theme.Space.m, alignment: .top),
    ]

    private var filteredPinned: [DashboardSummary] {
        filtered(pinned)
    }

    private var filteredOthers: [DashboardSummary] {
        filtered(others)
    }

    private var hasNoResults: Bool {
        !search.isEmpty && filteredPinned.isEmpty && filteredOthers.isEmpty
    }

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            ProjectOverviewContent(
                dashboards: dashboards,
                recentDashboards: filteredDashboards(dashboards, matching: search),
                pinnedPreviewStore: pinnedPreviewStore,
                recentRow: row
            )
            dashboardCollection
        }
        .accessibilityIdentifier("gethog.dashboard-hub")
    }

    private var dashboardCollection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if hasNoResults {
                EmptyStateView(
                    title: "No matching dashboards",
                    systemImage: "magnifyingglass",
                    message: "No dashboard title matched “\(search)”."
                )
            } else {
                if !filteredPinned.isEmpty {
                    dashboardSection(title: "Pinned", dashboards: filteredPinned)
                }

                if !filteredOthers.isEmpty {
                    dashboardSection(title: "All dashboards", dashboards: filteredOthers)
                }
            }

            FreshnessLabel(date: loadedAt)
        }
        // A `VStack` with two grid sections is represented twice by visionOS's
        // accessibility bridge when it carries the identifier itself. Keep the
        // stable full-width collection anchor in the background so the cards
        // remain individually discoverable buttons.
        .background {
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("gethog.dashboard-collection")
        }
    }

    private func dashboardSection(title: String, dashboards: [DashboardSummary]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: title, productMark: .dashboard)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.m) {
                ForEach(dashboards) { dashboard in
                    row(dashboard)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private func filtered(_ dashboards: [DashboardSummary]) -> [DashboardSummary] {
        filteredDashboards(dashboards, matching: search)
    }
}
