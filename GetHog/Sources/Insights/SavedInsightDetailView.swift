import GetHogKit
import SwiftUI

/// A saved insight on its own screen.
///
/// The counterpart of `InsightDetailBody`, which draws a dashboard *tile*. They
/// are not merged because they are given different things: a `Tile` carries its
/// insight plus the dashboard's own layout and refresh metadata, while this
/// starts from an id and has to resolve, compute and possibly fail to find the
/// insight before anything can be drawn. What they share — the chart, the
/// legend, the share menu, the comment thread — is shared by calling the same
/// views, which is the part that actually matters.
struct SavedInsightDetailView: View {

    /// Either spelling of the id: the console's 8-character handle or the
    /// numeric one. `SavedInsightStore.resolve` decides which without guessing.
    let identifier: String
    /// Known when arriving from the library, absent when arriving from a link.
    /// Used for the title while the fetch is in flight, so the navigation bar is
    /// never briefly labelled "Insight" for something the app already knew the
    /// name of.
    private let seeded: Insight?

    init(identifier: String, seed: Insight? = nil) {
        self.identifier = identifier
        self.seeded = seed
    }

    init(_ insight: Insight) {
        self.init(identifier: insight.linkID, seed: insight)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var store = SavedInsightStore()

    /// The narrowing currently applied, and the sheet that edits it.
    ///
    /// Held here rather than in the store because it is the *request*, not the
    /// answer — the store owns what came back. Keeping them apart is what lets
    /// the chart caption say "showing Chrome" while the store separately reports
    /// that the run failed, which is the pair `DashboardDetailView` gets wrong by
    /// having only one of them.
    @State private var filters: [InsightPropertyFilter] = []
    @State private var breakdown: InsightBreakdownOverride = .saved
    @State private var isNarrowing = false
    @State private var isShowingAlerts = false

    private var insight: Insight? { store.insight ?? seeded }
    private var title: String { insight?.title ?? "Insight" }

    var body: some View {
        content
            // Only the full-size screen offers the drill-down. A dashboard tile
            // is already a button that opens the insight, and a sheet raised
            // from a grid would land the reader somewhere they never navigated
            // to. `nil` for a kind that cannot be drilled, which is how the
            // affordance stays absent rather than present-and-failing.
            .insightPeople(for: insight)
            .background(Theme.pageBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // The same console page the share menu offers, handed to whatever
            // device can do more with it than a phone can.
            .handoff(webURL: webURL, title: title)
            .navigationDestination(for: DashboardReference.self) { reference in
                DashboardDetailView(dashboardID: reference.id)
            }
            .toolbar { toolbarContent }
            // Both sheets are presented from this screen rather than hoisted into
            // `RootView`. `AppTab.presentsDetailAsSheet` exists for a *secondary
            // tab's* own detail, which is torn down and written back through its
            // binding when the width class changes; this is a pushed detail screen
            // whose transient composer has no binding to write back through. What
            // a width change costs here is the sheet closing, which is what a
            // rebuilt screen should do with a half-typed form anyway.
            .sheet(isPresented: $isNarrowing) {
                if let insight {
                    InsightNarrowSheet(
                        insight: insight,
                        filters: $filters,
                        breakdown: $breakdown
                    ) {
                        applyNarrowing()
                    }
                }
            }
            .sheet(isPresented: $isShowingAlerts) {
                if let insight {
                    InsightAlertsView(insight: insight)
                }
            }
            .keyboardActions([
                KeyboardAction(key: "r", title: "Recompute results") { recompute() }
            ])
            .refreshable { await load() }
            // Keyed on the project rather than bare: a window restored at cold
            // launch appears before `bootstrap()` has produced a client, and a
            // plain `.task` would run once against nothing and leave the screen
            // permanently empty.
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            // `insight:read` is one of the two scopes behind this capability, so
            // the same gate the dashboards and search screens use is the right
            // one here — a key that cannot read insights cannot read this screen.
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if store.notFound {
            notFoundState
        } else if let insight {
            body(for: insight)
        } else if let failure = store.failure {
            LoadFailureState(title: "Couldn't load this insight", failure: failure) {
                Task { await load() }
            }
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity)
        }
    }

    /// A link outliving the object it names is normal, not exceptional — an
    /// insight can be deleted between somebody sending a link and somebody
    /// opening it — so this says which id was asked for and offers the console,
    /// where a deleted insight is at least explained.
    private var notFoundState: some View {
        EmptyStateView(
            title: "Insight not found",
            systemImage: "questionmark.square.dashed",
            message: "Nothing with the id \(identifier) is saved in \(model.selectedProject?.name ?? "this project"). It may have been deleted, or it may belong to another project.",
            actionTitle: webURL == nil ? nil : "Open in PostHog",
            action: webURL.map { url in { openURL(url) } }
        )
    }

    private func body(for insight: Insight) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header(for: insight)

                chart(for: insight)

                narrowingNote(for: insight)

                if case .timeSeries(let series, _) = drawnModel(for: insight), !series.isEmpty {
                    SeriesLegend(series: series)
                }

                freshness(for: insight)

                if !insight.dashboards.isEmpty {
                    dashboardLinks(for: insight)
                }

                Divider()
                // Keyed by scope + item id, exactly as the dashboard tile's
                // thread is — so a comment left on an insight from a dashboard is
                // the same thread this screen shows, rather than a second one
                // nobody else can see.
                CommentsSection(scope: .insight, itemID: String(insight.id))
            }
            .padding(Theme.Space.l)
        }
    }

    // MARK: - Pieces

    /// Kind, description, and when the definition last changed.
    ///
    /// The kind is a pill rather than a tint on the chart, because it is the one
    /// fact about an insight that survives having no data — and on this screen,
    /// unlike a dashboard, there is no grid of neighbours to tell a funnel from a
    /// retention grid by silhouette.
    @ViewBuilder
    private func header(for insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                StatusPill(
                    text: insight.kind?.title ?? readableKind(insight.sourceKind),
                    tint: Theme.accent
                )
                if insight.favorited {
                    // The word, not just the star: a starred insight must be
                    // identifiable without seeing the glyph.
                    Label("Favorite", systemImage: "star.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Status.warningInk)
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
            }

            if let description = insight.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    // Wraps rather than truncating: this is the author's own
                    // explanation of what the chart is for, and half of one is
                    // worse than none.
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let modified = insight.lastModifiedAt {
                Text("Definition last changed \(modified, format: .relative(presentation: .named))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The chart, or an honest statement of why there isn't one.
    ///
    /// Three outcomes, and they are deliberately different views. A kind this app
    /// does not draw gets `UnsupportedInsightCard`, the same deliberate card a
    /// dashboard tile gets — a mobile app declining to draw a HogQL table is a
    /// decision, and it should look like one. A drawable kind with no numbers yet
    /// gets a button, because that is a state the reader can change. Neither is
    /// ever a blank plot.
    /// What is actually on screen: the narrowed run when there is one, otherwise
    /// the saved result.
    ///
    /// One accessor rather than a branch at each use, because the chart, the
    /// legend and the CSV export all have to agree about which numbers they are
    /// describing. They did not have to before this screen could narrow, and a
    /// legend keyed to the saved series beneath a chart split by browser is the
    /// exact failure that makes.
    private func drawnModel(for insight: Insight) -> InsightRenderModel {
        store.narrowed ?? insight.renderModel
    }

    /// Whether the reader has asked for something other than the saved insight.
    private var isNarrowed: Bool {
        !filters.isEmpty || breakdown != .saved
    }

    /// States what the chart is showing whenever it is not the saved insight —
    /// and, separately, when a narrowing was asked for and did not arrive.
    ///
    /// The second half is the one that matters. A chart that quietly keeps
    /// drawing the saved, unfiltered numbers under a control the user set to
    /// "Chrome" is the lie this whole feature has to avoid, and it has three ways
    /// of happening: a refused request, a response that decoded to nothing, and an
    /// insight with no re-runnable source. `SavedInsightStore.narrowError` names
    /// which.
    @ViewBuilder
    private func narrowingNote(for insight: Insight) -> some View {
        if let error = store.narrowError {
            SectionEmptyState(
                text: error,
                systemImage: "exclamationmark.triangle",
                detail: "Asked for: \(narrowingSummary).",
                actionTitle: "Try again",
                action: applyNarrowing
            )
        } else if isNarrowed, store.narrowed != nil {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Label(narrowingSummary, systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // The 44pt floor inside the label, not around the button — see
                // `InsightAlertsView.controls` for the measurement. A caption-sized
                // label is the worst case for this: its intrinsic height is well
                // under half a fingertip.
                Button {
                    filters = []
                    breakdown = .saved
                    store.clearNarrowing()
                } label: {
                    Text("Clear")
                        .font(Theme.Typography.caption)
                        .frame(minHeight: 44)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Showing \(narrowingSummary). Double tap Clear to go back to the saved insight.")
        }
    }

    /// The narrowing in words, used by the caption, the failure detail and
    /// VoiceOver — one string so the three cannot describe it differently.
    private var narrowingSummary: String {
        var parts = filters.map(\.displayText)
        switch breakdown {
        case .saved: break
        case .none: parts.append("no breakdown")
        case .property(let value): parts.append("split by \(value.property)")
        }
        return parts.isEmpty ? "the saved insight" : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func chart(for insight: Insight) -> some View {
        Card(accent: TileStyle.accent(for: drawnModel(for: insight))) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if store.isNarrowing {
                    VStack(spacing: Theme.Space.s) {
                        ProgressView()
                        Text("Running…")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.xxl)
                } else if store.narrowed != nil || insight.hasDrawableResult {
                    InsightChartView(
                        model: drawnModel(for: insight),
                        compact: false,
                        webURL: webURL,
                        // The chart's descriptor has nowhere else to get a name.
                        title: insight.title,
                        // A full-size chart with nothing between it and a
                        // finger, so the gesture the tip describes works here.
                        showsScrubTip: true
                    )
                } else if store.isComputing || store.isLoading {
                    VStack(spacing: Theme.Space.s) {
                        ProgressView()
                        Text("Computing…")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.xxl)
                } else {
                    uncomputedState(for: insight)
                }

                if let failure = store.failure, insight.hasDrawableResult {
                    // Beside the chart, not instead of it: a recomputation that
                    // failed has not invalidated what is already drawn.
                    SectionEmptyState(
                        text: failure.summary,
                        systemImage: "exclamationmark.triangle",
                        detail: failure.detail,
                        actionTitle: "Try again",
                        action: recompute
                    )
                }
            }
            .padding(.leading, Theme.Space.s)
        }
    }

    /// Why there is no chart, in the words of whichever thing actually stopped
    /// it.
    ///
    /// The order matters. A *failed request* must not be reported as "PostHog
    /// hasn't computed this recently": those are different facts with different
    /// remedies, and the second is a confident claim about PostHog's cache made
    /// on the strength of a request that never got an answer. The empty-cache
    /// wording is only used when the fetch actually succeeded and came back
    /// without numbers.
    @ViewBuilder
    private func uncomputedState(for insight: Insight) -> some View {
        if !insight.isDrawableKind {
            UnsupportedInsightCard(kind: insight.sourceKind, webURL: webURL)
        } else if let failure = store.failure {
            SectionEmptyState(
                text: failure.summary,
                systemImage: "exclamationmark.triangle",
                detail: failure.detail,
                actionTitle: "Try again",
                action: recompute
            )
        } else {
            SectionEmptyState(
                text: "PostHog hasn't computed this insight recently, so there are no numbers to draw yet.",
                systemImage: "clock.arrow.circlepath",
                actionTitle: "Compute now",
                action: recompute
            )
        }
    }

    /// When the numbers were computed, and by whom.
    ///
    /// `FreshnessLabel` alone would say "not yet loaded" over a chart this
    /// screen had just computed itself, because a blocking recomputation returns
    /// `is_cached: false` and the timestamp arrives on the same response. So the
    /// screen states which of the two it is looking at.
    @ViewBuilder
    private func freshness(for insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            FreshnessLabel(date: insight.lastRefresh, isCached: insight.isCached)
            if store.didCompute {
                Text("Computed by this screen just now, not read from PostHog's cache.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
    }

    /// Where else this insight appears.
    ///
    /// Worth a section because it is the answer to "why am I seeing this number
    /// in two places", and because the dashboard is where the insight sits
    /// beside its context.
    ///
    /// **The name is not available here, and this screen does not buy it.**
    /// The row once rendered a raw numeric dashboard id in the slot where a
    /// name belongs, so the available data is spelled out here:
    ///
    /// - `Insight.dashboards` is `[Int]`, ids only.
    /// - The raw payload has nothing more. `GET /insights/:id/` also returns
    ///   `dashboard_tiles`, and each entry is `{id, dashboard_id, deleted}` —
    ///   the tile's id and the dashboard's, no title on either.
    /// - Nothing in the process holds a resolved list. `DashboardsStore` is
    ///   `@State` inside `DashboardsRoot`, so it does not outlive that screen and
    ///   is unreachable from this one; `AppModel` keeps no dashboard list;
    ///   `PostHogClient` has no read-through cache that a call site could consult
    ///   without also being willing to make the request.
    ///
    /// So the only way to print a name is `GET /api/projects/:id/dashboards/`,
    /// and **that request is not made**. The reasoning, since either choice is
    /// defensible:
    ///
    /// 1. It buys a *label*, not a capability. The destination is one tap away
    ///    and `DashboardDetailView` fetches and shows the real name on arrival,
    ///    so nothing here is unreachable without it — it would only be prettier
    ///    sooner.
    /// 2. It is not one small request. Per-id `GET /dashboards/:id/` returns the
    ///    dashboard *with its tiles*, so N ids is N multi-kilobyte responses to
    ///    extract N strings; the collection endpoint is one request but returns
    ///    up to 50 full summaries, and would still miss any dashboard past the
    ///    page. Either way the spend is out of proportion to a caption.
    /// 3. The budget is organisation-wide and shared with whatever else the user
    ///    has integrated. This screen already costs a resolve, a results
    ///    computation and a comment thread; a fourth request that no on-screen
    ///    decision depends on is the kind this app is supposed to decline.
    ///
    /// What is fixed instead is the *presentation*, which is where the actual
    /// defect was. A bare number in the title slot reads as a name that happens
    /// to be numeric; `#` marks it as an identifier, and the section says once,
    /// underneath, why there is a number there at all. The per-row subtitle that
    /// used to carry that explanation is gone — it was clipped to
    /// "Opens the dashboard this insight is a til…", which is a sentence that
    /// stops before it says anything, repeated on every row.
    private func dashboardLinks(for insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "On dashboards", systemImage: "square.grid.2x2")
            ForEach(insight.dashboards, id: \.self) { id in
                NavigationLink(value: DashboardReference(id: id)) {
                    // `DataRow.title` is a plain `String`, so this is ordinary
                    // string interpolation and the id is printed digit for digit.
                    // Worth keeping it that way: an id put through any number
                    // formatter is an id that no longer matches the URL it came
                    // from and cannot be pasted anywhere.
                    DataRow(glyph: "square.grid.2x2", title: "Dashboard #\(id)")
                }
                .buttonStyle(.plain)
            }
            Text(dashboardIDExplanation(count: insight.dashboards.count))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Said once under the rows rather than on each of them, for the same reason
    /// `StackTraceView` states the minified caveat once above its frames: it is
    /// one fact about the whole section, and repeating it per row is what made
    /// the previous wording too long to finish.
    private func dashboardIDExplanation(count: Int) -> String {
        count == 1
            ? "This insight is a tile on it. The insight carries the dashboard's id and not its name, so open it to see what it's called."
            : "This insight is a tile on each. The insight carries the dashboards' ids and not their names, so open one to see what it's called."
    }

    /// A type of this screen's own, rather than reusing `PostHogLink.dashboard`.
    ///
    /// This screen is hosted in three different stacks — the library's iPad
    /// detail column, the library's compact push, and the search tab's stack —
    /// and only the last of those has a `PostHogLink` destination registered.
    /// Pushing that type would have worked from search and silently done
    /// nothing on iPad, which is the failure mode that does not show up in a
    /// screenshot of the screen that works.
    ///
    /// A private type registered by this view is declared wherever this view is,
    /// so the link behaves the same in all three. It cannot collide with the
    /// search stack's own registrations either, which a second `PostHogLink`
    /// destination would.
    private struct DashboardReference: Hashable {
        let id: Int
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let insight {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        recompute()
                    } label: {
                        Label("Recompute results", systemImage: "arrow.clockwise")
                    }
                    // Two workflows, one menu, and both are hidden rather than
                    // disabled when they cannot apply — `InsightNarrowing` and
                    // `AlertableInsight` each know why, and each sheet states the
                    // reason on arrival. A permanently greyed item in a menu
                    // teaches nothing; the sheets do.
                    if InsightNarrowing(sourceKind: insight.sourceKind).isNarrowable {
                        Button {
                            isNarrowing = true
                        } label: {
                            Label(
                                isNarrowed ? "Change narrowing" : "Filter or split",
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        }
                    }
                    if AlertableInsight.isAlertable(sourceKind: insight.sourceKind) {
                        Button {
                            isShowingAlerts = true
                        } label: {
                            Label("Alerts", systemImage: "bell")
                        }
                    }
                    // Hidden rather than disabled when there is nothing to
                    // export: `InsightShareMenuItems` already declines to offer
                    // anything for a model it could not decode, and this keeps
                    // the two agreeing.
                    Divider()
                    // Exports what is drawn, not what was saved. A CSV of the
                    // saved series under a title the reader has just narrowed
                    // would be the same lie the caption exists to prevent — worse,
                    // because it leaves the file system.
                    InsightShareMenuItems(title: insight.title, model: drawnModel(for: insight))
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
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Insight actions")
            }
        }
    }

    /// The console's page for this insight.
    ///
    /// Built from `linkID`, which prefers the short handle — the spelling every
    /// link a user is *given* uses, so a link shared from here matches one they
    /// may already have.
    private var webURL: URL? {
        model.webURL(path: "insights/\(insight?.linkID ?? identifier)")
    }

    private func readableKind(_ sourceKind: String) -> String {
        sourceKind.replacingOccurrences(of: "Query", with: "")
    }

    // MARK: - Loading

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        if let seeded { store.seed(seeded) }
        await store.resolve(client: client, projectID: projectID, identifier: identifier)
        await store.loadResults(client: client, projectID: projectID)

        // After the resolve, so the home-screen menu gets the insight's real
        // name rather than the placeholder a link arrives with — the same order
        // and the same reason as `DashboardDetailView`'s.
        //
        // `QuickActions` has had an `.insight` arm in `subtitle(for:)` and
        // `symbol(for:)` since before this screen existed, and nothing could
        // ever reach it: recording a visit would have produced a shortcut whose
        // link `opensInApp` refused. Both halves are real now.
        if let resolved = store.insight {
            QuickActions.recordVisit(
                .insight(shortID: resolved.linkID),
                title: resolved.title,
                projectID: projectID
            )
            QuickActions.refresh(projectID: projectID)

            // The in-app twin of `GetMetricValueIntent`: the user asked for this
            // insight and the app has now put its number in front of them.
            //
            // After `loadResults`, and that is what makes the donation honest in
            // both directions. It is the first moment the app knows whether this
            // insight reduces to a single spoken value at all — the collection
            // endpoint hands back rows with no results — so an insight Siri
            // could only refuse is filtered out here rather than promoted into a
            // suggestion. `IntentDonations.metricRead` makes that call.
            //
            // Every route to this screen is a user act: a row in the library, a
            // search result, a `posthog.com` link, a home-screen shortcut.
            // Nothing restores an insight into a window on its own, which is why
            // this can sit beside `recordVisit` rather than needing a gesture.
            IntentDonations.metricRead(resolved)
        }
    }

    private func recompute() {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task { await store.compute(client: client, projectID: projectID) }
    }

    /// Spends the one `.query` this feature costs, and only from the sheet's
    /// Apply or from the failure state's Try again. Never from a picker's
    /// `onChange`, never from a `.task(id:)` keyed on the selection — both would
    /// turn browsing into a request per tap on a budget the whole organisation
    /// shares.
    private func applyNarrowing() {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            await store.applyNarrowing(
                dateFrom: nil,
                compare: false,
                filters: filters,
                breakdown: breakdown,
                client: client,
                projectID: projectID
            )
        }
    }
}
