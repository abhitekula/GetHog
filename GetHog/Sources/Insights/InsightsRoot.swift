import GetHogKit
import SwiftUI

/// The saved-insight library.
///
/// The largest collection in a typical project and, until now, the one this app
/// could only see through a dashboard: the project this was built against holds
/// **140 saved insights against 14 dashboards**, and an insight saved from the
/// console's own editor belongs to no dashboard at all, so it had no route into
/// the app whatsoever.
///
/// It is a `NavigationSplitView` for the same reason Errors and People are — a
/// list whose rows have a substantial detail — and it collapses to a plain push
/// in compact width for the same reason too: this screen is reached through the
/// search tab on a phone, which already owns a navigation stack, and nesting a
/// split view inside it draws a second navigation bar above the first.
struct InsightsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(OpenDetails.self) private var openDetails

    @State private var store = InsightsStore()
    @State private var search = ""
    @State private var kind: InsightKind?
    @State private var favouritesOnly = false

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

    private var selected: Insight? {
        selectedID.wrappedValue.flatMap { id in store.insights.first { $0.id == id } }
    }

    /// The three filters as one value, so `.task(id:)` fires once when two of
    /// them change together rather than racing two reloads against each other.
    private var request: InsightsRequest {
        InsightsRequest(search: search, kind: kind, favouritesOnly: favouritesOnly)
    }

    var body: some View {
        if sizeClass == .compact {
            list
                // Bound to the selection rather than registered `for:`, for the
                // reason `ErrorTrackingRoot` documents: a `for:` destination is
                // driven by the *container's* path, which this screen can
                // neither read nor write, so an insight open at one width would
                // be invisible at the other.
                .navigationDestination(item: selectedID) { id in
                    SavedInsightDetailView(
                        identifier: String(id),
                        seed: store.insights.first { $0.id == id }
                    )
                    .id(id)
                }
        } else {
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
                detailPane
            }
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
        } else if store.insights.isEmpty {
            emptyState
        } else {
            EmptyStateView(
                title: "Pick an insight",
                systemImage: "chart.xyaxis.line",
                message: store.coverageSummary
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
            .navigationTitle("Insights")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search insight names")
            .refreshable { await load() }
            // One task covers project switches, typing and both filters.
            // Searching is server-side, so a burst of keystrokes is debounced
            // into one request rather than one request per character — the same
            // arrangement, and the same 400ms, as the People screen's.
            .task(id: TaskKey(projectID: model.projectID, request: request)) {
                if !search.isEmpty {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                }
                await load()
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
        } else if let failure = store.failure, store.insights.isEmpty {
            LoadFailureState(title: "Couldn't load insights", failure: failure) {
                Task { await load() }
            }
        } else if store.insights.isEmpty && !store.isLoading {
            emptyState
        } else {
            rows
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
                favouritesOnly = false
            }
        } else {
            EmptyStateView(
                title: "No saved insights",
                systemImage: "chart.xyaxis.line",
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
        if favouritesOnly { parts.append("marked as favourites") }
        return "No saved insight in this project is " + parts.joined(separator: ", ") + "."
    }

    private var rows: some View {
        List(selection: selectedID) {
            // Favourites first, and the heading only when there are any. This
            // project has zero, so the section must not leave an empty heading
            // implying the app failed to load something.
            if !store.favourites.isEmpty {
                Section {
                    ForEach(store.favourites) { row($0) }
                } header: {
                    SectionLabel(text: "Favourites", systemImage: "star.fill")
                }
            }

            Section {
                ForEach(store.others) { row($0) }
            } header: {
                if !store.favourites.isEmpty {
                    SectionLabel(text: "All insights")
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

    /// Kind and favourites, above the list.
    ///
    /// A menu rather than a segmented control at every size: there are seven
    /// kinds plus "All", and eight segments on a phone is eight illegible
    /// slivers before Dynamic Type is even considered.
    private var filterBar: some View {
        GlassFilterBar {
            Picker("Insight kind", selection: $kind) {
                Text("All kinds").tag(InsightKind?.none)
                ForEach(InsightKind.allCases) { option in
                    Text(option.title).tag(InsightKind?.some(option))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)

            Spacer(minLength: 0)

            Toggle(isOn: $favouritesOnly) {
                favouritesLabel
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(favouritesOnly ? Theme.accentWarm : Theme.accent)
            .accessibilityLabel("Show only favourites")
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// The word joins the glyph at accessibility sizes.
    ///
    /// A filled-versus-hollow star is a state told entirely by shape, at a size
    /// chosen for someone who does not need the type scaled up. Two branches
    /// rather than a ternary on `.labelStyle`, because the two styles are
    /// different concrete types and cannot share an expression.
    @ViewBuilder
    private var favouritesLabel: some View {
        let label = Label("Favourites", systemImage: favouritesOnly ? "star.fill" : "star")
        if dynamicTypeSize.isAccessibilitySize {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
    }

    private func row(_ insight: Insight) -> some View {
        NavigationLink(value: insight.id) {
            DataRow(
                glyph: TileStyle.symbol(for: insight.renderModel),
                // Favourites take the warm secondary, the same way generated
                // dashboards do on the Dashboards list — a distinction the
                // "Favourites" heading above already states in words, so nothing
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
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
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
        .contextMenu {
            if let url = model.webURL(path: "insights/\(insight.linkID)") {
                Link(destination: url) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("Copy link", systemImage: "link")
                }
            }
        }
    }

    /// Kind and freshness, in that order.
    ///
    /// `lastModifiedAt` rather than `lastRefresh`: measured against project
    /// [REMOVED PRIVATE DATA], `last_refresh` is null on all 140 saved insights, so a row built
    /// on it would print nothing at all for every insight in the project. When
    /// the definition last changed is a fact every row actually has.
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
            } else if let failure = store.failure, !store.insights.isEmpty {
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
        await store.load(client: client, projectID: projectID, request: request)
    }

    private func loadMore() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadMore(client: client, projectID: projectID)
    }
}
