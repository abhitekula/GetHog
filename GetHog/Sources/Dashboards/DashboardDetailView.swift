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
    let dashboardID: Int
    /// Known up front when navigating from the list; absent when a restored
    /// window has nothing but an id, in which case the fetch supplies it.
    private let providedTitle: String?

    init(dashboardID: Int, title: String? = nil) {
        self.dashboardID = dashboardID
        self.providedTitle = title
    }

    init(summary: DashboardSummary) {
        self.init(dashboardID: summary.id, title: summary.title)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow
    @State private var store = DashboardDetailStore()
    @State private var selectedTile: Tile?

    private var title: String {
        store.dashboard?.title ?? providedTitle ?? "Dashboard"
    }

    private var columns: [GridItem] {
        guard sizeClass == .regular else { return [GridItem(.flexible())] }
        // With the panel open the grid keeps about a third of the iPad, where an
        // adaptive minimum yields one column centred between two dead margins.
        // A flexible column fills that space instead.
        return selectedTile == nil
            ? [GridItem(.adaptive(minimum: 280), spacing: 16)]
            : [GridItem(.flexible())]
    }

    var body: some View {
        grid
            .insightDetail(tile: $selectedTile, isWide: sizeClass == .regular)
            .background(Theme.pageBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .keyboardActions([
                KeyboardAction(key: "r", title: "Recompute results") {
                    Task { await load(refresh: true) }
                }
            ])
            .refreshable { await load(refresh: false) }
            // Keyed on the project, not bare: a window restored at cold launch
            // appears before `bootstrap()` has produced a client, and a plain
            // `.task` would run once against nothing and leave the window
            // permanently empty.
            .task(id: model.projectID) {
                await load(refresh: false)
                #if DEBUG
                if let index = DebugLaunch.tileIndex, orderedTiles.indices.contains(index) {
                    selectedTile = orderedTiles[index]
                }
                #endif
            }
    }

    private var grid: some View {
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
                            .pointerHighlight()
                            .onTapGesture { selectedTile = tile }
                    }
                }
                .padding(16)
                .skeleton(store.isLoading && store.dashboard == nil)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    // Only an explicit user action escalates to recomputation;
                    // the shared org budget pays for it.
                    Task { await load(refresh: true) }
                } label: {
                    Label("Recompute results", systemImage: "arrow.clockwise")
                }
                if Platform.supportsMultipleWindows {
                    Button {
                        openWindow(value: WindowTarget.dashboard(id: dashboardID))
                    } label: {
                        Label("Open in new window", systemImage: "macwindow.badge.plus")
                    }
                }
                if let url = model.webURL(path: "dashboard/\(dashboardID)") {
                    Link(destination: url) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Dashboard actions")
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
            client: client, projectID: projectID, dashboardID: dashboardID, refresh: refresh
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
        // Dragging a tile carries the chart as PNG, the series as CSV and the
        // title as text, so the destination decides what it wanted: Numbers
        // takes the CSV, Mail or Slack the image.
        .draggable(ExportableInsight(title: tile.title, model: tile.renderModel))
        .contextMenu {
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
            }
            InsightShareMenuItems(title: tile.title, model: tile.renderModel)
        }
    }
}

/// The insight itself, with no navigation chrome of its own.
///
/// Split out because the two presentations need different chrome: the sheet gets
/// a real navigation bar, while the iPad side panel draws its own header. Giving
/// the panel a nested `NavigationStack` instead pushed its toolbar items up into
/// the dashboard's navigation bar and displaced the dashboard's own title.
struct InsightDetailBody: View {
    let tile: Tile
    var webURL: URL?

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
    }
}

struct InsightDetailView: View {
    let tile: Tile
    var webURL: URL?
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        InsightDetailBody(tile: tile, webURL: webURL)
        .navigationTitle(tile.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    if let onClose { onClose() } else { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    InsightShareMenuItems(title: tile.title, model: tile.renderModel)
                    if let webURL {
                        Divider()
                        ShareLink(item: webURL) {
                            Label("Share link", systemImage: "link")
                        }
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share this insight")
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
