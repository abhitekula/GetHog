import GetHogKit
import SwiftUI

/// One field over everything the app can reach.
///
/// The screens this app is made of are each scoped to one product, which means
/// finding an object costs you knowing which product it belongs to first. The
/// project index removes that step for the price of a single request, so this
/// screen spends that request once and then answers every question locally.
///
/// In compact width it is also the app's own index: the phone's tab bar holds
/// five items, four of which are product surfaces, so the way to every screen
/// beyond those four — `AppTab.secondary`, which has grown steadily and is not
/// worth restating as a literal that goes stale on the next one — and the way to
/// the project's 200 objects share the fifth. Sharing the
/// slot means sharing the field, which is the better outcome anyway — two
/// separate searches, one for screens and one for objects, is a question the
/// user should never have had to answer before typing.
///
/// It is a search surface, not a file browser: folders are the index's own
/// filing structure and are never a destination here, only context printed under
/// a name and a second thing a query can match.
///
/// The screen index is rendered **first and unconditionally**, before anything
/// that depends on the network. A locked scope or a failed request must never
/// take 24 destinations down with it — on a phone this list is the only route to
/// them.
struct ProjectSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(NavPreferences.self) private var nav
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = ProjectSearchStore()
    @State private var recents = RecentSearchStore()
    @State private var query = ""
    /// A survey opens as a sheet, because that is how `SurveyDetailSheet` is
    /// presented from the Surveys screen and it carries its own navigation stack.
    @State private var surveyRequest: SurveySearchRequest?

    /// The iPad sidebar already lists every screen, so only the phone needs the
    /// index half — and pushing a screen here would put it in this tab's stack
    /// where the sidebar's selection would not follow it.
    private var showsScreens: Bool { sizeClass == .compact }

    var body: some View {
        List {
            if showsScreens {
                ScreenIndexSections(query: query, loose: nav.barTabs)
            }
            objects
            if !store.entries.isEmpty {
                summary
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle("Search")
        .toolbar { ProjectSwitcher() }
        .projectSubtitle()
        // Pinned open, the way Events pins its filter, and for a stronger
        // reason: this field is the tab's entire purpose. Left to the default
        // drawer behaviour it rested *collapsed* — an empty grey capsule with
        // no glyph and no prompt, reproduced across three sweeps as "the
        // search tab looks dead on arrival" — and only a pull-down revealed
        // that a field existed at all.
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: prompt
        )
        .searchSuggestions { suggestions }
        // Submitting is not what runs the search — filtering is live over an
        // index already in memory — so this hook exists only to write the term
        // down. Accepting a suggestion submits too, which is what keeps a term
        // offered once and then chosen from climbing back to the top of the
        // list on its own.
        .onSubmit(of: .search) { recents.record(query) }
        // One rotor, over the screen index, and this screen wants it more than
        // any other list in the app: on a phone it is the *only* route to every
        // screen in `AppTab.secondary`, so it is the one list where "scroll
        // until you find it" is not a fallback but the whole navigation model —
        // and scroll position is exactly what a VoiceOver user does not have.
        //
        // Entry ids are `AppTab` values keyed by `\.self`, which is the identity
        // `ScreenIndexSections` gives its own `ForEach`, and the entries are
        // filtered by the same rule — so a query that cuts the index to three
        // names leaves three entries in the rotor.
        //
        // **A second rotor over the object-type groups was written, measured and
        // removed.** It jumped to the head of each result group — Dashboards,
        // Insights, Flags — which is the half of this screen a rotor would help
        // most, since the demo project's index is 140 insights against 14
        // dashboards. It registered correctly under the name "Object types" and
        // returned **zero entries**, twice: once with the group heads carried as
        // anchors keyed by `FileSystemEntry.id`, and again with the entries as
        // `FileSystemEntry` values keyed by `\.self` against a `ForEach` keyed
        // the same way. The rows were rendered and were on screen — the tree
        // read back eight dashboard rows by name — so this is not laziness.
        // The one structural difference from every rotor in this app that does
        // resolve is that these rows are wrapped in a `Group` carrying a
        // `contextMenu` and four different destinations, where the working ones
        // are a bare `NavigationLink`.
        //
        // It is gone rather than shipped, because a rotor that is present in the
        // rotor list and empty when turned to is worse for the user than one
        // that was never offered, and it is exactly the shape of claim this
        // project has been burned by before.
        .accessibilityRotor(
            Text("Screens"),
            entries: rotorScreens,
            entryID: \.self,
            entryLabel: \.title
        )
        // A term Siri was given, typed in for the user. `ShowGetHogSearchResultsIntent`
        // can only ask the app to search; this is where the asking lands.
        .onAppear {
            if let term = LinkInbox.consumeQuery(for: .search) { query = term }
        }
        .screenRefreshable { await load(force: true) }
        .task(id: model.projectID) { await load(force: false) }
        .sheet(item: $surveyRequest) { request in
            SurveySearchSheet(surveyID: request.id, name: request.name)
        }
        .navigationDestination(for: ProjectSearchPush.self) { push in
            switch push {
            case .dashboard(let id, let name):
                DashboardDetailView(dashboardID: id, title: name)
            case .insight(let shortID, _):
                // The name is not passed on: unlike a dashboard, an insight's
                // own fetch is a single request that returns the title with
                // everything else, so seeding it would only risk showing the
                // index's stale copy of a renamed insight.
                SavedInsightDetailView(identifier: shortID)
            case .featureFlag(let id, let name):
                FlagSearchDestination(flagID: id, key: name)
            }
        }
    }

    /// Names both halves where both are searched, so the field does not
    /// under-promise on the device where it is doing the most work.
    private var prompt: String {
        showsScreens ? "Search screens, names and folders" : "Search names and folders"
    }

    // MARK: - Suggestions

    /// What the field offers before anything is typed.
    ///
    /// **No search scopes, and that is a decision rather than an omission.** The
    /// obvious reading of this screen is that the screens/objects split wants
    /// `.searchScopes`, and it was measured before being rejected. Three things
    /// against it:
    ///
    /// 1. **A scope hides a half, and there are queries where both halves are
    ///    real.** Measured over the 200-row demo index against the 30 screens in
    ///    `AppTab.secondary`: four screen titles — "Insights", "Notebooks",
    ///    "Surveys", "Web" — are also matched by an object name or folder in the
    ///    same project. In a scoped field those four queries get answered with
    ///    half the truth and no sign that they had been. `SearchSuggestionTests`
    ///    pins the count and the names.
    /// 2. **And the half a scope would rescue is never buried anyway.** Each of
    ///    those four queries matches exactly *one* screen, so the object results
    ///    begin one row below the screen results — measured in the same test.
    ///    The scope bar would cost more vertical space than the rows it saves
    ///    scrolling past, and it costs it when the keyboard is up.
    /// 3. The split is already carried, permanently and for free, by the section
    ///    headers: every screen group reads "… screens" under a `macwindow`
    ///    glyph and every object group carries its own type's.
    /// 4. In regular width there is no screens half at all — the sidebar lists
    ///    them — so the control would have to be conditional on size class,
    ///    which changes the `searchable` modifier's identity across the
    ///    boundary. This app has already measured what that costs elsewhere:
    ///    state thrown away on rotation, the defect `OpenDetails` exists for.
    ///
    /// What the split *does* want is a rotor, which navigates within a half
    /// without removing the other. That is the `accessibilityRotor` above.
    @ViewBuilder
    private var suggestions: some View {
        let offered = ProjectSearchSuggestions.forQuery(
            query,
            recentTerms: recents.terms,
            entries: store.entries
        )

        if !offered.recentTerms.isEmpty {
            Section("Recent searches") {
                ForEach(offered.recentTerms, id: \.self) { term in
                    Label(term, systemImage: "clock.arrow.circlepath")
                        .searchCompletion(term)
                }
            }
        }

        if !offered.recentObjects.isEmpty {
            Section("Recently viewed") {
                ForEach(offered.recentObjects) { entry in
                    // A completion rather than a link, deliberately. A row in
                    // this list resolves to one of four different destinations —
                    // a push, a sheet this view presents itself, a browser, or
                    // nothing at all — and a suggestion that navigated would
                    // have to reproduce that routing inside a surface the search
                    // controller owns rather than this stack. Completing to the
                    // object's exact name filters 200 rows to the one row, which
                    // is then unambiguous and carries the real routing.
                    Label(entry.name, systemImage: entry.type.systemImage)
                        .searchCompletion(entry.name)
                }
            }
        }
    }

    // MARK: - Rotor entries

    /// The screen rows currently drawn, in the order `ScreenIndexSections` draws
    /// them.
    ///
    /// `AppTab.secondary` is defined as `sections.flatMap(\.tabs) + utility`,
    /// which is exactly that order, and the filter is the same
    /// case-insensitive title match. Empty in regular width, where this screen
    /// draws no screen rows at all — so the rotor is absent there rather than
    /// offering jumps to rows that were never rendered.
    private var rotorScreens: [AppTab] {
        guard showsScreens else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nav.indexedScreens }
        return nav.indexedScreens.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    // MARK: - Objects

    /// The project half, in whatever state it is actually in.
    ///
    /// Every failure here is a row rather than a replacement for the screen, for
    /// the reason in the type's own documentation: the screens above must survive
    /// a locked key and a dead network.
    @ViewBuilder
    private var objects: some View {
        if !model.isAvailable(.dashboards) {
            // The same gate the Surveys screen uses, and for the same reason: of
            // the 200 rows this index returns, insights and dashboards are 154 of
            // them, so a key without `insight:read` has almost nothing to search.
            stateRow {
                LockedCapabilityView(
                    capability: .dashboards,
                    scope: model.lockedScope(for: .dashboards)
                ) {
                    Task { await model.refreshCapabilities() }
                }
            }
        } else if let error = store.error, store.entries.isEmpty {
            stateRow {
                EmptyStateView(
                    title: "Couldn't load the project index",
                    systemImage: "exclamationmark.triangle",
                    message: error,
                    actionTitle: "Try again"
                ) {
                    Task { await load(force: true) }
                }
            }
        } else if store.entries.isEmpty && store.isLoading {
            stateRow {
                ProgressView().frame(maxWidth: .infinity)
            }
        } else if store.entries.isEmpty {
            stateRow {
                EmptyStateView(
                    title: "Nothing in this project",
                    systemImage: "tray",
                    message: "PostHog's index of this project came back empty — there are no insights, dashboards, flags or anything else in it yet."
                )
            }
        } else if query.isEmpty {
            recentSection
        } else {
            resultSections
        }
    }

    // MARK: - No query: recently viewed

    /// The default state, which costs nothing extra: `last_viewed_at` arrives on
    /// the same rows the search filters.
    ///
    /// It sits *below* the screen index on a phone deliberately. This tab is the
    /// only route to 24 destinations, and a navigation list that shifts down by a
    /// varying number of rows every time you open it is worse than a shortcut you
    /// scroll to. In regular width there is no index above it, so recents are the
    /// top of the screen — which is where they belong when nothing else competes.
    @ViewBuilder
    private var recentSection: some View {
        let recent = ProjectSearchIndex.recentlyViewed(in: store.entries)
        if recent.isEmpty {
            // With the index above it there is already something to read and
            // somewhere to go, so an empty state here would be noise.
            if !showsScreens {
                stateRow {
                    EmptyStateView(
                        title: "Nothing opened yet",
                        systemImage: "clock",
                        illustration: .workspace,
                        message: "PostHog records when you last opened an object; nothing in this project has been opened. Search above to find anything in it."
                    )
                    // Regular width hands this state most of a 13-inch pane.
                    // Without a claimed height it sat top-anchored over ~85%
                    // bare ground with the object-count footer stranded at the
                    // bottom left — measured in two sweeps as the emptiest
                    // screen in the app. Centring in a generous band makes the
                    // pane read as composed rather than abandoned.
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
        } else {
            Section {
                ForEach(recent) { row($0) }
            } header: {
                SectionLabel(text: "Recently viewed", systemImage: "clock.arrow.circlepath")
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    // Named as PostHog's record rather than the app's, because it
                    // is: GetHog has never written to this field, and a reader
                    // who opened something here yesterday should not expect to
                    // see it.
                    Text("Ordered by when PostHog last recorded you opening each one.")
                    // The grouped results explain this per group; here the types
                    // are mixed, so the pill would otherwise go unexplained.
                    if recent.contains(where: { !ProjectSearchIndex.route(for: $0).opensInApp }) {
                        Text("Rows marked “Web” have no screen in GetHog and open in the PostHog console.")
                    }
                }
            }
        }
    }

    // MARK: - Query: grouped results

    @ViewBuilder
    private var resultSections: some View {
        let groups = ProjectSearchIndex.results(in: store.entries, query: query)
        if groups.isEmpty {
            if showsScreens && ScreenIndexSections.hasMatches(query: query, loose: nav.barTabs) {
                // Screens matched and objects did not. Said plainly rather than
                // left blank, or a reader would reasonably conclude the field
                // only ever searched the app's own screens.
                Text("No object name or folder in this project matched “\(query)”.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                // Says what was actually searched. "No results" alone leaves a
                // reader unable to tell a typo from something that isn't here.
                stateRow {
                    EmptyStateView(
                        title: "No matches",
                        systemImage: "magnifyingglass",
                        message: noMatchesMessage
                    )
                }
            }
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { row($0) }
                } header: {
                    SectionLabel(text: group.type.title, systemImage: group.type.systemImage)
                } footer: {
                    if group.routesToWeb {
                        Text(ProjectSearchIndex.webFallbackNote(for: group.type))
                    }
                }
            }
        }
    }

    private var noMatchesMessage: String {
        showsScreens
            ? "No screen, and no object name or folder in this project, contains “\(query)”."
            : "No object name and no folder in this project contains “\(query)”."
    }

    /// A full-width state where a row would normally be.
    private func stateRow(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ entry: FileSystemEntry) -> some View {
        let route = ProjectSearchIndex.route(for: entry)

        Group {
            if let push = route.push(named: entry.name) {
                NavigationLink(value: push) {
                    // No accessory: a `NavigationLink` in a `List` draws its own
                    // disclosure indicator, and `DataRow`'s would sit beside it.
                    dataRow(entry, route: route, accessory: .none)
                }
            } else if case .survey(let id) = route {
                Button {
                    surveyRequest = SurveySearchRequest(id: id, name: entry.name)
                } label: {
                    dataRow(entry, route: route, accessory: .chevron)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the survey's questions")
            } else if case .web(let path) = route, let url = model.webURL(path: path) {
                Link(destination: url) {
                    // The word, not the arrow: the row leaves the app, and a
                    // reader should be able to know that without decoding a glyph.
                    dataRow(entry, route: route, accessory: .pill("Web", .secondary))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in the PostHog web console")
            } else {
                dataRow(entry, route: route, accessory: .none)
            }
        }
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
        .contextMenu {
            // Offered on the rows that open in the app, because the console is
            // where an object is edited and this app can only read. A row that
            // already links out needs no menu item repeating its own tap.
            if route.opensInApp, let url = webURL(for: entry) {
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

    private func dataRow(
        _ entry: FileSystemEntry,
        route: ProjectSearchRoute,
        accessory: RowAccessory
    ) -> some View {
        DataRow(
            glyph: entry.type.systemImage,
            // A row this app can open takes the accent; one that hands the reader
            // to a browser recedes, the way generated dashboards and PostHog's
            // own playlists do. The "Web" pill carries the same fact in words, so
            // nothing here rests on the tint alone.
            tint: route.opensInApp ? Theme.accent : .secondary,
            title: entry.name,
            // The folders are the context that separates two objects with the
            // same name, which on this endpoint is common: every product files
            // its own "Unfiled" tree.
            subtitle: entry.folderDisplayPath,
            footnote: entry.lastViewedAt.map {
                "Viewed \($0.formatted(.relative(presentation: .named)))"
            },
            accessory: accessory
        )
    }

    // MARK: - Footer

    @ViewBuilder
    private var summary: some View {
        VStack(
            alignment: showsScreens ? .leading : .center,
            spacing: Theme.Space.xs
        ) {
            if let coverage = store.coverageSummary {
                Text(coverage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            FreshnessLabel(date: store.loadedAt)
        }
        // Centred at regular width, where this footer often sits beneath a
        // centred empty state as the only other ink on the pane — left-aligned
        // there it read as orphaned debris rather than as a caption.
        .frame(maxWidth: .infinity, alignment: showsScreens ? .leading : .center)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Loading

    private func webURL(for entry: FileSystemEntry) -> URL? {
        guard let href = entry.href, !href.isEmpty else { return nil }
        return model.webURL(path: String(href.drop(while: { $0 == "/" })))
    }

    private func load(force: Bool) async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, force: force)
    }
}

// MARK: - Feature flag destination

/// The flag screen, reached from nothing but an id.
///
/// `FlagDetailView` takes a decoded `FeatureFlag` — it has to, because the
/// toggle it guards needs the flag's release conditions and variants — and the
/// index only carries the id. Resolving here is the same shape a torn-off window
/// uses in `DetachedRecordingView`, and it reuses `FlagsStore` rather than
/// fetching by hand so the deleted-flag filtering and the toggle controller are
/// the ones the Flags screen already uses.
struct FlagSearchDestination: View {
    let flagID: Int
    /// The key as the index spelled it, so the screen has a title before the
    /// flag itself has arrived. Nil when a link supplied nothing but an id,
    /// which is all a console URL carries.
    let key: String?

    @Environment(AppModel.self) private var model
    @State private var store = FlagsStore()

    private var flag: FeatureFlag? { store.flags.first { $0.id == flagID } }

    /// The flag's own key once it has loaded, so a link that started with only
    /// an id ends up titled the same as one that came from the index.
    private var title: String { flag?.key ?? key ?? "Feature flag" }

    var body: some View {
        Group {
            if let flag {
                FlagDetailView(flag: flag, controller: store.toggles)
            } else if store.isLoading {
                ProgressView().controlSize(.large)
            } else if let error = store.error {
                EmptyStateView(
                    title: "Couldn't load this flag",
                    systemImage: "exclamationmark.triangle",
                    message: error,
                    actionTitle: "Try again"
                ) {
                    Task { await load() }
                }
            } else {
                // The index and the flag list are two different reads of the same
                // project, and a flag deleted between them is a real outcome.
                EmptyStateView(
                    title: "Flag not found",
                    systemImage: "flag.slash",
                    message: key.map {
                        "“\($0)” is in this project's index but is no longer among its feature flags. It was probably deleted."
                    } ?? "Flag \(flagID) is not among this project's feature flags. It was probably deleted, or it belongs to another project."
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.projectID) { await load() }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Survey destination

/// What the sheet was asked to show. Carries the name so the sheet has a title
/// while the survey is still loading.
struct SurveySearchRequest: Identifiable, Hashable {
    let id: String
    let name: String
}

/// The survey screen, reached from an id.
///
/// A sheet rather than a push because on iOS `SurveyDetailSheet` is a sheet: it
/// brings its own `NavigationStack` and its own Done button, and pushing it
/// would draw a second navigation bar above the first — the exact cost
/// `ScreenIndexSections` documents paying on 24 screens.
///
/// **On the Mac it brings neither**, and that is the whole of the difference
/// below. `MacRootView` *pushes* that view into a stack that already has a bar,
/// so `DetailSheetContainer` gives it none — while this presentation is a real
/// sheet either way, with nothing above it to inherit chrome from. So the Mac
/// supplies the stack and the Done button here, around **both** states. Around
/// only the loaded one and the sheet would arrive with a title bar and lose it
/// the moment the survey landed; around neither and there is no way to close it.
struct SurveySearchSheet: View {
    let surveyID: String
    let name: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = SurveysStore()

    private var survey: Survey? { store.surveys.first { $0.id == surveyID } }

    var body: some View {
        Group {
            if let survey {
                sheetChrome {
                    SurveyDetailSheet(
                        survey: survey,
                        webURL: model.webURL(path: "surveys/\(survey.id)")
                    )
                }
            } else {
                // One bar in this state too: on iOS the loaded state has a
                // navigation stack of its own, so this branch supplies the only
                // other one. On the Mac neither state brings one and both get
                // theirs from `sheetChrome`, which is why this stack is the
                // iOS spelling of the same job rather than a second one.
                NavigationStack {
                    placeholder
                        .pageSurface()
                        .navigationTitle(name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .task(id: model.projectID) { await load() }
    }

    /// The chrome a *sheet* needs when the view inside it supplies none.
    ///
    /// Nothing on iOS, where `SurveyDetailSheet` still carries its own stack and
    /// Done button; the stack and the button on macOS, where it carries neither
    /// because its other host — `MacRootView` — pushes it. Written as a wrapper
    /// rather than as an `#if` around the whole `body` so the loading branch
    /// above stays one piece of code on both platforms.
    @ViewBuilder
    private func sheetChrome(@ViewBuilder _ content: () -> some View) -> some View {
        #if os(macOS)
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #else
        content()
        #endif
    }

    @ViewBuilder
    private var placeholder: some View {
        if store.isLoading {
            ProgressView().controlSize(.large)
        } else if let error = store.error {
            EmptyStateView(
                title: "Couldn't load this survey",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await load() }
            }
        } else {
            EmptyStateView(
                title: "Survey not found",
                systemImage: "text.bubble",
                message: "“\(name)” is in this project's index but is no longer among its surveys. It was probably deleted."
            )
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}
