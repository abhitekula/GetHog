import GetHogKit
import SwiftUI

@MainActor
@Observable
final class DashboardDetailStore {
    var dashboard: Dashboard?
    var isLoading = false
    var error: String?

    func load(client: PostHogClient, projectID: Int, dashboardID: Int, refresh: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            dashboard = try await client.send(
                PostHogAPI.dashboard(projectID: projectID, dashboardID: dashboardID, refresh: refresh)
            )
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

struct DashboardDetailView: View {
    let summary: DashboardSummary

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = DashboardDetailStore()
    @State private var selectedTile: Tile?

    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 320), spacing: 16)]
            : [GridItem(.flexible())]
    }

    var body: some View {
        ScrollView {
            if let error = store.error, store.dashboard == nil {
                ContentUnavailableView {
                    Label("Couldn't load this dashboard", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load(refresh: false) } }
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(orderedTiles) { tile in
                        TileCard(tile: tile, webURL: tileWebURL(tile))
                            .onTapGesture { selectedTile = tile }
                    }
                }
                .padding(16)
                .skeleton(store.isLoading && store.dashboard == nil)
            }
        }
        .background(Theme.pageBackground)
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        // Only an explicit user action escalates to recomputation;
                        // the shared org budget pays for it.
                        Task { await load(refresh: true) }
                    } label: {
                        Label("Recompute results", systemImage: "arrow.clockwise")
                    }
                    if let url = model.webURL(path: "dashboard/\(summary.id)") {
                        Link(destination: url) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await load(refresh: false) }
        .task { await load(refresh: false) }
        .sheet(item: $selectedTile) { tile in
            NavigationStack {
                InsightDetailView(tile: tile, webURL: tileWebURL(tile))
            }
        }
    }

    private var orderedTiles: [Tile] {
        // Stored layouts only contain `sm`/`xs`, so there is no iPad layout to
        // honour — order is ours to decide.
        (store.dashboard?.tiles ?? []).sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    private func tileWebURL(_ tile: Tile) -> URL? {
        guard let insight = tile.insight else { return nil }
        return model.webURL(path: "insights/\(insight.id)")
    }

    private func load(refresh: Bool) async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(
            client: client, projectID: projectID, dashboardID: summary.id, refresh: refresh
        )
    }
}

struct TileCard: View {
    let tile: Tile
    var webURL: URL?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tile.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                }

                InsightChartView(model: tile.renderModel, compact: true, webURL: webURL)

                FreshnessLabel(date: tile.lastRefresh, isCached: tile.isCached)
            }
        }
        .contentShape(.rect)
        .contextMenu {
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
            }
        }
    }
}

struct InsightDetailView: View {
    let tile: Tile
    var webURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                InsightChartView(model: tile.renderModel, compact: false, webURL: webURL)

                if case .timeSeries(let series, _) = tile.renderModel {
                    SeriesLegend(series: series)
                }

                FreshnessLabel(date: tile.lastRefresh, isCached: tile.isCached)
            }
            .padding()
        }
        .background(Theme.pageBackground)
        .navigationTitle(tile.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            if let webURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: webURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}

/// Explicit legend with symbol + label, so a series is identifiable without
/// relying on hue — required by the palette's light-mode contrast relief rule.
struct SeriesLegend: View {
    let series: [Series]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(series.enumerated()), id: \.offset) { index, s in
                HStack(spacing: 8) {
                    Image(systemName: SeriesPalette.symbol(at: index))
                        .font(.system(size: 9))
                        .foregroundStyle(SeriesPalette.color(at: index))
                    Text(s.label)
                        .font(.subheadline)
                    Spacer()
                    Text(s.total.compactFormatted)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(s.label), total \(s.total.formatted())")
            }
        }
    }
}
