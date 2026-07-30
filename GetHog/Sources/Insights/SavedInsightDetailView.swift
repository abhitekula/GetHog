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
            .navigationDestination(for: DashboardReference.self) { reference in
                DashboardDetailView(dashboardID: reference.id)
            }
            .toolbar { toolbarContent }
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

                if case .timeSeries(let series, _) = insight.renderModel, !series.isEmpty {
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
                    Label("Favourite", systemImage: "star.fill")
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
    @ViewBuilder
    private func chart(for insight: Insight) -> some View {
        Card(accent: TileStyle.accent(for: insight.renderModel)) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if insight.hasDrawableResult {
                    InsightChartView(
                        model: insight.renderModel,
                        compact: false,
                        webURL: webURL,
                        // The chart's descriptor has nowhere else to get a name.
                        title: insight.title
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
    /// without numbers — which, measured against project [REMOVED PRIVATE DATA], is what all 140
    /// saved insights do.
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
    /// Worth a row because it is the answer to "why am I seeing this number in
    /// two places", and because the dashboard is where the insight sits beside
    /// its context. Ids only — the names would cost one request per dashboard,
    /// and `DashboardDetailView` fetches its own title anyway.
    private func dashboardLinks(for insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "On dashboards", systemImage: "square.grid.2x2")
            ForEach(insight.dashboards, id: \.self) { id in
                NavigationLink(value: DashboardReference(id: id)) {
                    DataRow(
                        glyph: "square.grid.2x2",
                        title: "Dashboard \(id)",
                        subtitle: "Opens the dashboard this insight is a tile on"
                    )
                }
                .buttonStyle(.plain)
            }
        }
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
                    // Hidden rather than disabled when there is nothing to
                    // export: `InsightShareMenuItems` already declines to offer
                    // anything for a model it could not decode, and this keeps
                    // the two agreeing.
                    Divider()
                    InsightShareMenuItems(title: insight.title, model: insight.renderModel)
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
}
