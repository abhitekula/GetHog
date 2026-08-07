import GetHogKit
import GetHogUI
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(tvOS)
    // The environment value itself is unavailable on tvOS, not merely useless
    // there. `Platform.supportsMultipleWindows` answers false on that platform,
    // so the one site that reads this is already absent.
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var store = DashboardDetailStore()
    @State private var selectedTile: Tile?
    @State private var range: DashboardRange = .saved
    @State private var compare = false

    /// Pairs each tile with the detail it opens, so the card grows into the
    /// screen it becomes instead of the screen arriving from off-stage.
    ///
    /// Declared here rather than inside `InsightDetailPresentation` because the
    /// two ends live on opposite sides of that modifier: the source is a card in
    /// the grid this view owns, and the destination is presented by a modifier
    /// applied to it. A `@Namespace` in the modifier would be a different
    /// namespace from the one the cards registered in, and the transition would
    /// silently fall back to a plain sheet — silently being the problem.
    @Namespace private var tileTransition

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
            .insightDetail(tile: $selectedTile, isWide: sizeClass == .regular, in: tileTransition)
            .background(Theme.pageBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Same URL the "Open in PostHog" item below opens, offered to the
            // *other* device instead of this one.
            .handoff(webURL: webURL, title: title)
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
                // After the load, so the home screen menu gets the dashboard's
                // real title rather than the placeholder a link arrives with.
                if let projectID = model.projectID {
                    QuickActions.recordVisit(
                        .dashboard(id: dashboardID),
                        title: title,
                        projectID: projectID
                    )
                    QuickActions.refresh(projectID: projectID)
                }
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
                adaptivelyStyled(
                    Picker("Time range", selection: $range) {
                        ForEach(DashboardRange.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                )
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
                    #if os(tvOS)
                    // `toggleStyle(.button)` is unavailable on tvOS. The
                    // platform's own toggle is already a focusable control that
                    // reads its state aloud, which is what the button style was
                    // buying elsewhere.
                    Toggle("Compare to previous", isOn: $compare)
                        .font(.caption)
                        .accessibilityLabel("Compare to the previous period")
                    #else
                    Toggle("Compare to previous", isOn: $compare)
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .accessibilityLabel("Compare to the previous period")
                    #endif
                }

                if let rangeError = store.rangeError {
                    Label(rangeError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.Status.criticalInk)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
    }

    /// Segmented controls shrink their labels to slivers at accessibility text
    /// sizes, so past that threshold the same choice becomes a menu. Five
    /// segments made this the worst offender: "Saved" stayed tiny while every
    /// other control on the screen grew around it.
    @ViewBuilder
    private func adaptivelyStyled(_ picker: some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
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
                            webURL: tileWebURL(tile),
                            open: { selectedTile = tile }
                        )
                        .pointerHighlight()
                        // The source half of the zoom. Registered unconditionally,
                        // including under Reduce Motion and on iPad where the
                        // detail is a side panel rather than a presentation: with
                        // no destination naming this id, the modifier records a
                        // frame nothing reads and changes neither the layout nor
                        // the accessibility tree. Gating it as well as the
                        // destination would be two switches for one behaviour, and
                        // the wrong one to forget.
                        .matchedTransitionSource(id: tile.id, in: tileTransition)
                        // Outermost, and it has to stay outermost: `tileSpan` is a
                        // `LayoutValueKey` that `MasonryLayout` reads off the
                        // subview it is given, and a modifier applied after it is
                        // what that subview becomes.
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
                #if !os(tvOS)
                if Platform.supportsMultipleWindows {
                    Button {
                        openWindow(value: WindowTarget.dashboard(id: dashboardID))
                    } label: {
                        Label("Open in new window", systemImage: "macwindow.badge.plus")
                    }
                }
                // No browser on tvOS: the link would focus and then do nothing.
                if let webURL {
                    Link(destination: webURL) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
                #endif
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

    /// This dashboard's page in the console. One property rather than two call
    /// sites, because the toolbar link and the Handoff activity must name the
    /// same page or the second device lands somewhere the first never was.
    private var webURL: URL? {
        model.webURL(path: "dashboard/\(dashboardID)")
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
    /// What opening the tile does, on the one screen where a tile opens.
    ///
    /// `nil` on the project overview, whose pinned tiles are a preview of a
    /// dashboard one tap away rather than five controls — see `ProjectOverview`,
    /// which also switches hit testing off. A card that does nothing must not
    /// claim the button trait; VoiceOver would offer an activation that has no
    /// effect.
    var open: (() -> Void)?

    /// Both of these were suspects for the tap defect fixed in `card`, and both
    /// were **exonerated by measurement** rather than by reading. With the
    /// `Button` otherwise untouched, removing `.draggable`, removing
    /// `.contextMenu`, and removing both changed nothing at all: the tile opened
    /// on a first tap and refused every tap after a tap on the plot in all four
    /// shapes, identically. Recorded because the standing note on this defect
    /// named these two as the only things between the tap and the control, which
    /// was true and was not the same as their being responsible.
    var body: some View {
        control
            // Dragging a tile carries the chart as PNG, the series as CSV and
            // the title as text, so the destination decides what it wanted:
            // Numbers takes the CSV, Mail or Slack the image. It carries what is
            // on screen, so an exported CSV matches the window the user is
            // looking at.
            //
            // `draggable` is unavailable on tvOS, which has no drag session and
            // no second app to drop into.
            #if !os(tvOS)
            .draggable(ExportableInsight(title: tile.title, model: model))
            #endif
            .contextMenu {
                #if !os(tvOS)
                // No browser to open it in; `InsightShareMenuItems` already
                // renders nothing on tvOS, so the menu is empty there rather
                // than a list of things that do not happen.
                if let webURL {
                    Link(destination: webURL) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
                #endif
                InsightShareMenuItems(title: tile.title, model: model)
            }
    }

    /// One button per tile, not a card with a tap gesture bolted on.
    ///
    /// `.onTapGesture` moves pixels and tells the accessibility tree nothing.
    /// Measured on the demo dashboard before this: six tiles, no tile buttons in
    /// the tree at all, and each tile leaving two loose `StaticText`s behind —
    /// an 18pt title and a 13.3pt freshness stamp, which Apple's
    /// `performAccessibilityAudit` flagged "hit area is too small" four times
    /// over. A `Button` taking the card as its label collapses the same tile
    /// into one 370×289pt element carrying the button trait, which is the shape
    /// every `List` row elsewhere in this app already has, and the audit's four
    /// hits go with it.
    ///
    /// The button can now be activated from anywhere inside the card, which is
    /// also the only way a VoiceOver or Full Keyboard Access user ever reaches
    /// it. That was **not** true when this was written — see `card`.
    @ViewBuilder
    private var control: some View {
        if let open {
            Button(action: open) {
                card
            }
            #if os(tvOS)
            // `.card` is the platform's own focus treatment — the lift, the
            // parallax and the shadow a viewer ten feet away needs in order to
            // see which tile the remote is on. `.plain` on tvOS draws no focus
            // state at all, which on a grid of cards is unnavigable.
            .buttonStyle(.card)
            #else
            // The card is already the design; a button style would repaint it.
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Opens the full insight")
        } else {
            card
        }
    }

    private var card: some View {
        Card(accent: TileStyle.accent(for: model)) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(
                    title: tile.title,
                    systemImage: TileStyle.symbol(for: model),
                    showsBrandStitch: true
                )

                InsightChartView(
                    model: model,
                    compact: true,
                    webURL: webURL,
                    // The tile's heading is the insight's name, and it is the
                    // only place the chart's descriptor can get one from.
                    title: tile.title
                )
                // **This one line is why a dashboard tile could not be opened.**
                //
                // `TimeSeriesChart` installs `.chartXSelection` so a chart can be
                // scrubbed. Inside this `Button`'s label that gesture is a child
                // of the control, and it does not merely win the plot region — it
                // takes the touch, produces no selection from a tap, and leaves
                // the enclosing button unable to perform its action *ever again*,
                // anywhere in its bounds, for as long as the screen lives.
                //
                // Measured on iPhone 16e, demo build, six-tile dashboard, one
                // launch per row:
                //
                //   tap the title row first .............. opens
                //   tap the plot, then the title row ..... neither opens
                //   …with `.draggable` removed ........... neither opens
                //   …with `.contextMenu` removed ......... neither opens
                //   …with both removed ................... neither opens
                //   …with this modifier ................. the plot tap opens it
                //
                // and in the poisoned run the *neighbouring* tile, never touched,
                // still opened on its first tap — so the damage is one button's,
                // not the screen's, and it is caused by the touch rather than by
                // any state the tap leaves behind. Nothing is visible: no scrub
                // readout, no rule mark, no pressed appearance; screenshots
                // before and after the poisoning tap are identical.
                //
                // The tile is one control by design, so its content is a picture:
                // hit testing off here is the invariant rather than a patch for
                // one chart, and it covers every form `InsightChartView` can draw
                // — including `.unsupported`, whose "Open in PostHog" `Link` is
                // the same trap in a different shape. Accessibility is untouched:
                // this suppresses touches, not the tree, so the chart's
                // `AXChartDescriptor` and the rotor still work.
                //
                // `ProjectOverview` switches hit testing off at its own call site
                // too. That is not this — its tiles are not buttons at all, and
                // the two are unrelated guards that happen to spell the same.
                .allowsHitTesting(false)

                FreshnessLabel(date: tile.lastRefresh, isCached: tile.isCached)
            }
            // Clears the accent spine, which is drawn inside the card's bounds.
            .padding(.leading, Theme.Space.s)
        }
        .contentShape(.rect)
    }

    /// Title, what the chart shows, and how stale it is — the three things the
    /// card prints, in the order it prints them.
    ///
    /// Spelled out rather than left to SwiftUI's own combining because the chart
    /// in the middle is a plot: combined automatically, the tile would announce
    /// its heading and its date stamp with silence where the data should be.
    /// `joinedAsSentences()` rather than `joined(separator: ". ")`: the first
    /// fragment is `insight.name` straight off the API, and a dashboard whose
    /// author ended a tile title in a full stop would otherwise be read with a
    /// doubled one — the defect that helper was measured against on the Errors
    /// list.
    private var spokenLabel: String {
        [tile.title, InsightSummary.spoken(model), freshness].joinedAsSentences()
    }

    /// `FreshnessLabel`'s own wording. It lives in `Common` and its label is not
    /// reachable from here, and the two saying different things about the same
    /// timestamp would be worse than saying it twice.
    private var freshness: String {
        tile.lastRefresh
            .map { "Data updated \($0.formatted(.relative(presentation: .named)))" }
            ?? "Data not yet loaded"
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
                InsightChartView(
                    model: tile.renderModel,
                    compact: false,
                    webURL: webURL,
                    title: tile.title,
                    // The opened tile, which is a full-size chart outside any
                    // button — unlike the tile itself, whose chart is
                    // `.allowsHitTesting(false)` above and cannot be scrubbed.
                    showsScrubTip: true
                )

                if case .timeSeries(let series, _) = tile.renderModel {
                    SeriesLegend(series: series)
                }

                FreshnessLabel(date: tile.lastRefresh, isCached: tile.isCached)

                // Comments are keyed by scope + item_id, so they belong on the
                // object they annotate rather than in a tab of their own. This
                // body serves both presentations — the iPad side panel and the
                // iPhone sheet — so one insertion covers both. Only a saved
                // insight has an id to key on; an ad-hoc tile has nothing to
                // attach a thread to.
                if let insight = tile.insight {
                    Divider()
                    CommentsSection(scope: .insight, itemID: String(insight.id))
                }
            }
            .padding()
        }
        // The opened tile, not the grid: the charts inside a `TileCard` are
        // deliberately left inert, because a tile is already one button. Here
        // there is room for a step to be a step and a bar to be a bar.
        //
        // An ad-hoc tile with no saved insight has no query to drill and gets
        // nothing, which is the same answer as a kind that cannot be drilled.
        .insightPeople(for: tile.insight)
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
            #if !os(tvOS)
            // The whole menu is unavailable on tvOS: `ShareLink` does not
            // exist there, `Link` opens nothing, and `InsightShareMenuItems`
            // already renders empty. A share button that opens on nothing is
            // one more stop on the focus walk for no reward.
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
            #endif
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
                    // Tracks the label rather than sitting at a fixed 9pt. The
                    // symbol is the half of this legend that does not depend on
                    // hue, and three light-mode palette colours fall below 3:1 —
                    // so pinning it small shrinks the relief to a speck for
                    // precisely the readers it exists for.
                    Image(systemName: SeriesPalette.symbol(at: index))
                        .font(.caption2)
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
