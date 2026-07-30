import GetHogKit
import SwiftUI

/// A dashboard-wide time window.
///
/// `.saved` is not "no filter" — it is each insight's own stored range, which
/// differs per tile. That distinction is why this is an explicit case rather
/// than an optional: a dashboard showing a 30-day chart beside a 14-day one is
/// correct until the user asks for one window, and the control has to be able to
/// say so.
enum DashboardRange: String, CaseIterable, Identifiable {
    case saved, day, week, month, quarter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saved: "Saved"
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        }
    }

    /// `nil` for `.saved`, which runs nothing and shows the stored results.
    var dateFrom: String? {
        switch self {
        case .saved: nil
        case .day: "-24h"
        case .week: "-7d"
        case .month: "-30d"
        case .quarter: "-90d"
        }
    }
}

@MainActor
@Observable
final class DashboardDetailStore {
    var dashboard: Dashboard?
    var isLoading = false
    var error: String?

    /// Results for tiles re-run over an overridden window, keyed by tile id.
    /// Absent means "show the saved result".
    private(set) var overrides: [Int: InsightRenderModel] = [:]
    private(set) var isApplyingRange = false
    private(set) var rangeError: String?

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

    func clearOverrides() {
        overrides = [:]
        rangeError = nil
    }

    /// Re-runs every tile over `range`.
    ///
    /// Costs one `/query/` request per tile, because the dashboard endpoint
    /// cannot do this — see `InsightRerun`, where the silent no-op is documented.
    /// That price is why this is only ever called from an explicit choice, never
    /// from a gesture or a scroll.
    func apply(
        range: DashboardRange,
        compare: Bool,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard let dateFrom = range.dateFrom, let tiles = dashboard?.tiles else {
            clearOverrides()
            return
        }

        isApplyingRange = true
        defer { isApplyingRange = false }

        var results: [Int: InsightRenderModel] = [:]
        var failures = 0

        for tile in tiles {
            guard let insight = tile.insight, let source = insight.rawSource else { continue }
            let rebuilt = InsightRerun.source(source, dateFrom: dateFrom, compare: compare)
            do {
                let data = try await client.data(
                    for: PostHogAPI.runQuery(projectID: projectID, source: rebuilt)
                )
                if let model = InsightRerun.renderModel(
                    from: data,
                    sourceKind: insight.sourceKind,
                    display: insight.displayType
                ) {
                    results[tile.id] = model
                }
            } catch {
                failures += 1
            }
        }

        overrides = results
        // Named rather than swallowed: a tile silently showing its saved range
        // while the control claims 7 days is exactly the lie this feature exists
        // to avoid.
        rangeError = failures == 0
            ? nil
            : "\(failures) of \(tiles.count) tiles kept their saved range."
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
    @State private var range: DashboardRange = .saved
    @State private var compare = false

    private var title: String {
        store.dashboard?.title ?? providedTitle ?? "Dashboard"
    }

    /// Ceiling on columns; `MasonryLayout` drops below it whenever the width
    /// cannot give each column a readable tile.
    ///
    /// Four columns on a large iPad looks tidy and reads badly: axis labels
    /// collide and every card becomes a postage stamp. Two wide columns beat
    /// three narrow ones.
    ///
    /// This no longer forces one column when the inspector opens. It used to,
    /// which combined with the old fixed-width side panel to squeeze the grid
    /// into a strip of clipped titles — the layout now derives its own count
    /// from the width it is actually granted.
    private var columnCount: Int {
        sizeClass == .regular ? 2 : 1
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
            // Keyed on both, so toggling compare re-runs rather than leaving the
            // grid showing figures that no longer match the control.
            .task(id: RangeSelection(range: range, compare: compare)) {
                await applyRange()
            }
            // Keyed on the project, not bare: a window restored at cold launch
            // appears before `bootstrap()` has produced a client, and a plain
            // `.task` would run once against nothing and leave the window
            // permanently empty.
            .task(id: model.projectID) {
                // Without this, a launch that lands on Dashboards leaves the
                // scrub tip's availability rule false and it never fires.
                AppTips.refresh(from: model)
                await load(refresh: false)
                #if DEBUG
                if let index = DebugLaunch.tileIndex, orderedTiles.indices.contains(index) {
                    selectedTile = orderedTiles[index]
                }
                #endif
            }
    }

    /// Time window + compare, above the grid.
    ///
    /// Applying a window costs one request per tile, so it commits on release
    /// rather than continuously, and the compare toggle only appears once a
    /// window is chosen — comparing "each insight's own saved range" against a
    /// previous period is not a question with one answer.
    private var rangeBar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Picker("Time range", selection: $range) {
                    ForEach(DashboardRange.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                // Capped rather than stretched: a segmented control spanning a
                // 13-inch iPad puts five words a hand's width apart and reads as
                // a toolbar, not a choice.
                .frame(maxWidth: 420, alignment: .leading)

                if store.isApplyingRange {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: Theme.Space.m) {
                if range != .saved {
                    Toggle("Compare to previous", isOn: $compare)
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .accessibilityLabel("Compare to the previous period")
                }

                if let rangeError = store.rangeError {
                    Label(rangeError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.Status.critical)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
    }

    private var grid: some View {
        ScrollView {
            rangeBar
                .padding(.bottom, Theme.Space.xs)

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
                MasonryLayout(columns: columnCount, spacing: Theme.Space.l) {
                    ForEach(orderedTiles) { tile in
                        TileCard(
                            tile: tile,
                            model: store.overrides[tile.id] ?? tile.renderModel,
                            webURL: tileWebURL(tile)
                        )
                        .pointerHighlight()
                        .onTapGesture { selectedTile = tile }
                        .tileSpan(
                            TileStyle.preferredColumns(
                                for: store.overrides[tile.id] ?? tile.renderModel
                            )
                        )
                    }
                }
                .padding(Theme.Space.l)
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

    /// One value so a change to either field re-runs exactly once.
    private struct RangeSelection: Equatable {
        let range: DashboardRange
        let compare: Bool
    }

    private func applyRange() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        guard range != .saved else {
            store.clearOverrides()
            return
        }
        await store.apply(range: range, compare: compare, client: client, projectID: projectID)
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
    /// The model to draw, which is the tile's own unless a time-range override
    /// replaced it.
    let model: InsightRenderModel
    var webURL: URL?

    var body: some View {
        Card(accent: TileStyle.accent(for: model)) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(
                    title: tile.title,
                    systemImage: TileStyle.symbol(for: model)
                )

                InsightChartView(model: model, compact: true, webURL: webURL)

                FreshnessLabel(date: tile.lastRefresh, isCached: tile.isCached)
            }
            // Clears the accent spine, which is drawn inside the card's bounds.
            .padding(.leading, Theme.Space.s)
        }
        .contentShape(.rect)
        // Dragging a tile carries the chart as PNG, the series as CSV and the
        // title as text, so the destination decides what it wanted: Numbers
        // takes the CSV, Mail or Slack the image. It carries what is on screen,
        // so an exported CSV matches the window the user is looking at.
        .draggable(ExportableInsight(title: tile.title, model: model))
        .contextMenu {
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
            }
            InsightShareMenuItems(title: tile.title, model: model)
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
