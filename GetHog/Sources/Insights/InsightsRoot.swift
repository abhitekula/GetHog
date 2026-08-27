import GetHogKit
import GetHogUI
import SwiftUI

/// The saved-insight library.
///
/// Often one of the largest collections in a project and, until now, one this
/// app could only see through a dashboard. An insight saved from the console's
/// own editor can belong to no dashboard at all, so it had no route into the app.
///
/// It is a `NavigationSplitView` for the same reason Errors and People are — a
/// list whose rows have a substantial detail — and it collapses to a plain push
/// in compact width for the same reason too: this screen is reached through the
/// search tab on a phone, which already owns a navigation stack, and nesting a
/// split view inside it draws a second navigation bar above the first.
struct InsightsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.screenNavigationPlacement) private var navigationPlacement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(OpenDetails.self) private var openDetails

    @State private var store = InsightsStore()
    @State private var quickPreviewStore = InsightQuickPreviewStore()
    @State private var search = ""
    @State private var kind: InsightKind?
    @State private var favoritesOnly = false
    #if os(tvOS)
    @State private var isChoosingKind = false
    #endif

    /// The open insight, and deliberately **not** `@State`.
    ///
    /// This screen is one of the 27 reached through the search tab, so it is
    /// hosted by a sidebar `Tab` above the size-class boundary and by the search
    /// stack below it. Crossing the boundary swaps hosts and rebuilds the
    /// screen, which throws `@State` away — the defect `OpenDetails` was
    /// measured against on Errors, where an open issue vanished at 834→375pt and
    /// did not come back on the way up.
    ///
    /// `Insight` is not `Hashable`, and making it so would mean deciding what
    /// equality means for a decoded API row. The **id** is carried instead and
    /// the row is looked back up, which is also what keeps the selection valid
    /// after a filter change reloads the list.
    private var selectedID: Binding<Int?> {
        Binding(
            get: { openDetails[.insights] as? Int },
            set: { openDetails[.insights] = $0.map(AnyHashable.init) }
        )
    }

    /// Compact navigation must stop being driven by an old project/filter id
    /// in the same render that the live scope changes. Gating only the detail's
    /// seed is too late: a non-nil destination can still fetch that id against
    /// the replacement project.
    private var currentScopeSelectedID: Binding<Int?> {
        Binding(
            get: {
                InsightsSelectionAuthority.current(
                    selectedID: selectedID.wrappedValue,
                    publishesCurrentScope: publishesCurrentScope
                )
            },
            set: { selectedID.wrappedValue = $0 }
        )
    }

    private var selected: Insight? {
        guard publishesCurrentScope else { return nil }
        return selectedID.wrappedValue.flatMap { id in
            store.insights.first { $0.id == id }
        }
    }

    /// The three filters as one value, so `.task(id:)` fires once when two of
    /// them change together rather than racing two reloads against each other.
    private var request: InsightsRequest {
        InsightsRequest(search: search, kind: kind, favoritesOnly: favoritesOnly)
    }

    /// The screen may change authority one render before its replacement task
    /// begins. Gate every row-derived surface against committed provenance so
    /// that frame cannot relabel old rows with the new project or filters.
    private var publishesCurrentScope: Bool {
        store.publishes(projectID: model.projectID, request: request)
    }

    private var currentScopeFailure: LoadFailure? {
        store.failure(projectID: model.projectID, request: request)
    }

    private var requestAuthority: ResourceRequestAuthority? {
        guard
            let client = model.client,
            let projectID = model.projectID,
            let authSessionID = model.authSessionID
        else { return nil }
        return ResourceRequestAuthority(
            projectID: projectID,
            region: client.region,
            authSessionID: authSessionID
        )
    }

    private var usesHostNavigation: Bool {
        sizeClass == .compact || navigationPlacement == .visionSectionDetail
    }

    #if os(macOS)
    @Environment(\.macRegularListWidth) private var macRegularListWidth
    #endif

    var body: some View {
        if usesHostNavigation {
            list
                // Bound to the selection rather than registered `for:`, for the
                // reason `ErrorTrackingRoot` documents: a `for:` destination is
                // driven by the *container's* path, which this screen can
                // neither read nor write, so an insight open at one width would
                // be invisible at the other.
                .navigationDestination(item: currentScopeSelectedID) { id in
                    SavedInsightDetailView(
                        identifier: String(id),
                        seed: store.insights.first { $0.id == id }
                    )
                    .id(id)
                }
        } else {
            #if os(macOS)
            MacRegularListDetailSplit(
                accessibilityIdentifier: "gethog.mac-product-divider.insights",
                accessibilityLabel: "Insights list width",
                minimumListWidth: 300,
                idealListWidth: 380,
                maximumListWidth: 440,
                preferredListWidth: macRegularListWidth
            ) {
                list
            } detail: {
                // Its own stack, so `NavigationLink(value:)` inside the detail
                // has somewhere to push.
                NavigationStack {
                    detailPane
                }
            }
            #else
            NavigationSplitView {
                list
                    // Sized to the row: a title that wraps to two lines, the
                    // author's description under it, and a footnote carrying the
                    // kind and the modified date. Narrower than this and every
                    // description truncated to a few words, which is the one
                    // line saying what the chart is *for*.
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 440)
                    // The tab sidebar already puts a toggle in this bar; the
                    // split view added a second, identical one beside it.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                // Its own stack, so `NavigationLink(value:)` inside the detail
                // has somewhere to push. Without it the "On dashboards →
                // Dashboard #N" rows were dead at regular width — the
                // destination is registered on the detail view itself, and a
                // bare split-view column is not a navigation container.
                NavigationStack {
                    detailPane
                }
            }
            #endif
        }
    }

    // MARK: - Detail column

    /// The chosen insight, or an honest account of the collection when nothing
    /// is chosen.
    ///
    /// Mirrors the list's own states rather than summarising thin air: a locked
    /// key, a project with no saved insights, and a filter that matched nothing
    /// are three different facts and the detail column is the largest surface
    /// available to state them on.
    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            SavedInsightDetailView(selected)
                // Rebuilds per insight, so opening a second one cannot inherit
                // the first one's computed results.
                .id(selected.id)
        } else if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if !publishesCurrentScope {
            pendingScopeState
        } else if store.insights.isEmpty {
            emptyState
        } else {
            InsightsOverview(
                store: store,
                selection: selectedID
            )
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        content
            // The list paints its own ground; this covers the strip the filter
            // bar sits on, which would otherwise stay system grey and leave the
            // glass floating on the wrong surface.
            .background(Theme.pageBackground)
            .topLevelNavigationTitle("Insights")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .onChange(of: requestAuthority, initial: true) { _, _ in
                quickPreviewStore.invalidate()
            }
            // Absent on tvOS for the reason `DashboardsRoot` records in
            // full: the field takes initial focus there and raises the
            // full-screen grid keyboard over the list it filters.
            #if !os(tvOS)
            .searchable(text: $search, prompt: "Search insight names")
            #endif
            .screenRefreshable { await load() }
            // One task covers project switches, typing and both filters.
            // Searching is server-side, so a burst of keystrokes is debounced
            // into one request rather than one request per character — the same
            // arrangement, and the same 400ms, as the People screen's.
            .task(id: TaskKey(projectID: model.projectID, request: request)) {
                // `ChartScrubTip`'s rule is a `@Parameter` that only four screens
                // were pushing capabilities into — and none of them is on the
                // route to a saved insight, which is one of the two screens that
                // now hosts the tip. Reaching Insights straight from the search
                // tab on a fresh install left the parameter `false`, so the tip
                // was eligible nowhere the user had actually gone. Same call the
                // other four make; TipKit suppresses the tip if the key cannot
                // reach the feature.
                AppTips.refresh(from: model)
                if !search.isEmpty {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                }
                await load()
            }
            .onChange(of: model.projectID) { _, _ in
                // An insight id is project-scoped. Keeping a compact push alive
                // across a switch could ask Project B for Project A's id before
                // the replacement list has committed.
                selectedID.wrappedValue = nil
            }
    }

    /// One value so a change to the project or to any filter re-runs exactly
    /// once, and so two of them changing together do not run it twice.
    private struct TaskKey: Equatable {
        let projectID: Int?
        let request: InsightsRequest
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            // `insight:read` is one of this capability's two scopes, so a key
            // that cannot open Dashboards cannot open this screen either. The
            // same gate, named the same way, rather than a second one that could
            // disagree with it.
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if !publishesCurrentScope {
            pendingScopeState
        } else if let failure = currentScopeFailure, store.insights.isEmpty {
            LoadFailureState(title: "Couldn't load insights", failure: failure) {
                Task { await load() }
            }
        } else if store.insights.isEmpty && !store.isLoading {
            emptyState
        } else {
            rows
        }
    }

    /// The current authority has not published a valid first page yet. This is
    /// intentionally distinct from a successful empty result, whose provenance
    /// is committed and therefore flows into `emptyState` above.
    @ViewBuilder
    private var pendingScopeState: some View {
        if let failure = currentScopeFailure, !store.isLoading {
            LoadFailureState(title: "Couldn't load insights", failure: failure) {
                Task { await load() }
            }
        } else {
            ProgressView("Loading insights…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pageBackground)
        }
    }

    /// Two different facts, said differently.
    ///
    /// "This project has no saved insights" and "nothing matched what you asked
    /// for" look identical on screen and are not the same thing at all — one is
    /// about the project, the other about three controls the reader can change.
    @ViewBuilder
    private var emptyState: some View {
        if request.isFiltering {
            EmptyStateView(
                title: "No matching insights",
                systemImage: "magnifyingglass",
                message: filterDescription,
                actionTitle: "Clear filters"
            ) {
                search = ""
                kind = nil
                favoritesOnly = false
            }
        } else {
            EmptyStateView(
                title: "No saved insights",
                systemImage: "chart.xyaxis.line",
                illustration: .insights,
                message: "Nothing has been saved as an insight in this project yet."
            )
        }
    }

    /// Names every filter that is on, so a reader can see which one to undo.
    private var filterDescription: String {
        var parts: [String] = []
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty { parts.append("named like “\(term)”") }
        if let kind { parts.append("of kind \(kind.title)") }
        if favoritesOnly { parts.append("marked as favorites") }
        return "No saved insight in this project is " + parts.joined(separator: ", ") + "."
    }

    private var rows: some View {
        List(selection: selectedID) {
            // Favorites first, and the heading only when there are any. This
            // project has zero, so the section must not leave an empty heading
            // implying the app failed to load something.
            if !store.favorites.isEmpty {
                Section {
                    ForEach(store.favorites) { row($0) }
                } header: {
                    SectionLabel(text: "Favorites", systemImage: "star.fill", productMark: .dashboard)
                }
            }

            Section {
                ForEach(store.others) { row($0) }
            } header: {
                if !store.favorites.isEmpty {
                    SectionLabel(text: "All insights", productMark: .dashboard)
                }
            }

            footer
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.insights.isEmpty)
        // Pinned rather than scrolled away, as the Errors filter is: these two
        // controls are what explains *which* of 140 insights the list is
        // showing, so scrolling them off leaves a filtered list looking like a
        // short one.
        .safeAreaInset(edge: .top) {
            filterBar
                .padding(.bottom, Theme.Space.s)
        }
    }

    /// Kind and favorites, above the list.
    ///
    /// A menu rather than a segmented control at every size: there are seven
    /// kinds plus "All", and eight segments on a phone is eight illegible
    /// slivers before Dynamic Type is even considered.
    @ViewBuilder
    private var filterBar: some View {
        #if os(tvOS)
        televisionFilterBar
        #else
        GlassFilterBar {
            Picker("Insight kind", selection: $kind) {
                Text("All kinds").tag(InsightKind?.none)
                ForEach(InsightKind.allCases) { option in
                    Text(option.title).tag(InsightKind?.some(option))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)
            // Pushes the toggle to the trailing edge in a row, and takes the
            // whole line when `GlassFilterBar` stacks. A `Spacer` between the two
            // did the first and, once the bar stacked, became a *vertical* gap
            // between two rows that were already spaced.
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $favoritesOnly) {
                favoritesLabel
            }
            // `toggleStyle(.button)` is unavailable on tvOS; the platform's own
            // toggle is already focusable and already states its state.
            #if !os(tvOS)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            #endif
            .tint(favoritesOnly ? Theme.accentWarm : Theme.accent)
            .accessibilityLabel("Show only favorites")
        }
        .padding(.vertical, Theme.Space.xs)
        #endif
    }

    #if os(tvOS)
    /// Explicit value-bearing controls for a focus engine.
    ///
    /// A menu-style `Picker` plus the platform `Toggle` is compact on touch but
    /// renders on television as two accent blobs, one with a clipped "Off" and
    /// neither with enough text to identify it. These keep the exact same state
    /// and choices while giving each focus surface one stable, readable label.
    private var televisionFilterBar: some View {
        HStack(spacing: Theme.Space.l) {
            Button {
                isChoosingKind = true
            } label: {
                Label(kind?.title ?? "All kinds", systemImage: "line.3.horizontal.decrease.circle")
                    .lineLimit(1)
                    .frame(minWidth: 300, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .televisionAccentControlInk()
            .accessibilityLabel("Insight kind: \(kind?.title ?? "All kinds")")
            .confirmationDialog(
                "Insight kind",
                isPresented: $isChoosingKind,
                titleVisibility: .visible
            ) {
                Button {
                    kind = nil
                } label: {
                    if kind == nil {
                        Label("All kinds", systemImage: "checkmark")
                    } else {
                        Text("All kinds")
                    }
                }
                .accessibilityLabel(kind == nil ? "All kinds, selected" : "All kinds")
                ForEach(InsightKind.allCases) { option in
                    Button {
                        kind = option
                    } label: {
                        if kind == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                    .accessibilityLabel(kind == option ? "\(option.title), selected" : option.title)
                }
            }

            Button {
                favoritesOnly.toggle()
            } label: {
                Label(
                    "Favorites: \(favoritesOnly ? "On" : "Off")",
                    systemImage: favoritesOnly ? "star.fill" : "star"
                )
                .lineLimit(1)
                .frame(minWidth: 260, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .televisionAccentControlInk()
            .accessibilityLabel("Favorites: \(favoritesOnly ? "On" : "Off")")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .warmGlass(in: .rect(cornerRadius: Theme.Radius.medium, style: .continuous))
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
    }
    #endif

    /// The word joins the glyph at accessibility sizes.
    ///
    /// A filled-versus-hollow star is a state told entirely by shape, at a size
    /// chosen for someone who does not need the type scaled up. Two branches
    /// rather than a ternary on `.labelStyle`, because the two styles are
    /// different concrete types and cannot share an expression.
    @ViewBuilder
    private var favoritesLabel: some View {
        let label = Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
        if dynamicTypeSize.isAccessibilitySize {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
    }

    private func row(_ insight: Insight) -> some View {
        let scope = requestAuthority.map {
            InsightPreviewScope(authority: $0, insightID: insight.id)
        }
        return NavigationLink(value: insight.id) {
            DataRow(
                glyph: TileStyle.symbol(for: insight.renderModel),
                // Favorites take the warm secondary, the same way generated
                // dashboards do on the Dashboards list — a distinction the
                // "Favorites" heading above already states in words, so nothing
                // here rests on the tint alone.
                tint: insight.favorited ? Theme.accentWarm : Theme.accent,
                title: insight.title,
                subtitle: insight.description,
                // Two facts a reader scans for: what kind of chart it is, and
                // whether anyone has touched it lately. Two lines allowed,
                // because on a narrow column the kind alone can push the date
                // off the end and the date is the half that differs between
                // rows.
                footnote: footnote(for: insight),
                footnoteLineLimit: 2,
                accessory: .none
            )
        }
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
        )
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("gethog.insight-card.\(insight.id)")
        .quickPreview {
            InsightQuickPreview(
                summary: insight,
                state: quickPreviewStore.state(for: scope)
            )
            .task(id: scope) {
                await quickPreviewStore.activate(client: model.client, scope: scope)
            }
        } menuItems: {
            Button {
                selectedID.wrappedValue = insight.id
            } label: {
                Label("Open Insight", systemImage: "arrow.right.circle")
            }
        }
        // The page after this one is fetched when its last row appears rather
        // than from a button, because 140 insights is three pages and a reader
        // scrolling a list should not have to ask for the rest of it. Guarded
        // inside the store, which ignores the call when a page is already in
        // flight or the server said there is no more.
        .onAppear {
            if insight.id == store.insights.last?.id {
                Task { await loadMore() }
            }
        }
    }

    /// Kind and freshness, in that order.
    ///
    /// `lastModifiedAt` rather than optional cache freshness: when the definition
    /// last changed is a durable fact even when no result has been refreshed.
    private func footnote(for insight: Insight) -> String? {
        var parts = [insight.kind?.title ?? insight.sourceKind.replacingOccurrences(of: "Query", with: "")]
        if let modified = insight.lastModifiedAt {
            parts.append("edited \(modified.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    /// What is on screen, what is still coming, and when it arrived.
    ///
    /// The coverage line is not decoration: this list truncates by design on
    /// every project with more than 50 insights, and a list that stops with no
    /// explanation is the same silent truncation the search screen states too.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if store.isLoadingMore {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Loading more…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            } else if let failure = currentScopeFailure, !store.insights.isEmpty {
                // A failed *next* page, with rows already on screen. Stated
                // here rather than replacing the list, which would throw away
                // 50 good insights because the 51st did not arrive.
                SectionEmptyState(
                    text: failure.summary,
                    systemImage: "exclamationmark.triangle",
                    detail: failure.detail,
                    actionTitle: "Try again",
                    action: { Task { await loadMore() } }
                )
            }
            if let coverage = store.coverageSummary {
                Text(coverage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            FreshnessLabel(date: store.loadedAt)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Loading

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(
            client: client,
            projectID: projectID,
            request: request,
            projectName: model.selectedProject?.name
        )
    }

    private func loadMore() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadMore(client: client, projectID: projectID)
    }
}

/// What the regular-width detail pane shows before an insight is picked.
///
/// The library is paged and can also be filtered, so every aggregate here is
/// scoped to the rows already loaded. Nothing on this surface triggers a query
/// or computes an insight result; its only actions select real rows the sidebar
/// is already holding.
private struct InsightsOverview: View {
    let store: InsightsStore
    @Binding var selection: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var facts: InsightOverviewFacts {
        InsightOverviewFacts(
            insights: store.insights,
            total: store.total,
            hasMore: store.hasMore,
            isFiltering: store.loadedRequest?.isFiltering ?? false
        )
    }

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            summaryScene
            kindsSection
            recentlyEditedSection
            FreshnessLabel(date: store.loadedAt)
        }
        .accessibilityIdentifier("gethog.insights-overview")
    }

    // MARK: - Summary

    private var summaryScene: some View {
        Card(accent: Theme.SignalChrome.teal) {
            summaryLayout
        }
        // A real accessibility container, not an invisible geometry anchor:
        // descendants keep their labels while the summary exposes the card's
        // rendered frame to the focused regular-width visual contract.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gethog.signal-summary.insights")
        .signalConfirmation(trigger: store.loadedAt)
    }

    @ViewBuilder
    private var summaryLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            compactSummary
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.xxl) {
                    libraryIdentity
                        .frame(maxWidth: 320, alignment: .leading)
                    libraryMetrics
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                compactSummary
            }
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            libraryIdentity
            SignalRule(mark: .dashboard)
            libraryMetrics
        }
    }

    private var libraryIdentity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(store.loadedProjectName ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            Text(facts.coverageSummary)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private var libraryMetrics: some View {
        StatStrip(stacksAtAccessibilitySizes: true) {
            MetricTile(
                label: facts.qualifiesMetricsAsLoaded ? "Loaded insights" : "Insights",
                value: "\(facts.loadedCount)",
                compact: true
            )
            MetricTile(
                label: facts.qualifiesMetricsAsLoaded ? "Loaded favorites" : "Favorites",
                value: "\(facts.favoriteCount)",
                compact: true
            )
            MetricTile(
                label: facts.qualifiesMetricsAsLoaded ? "Loaded kinds" : "Kinds",
                value: "\(facts.kindCount)",
                compact: true
            )
        }
        .padding(.horizontal, -Theme.Space.l)
    }

    // MARK: - Groups

    private var kindsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Kinds represented", systemImage: "chart.bar.xaxis")

            Text("Among the \(facts.loadedCount) insights loaded. Open the newest of each kind.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)

            VStack(spacing: Theme.Space.s) {
                ForEach(facts.kindGroups) { group in
                    overviewRow(
                        group.newest,
                        identifier: "gethog.insights-overview.kind.\(group.id)",
                        title: group.title,
                        subtitle: group.count == 1
                            ? "1 insight loaded" : "\(group.count) insights loaded",
                        footnote: newestFootnote(group.newest),
                        accessory: .metric("\(group.count)")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var recentlyEditedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(
                text: "Recently edited of those loaded",
                systemImage: "clock.arrow.circlepath"
            )

            if facts.recentlyEdited.isEmpty {
                Card {
                    Label(
                        "No loaded insight includes an edit timestamp.",
                        systemImage: "info.circle"
                    )
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
                }
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(facts.recentlyEdited) { insight in
                        overviewRow(
                            insight,
                            identifier: "gethog.insights-overview.recent.\(insight.id)",
                            title: insight.title,
                            subtitle: insight.description,
                            footnote: recentFootnote(insight),
                            accessory: .none
                        )
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func overviewRow(
        _ insight: Insight,
        identifier: String,
        title: String,
        subtitle: String?,
        footnote: String?,
        accessory: RowAccessory
    ) -> some View {
        Button {
            selection = insight.id
        } label: {
            Card(padding: Theme.Space.m) {
                DataRow(
                    glyph: TileStyle.symbol(for: insight.renderModel),
                    tint: insight.favorited ? Theme.accentWarm : Theme.accent,
                    title: title,
                    subtitle: subtitle,
                    footnote: footnote,
                    footnoteLineLimit: 2,
                    accessory: accessory
                )
            }
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        .pointerHighlight(cornerRadius: Theme.Radius.medium)
        .accessibilityIdentifier(identifier)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            InsightOverviewAccessibility.spokenSummary(
                title: title,
                subtitle: subtitle,
                footnote: footnote
            )
        )
    }

    private func newestFootnote(_ insight: Insight) -> String? {
        if let modified = insight.lastModifiedAt {
            return "Newest edited \(modified.formatted(.relative(presentation: .named)))"
        }
        return insight.createdAt.map {
            "Newest created \($0.formatted(.relative(presentation: .named)))"
        }
    }

    private func recentFootnote(_ insight: Insight) -> String {
        let kind = insight.kind?.title ?? "Other"
        guard let modified = insight.lastModifiedAt else { return kind }
        return "\(kind) · Edited \(modified.formatted(.relative(presentation: .named)))"
    }

}
