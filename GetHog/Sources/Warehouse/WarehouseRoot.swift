import GetHogKit
import SwiftUI

@MainActor
@Observable
final class WarehouseStore {
    var sources: [ExternalDataSource] = []
    var tables: [WarehouseTable] = []
    var isLoading = false

    /// The failure of each list, kept apart rather than joined into one string.
    ///
    /// They are two requests to two endpoints and either can fail alone, so a
    /// single combined `error` cannot answer the question each section has to
    /// ask before it writes anything: *did my own request answer?* Without that,
    /// a section whose request failed falls through to its empty branch and
    /// states "No external data sources." — an absence presented as a finding
    /// about a request that never returned. Measured in demo mode, where
    /// `/external_data_sources/` and `/warehouse_tables/` are both deliberately
    /// unrouted and answer 501: both sections said "No …" while the views list
    /// beside them loaded, and the screen-level notice was suppressed because
    /// the screen was no longer empty.
    var sourcesError: String?
    var tablesError: String?

    var loadedAt: Date?

    var isEmpty: Bool { sources.isEmpty && tables.isEmpty }

    /// Both requests' failures, for the state that takes the whole screen.
    var error: String? {
        let failures = [sourcesError, tablesError].compactMap { $0 }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    /// A list that failed while still holding rows from a previous success.
    ///
    /// This — and not "the screen has content" — is what makes "from an earlier
    /// load" a true sentence. A first load that fails leaves nothing behind, so
    /// there is no earlier load to attribute anything to; the failure is stated
    /// in the section it cost instead. Same distinction `HeatmapsRoot` draws
    /// with `sectionErrorNote(_:hasEarlierData:)`.
    var hasStaleRows: Bool {
        (sourcesError != nil && !sources.isEmpty) || (tablesError != nil && !tables.isEmpty)
    }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }

        // Two independent lists. A failure in either must not blank the other:
        // a sources outage should still leave the table catalog on screen, so
        // each is caught on its own and only a total failure empties the view.
        sourcesError = nil
        tablesError = nil

        do {
            let page: Page<ExternalDataSource> = try await client.send(
                Self.sourcesEndpoint(projectID: projectID)
            )
            // Trouble first: this screen exists to surface a broken sync.
            sources = page.results.sorted {
                ($0.health.severity, $0.displayName) < ($1.health.severity, $1.displayName)
            }
        } catch {
            sourcesError = Self.message(for: error)
        }

        do {
            let page: Page<WarehouseTable> = try await client.send(
                Self.tablesEndpoint(projectID: projectID)
            )
            tables = page.results.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            tablesError = Self.message(for: error)
        }

        if sourcesError == nil || tablesError == nil { loadedAt = Date() }
    }

    /// Sources whose last run failed or that have nothing left syncing.
    var unhealthySources: [ExternalDataSource] {
        sources.filter { $0.health == .failed || $0.health == .paused }
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }

    static func sourcesEndpoint(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/external_data_sources/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    static func tablesEndpoint(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/warehouse_tables/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}

/// What the warehouse screen can push.
///
/// One type rather than two selection bindings, because `List(selection:)` takes
/// exactly one and a second binding would have to be driven by a `Button`
/// instead of a `NavigationLink` — losing the row's selection highlight on iPad,
/// which is the affordance that says which row the detail column belongs to.
///
/// It also keeps the `OpenDetails` slot single-valued. That box stores an
/// `AnyHashable` per screen, so two types sharing the slot would have made
/// "which detail is open" a question of casting order rather than of one value.
enum WarehouseDetail: Hashable {
    case table(WarehouseTable)
    case view(SavedQuery)
}

struct WarehouseRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = WarehouseStore()
    @State private var views = SavedQueryStore()
    @State private var search = ""

    /// The open table or view, held in `OpenDetails` rather than pushed as a
    /// value onto the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it, and a value on
    /// the host's stack goes when the host does.
    private var selection: Binding<WarehouseDetail?> {
        Binding(
            get: { openDetails[.warehouse] as? WarehouseDetail },
            set: { openDetails[.warehouse] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        content
            .navigationTitle("Warehouse")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search sources, tables and views")
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
            .navigationDestination(item: selection) { detail in
                switch detail {
                case .table(let table): WarehouseTableDetailView(table: table)
                case .view(let view): WarehouseViewDetailView(view: view)
                }
            }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.isEmpty, views.views.isEmpty {
            // Takes the screen only when there is *nothing* to show. The views
            // list can succeed while sources and tables fail — they are three
            // requests to two different endpoint families — and an error state
            // over a list that loaded reads as a broken screen rather than as a
            // partial one. The inline notice at the foot of `list` covers that
            // case instead.
            EmptyStateView(
                title: "Couldn't load the warehouse",
                systemImage: "exclamationmark.triangle",
                message: [error, views.error].compactMap { $0 }.joined(separator: " "),
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.isEmpty && views.views.isEmpty && views.error == nil
            && !store.isLoading && !views.isLoading {
            EmptyStateView(
                title: "Nothing in the warehouse",
                systemImage: "cylinder.split.1x2",
                message: "The warehouse holds tables imported from outside PostHog — a Stripe account, a Postgres replica, files in an S3 bucket — and the views a team defines on top of them. This project has none of the three, which is where every project starts."
            )
        } else {
            list
        }
    }

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` displays it.
    private var list: some View {
        List(selection: selection) {
            if !store.unhealthySources.isEmpty && search.isEmpty {
                Section {
                    WarehouseAlertBanner(sources: store.unhealthySources)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }

            // A second banner rather than more rows inside the first. A failing
            // source and a stale view are different problems with different
            // fixes — nothing is arriving, versus old rows are being served as
            // if they were new — and merging them would leave a reader unable to
            // tell which they have. It sits below the source banner because a
            // source that stopped is usually the *cause* of the view behind it.
            if !views.stale.isEmpty && search.isEmpty {
                Section {
                    WarehouseModelingAlertBanner(views: views.stale)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }

            Section {
                if let error = store.sourcesError, store.sources.isEmpty {
                    // Said here, in the section the failed request was for, and
                    // in the same idiom the views section below has always used.
                    // The alternative — falling through to "No external data
                    // sources." — is the failure mode this project keeps
                    // producing: an absence stated as a finding when the request
                    // that would have established it never answered.
                    sectionNote("Couldn't load sources. \(error)")
                } else if filteredSources.isEmpty {
                    sectionNote(
                        store.sources.isEmpty ? "No external data sources." : "No matching sources."
                    )
                } else {
                    ForEach(filteredSources) { source in
                        WarehouseSourceRowView(source: source)
                            .warehouseRowCard()
                    }
                }
            } header: {
                SectionLabel(text: "Sources", systemImage: "arrow.down.circle")
            } footer: {
                Text("Managed imports that write into the warehouse on a schedule.")
            }

            Section {
                if let error = store.tablesError, store.tables.isEmpty {
                    sectionNote("Couldn't load tables. \(error)")
                } else if filteredTables.isEmpty {
                    sectionNote(
                        store.tables.isEmpty ? "No warehouse tables." : "No matching tables."
                    )
                } else {
                    ForEach(filteredTables) { table in
                        NavigationLink(value: WarehouseDetail.table(table)) {
                            WarehouseTableRowView(table: table)
                        }
                        .warehouseRowCard()
                    }
                }
            } header: {
                SectionLabel(text: "Tables", systemImage: "tablecells")
            }

            Section {
                if let error = views.error, views.views.isEmpty {
                    // The views list can fail on its own — a plan without data
                    // modelling still has sources and tables — so its failure is
                    // stated inside its own section rather than taking the
                    // screen. Sources and tables above now do the same.
                    sectionNote("Couldn't load views. \(error)")
                } else if filteredViews.isEmpty {
                    sectionNote(views.views.isEmpty ? "No saved views." : "No matching views.")
                } else {
                    ForEach(filteredViews) { view in
                        NavigationLink(value: WarehouseDetail.view(view)) {
                            WarehouseViewRowView(view: view)
                        }
                        .warehouseRowCard()
                    }
                }

                if views.hasMorePages {
                    // The list endpoint paginates by page number and ignores
                    // `?limit=`, so this cannot be widened away. Saying "showing
                    // the first page" is the difference between a partial answer
                    // and a wrong one.
                    Text("Showing the first page of views. PostHog reports more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(text: "Views", systemImage: "square.stack.3d.up")
            } footer: {
                // The second sentence is the honest caveat on the banner above.
                // `suspended` — PostHog having given up retrying a view after
                // repeated failures — is on the detail serializer and not on the
                // list one, so a quiet banner is not proof that nothing is
                // suspended. Saying so here costs a line and stops the absence
                // of an alarm being read as an all-clear.
                Text("Saved queries the team defined on top of these tables. A materialised view answers from a stored table, so a failed run leaves it serving old rows. A view PostHog has stopped retrying only shows that on its own screen — the list PostHog returns does not carry it.")
            }

            // The one failure case the sections above **cannot** state, and the
            // only one left for this line.
            //
            // It used to read `if let error = store.error, !store.isEmpty`, and
            // the second clause was the bug: sources and tables can both fail
            // while the views list — a different endpoint family, a third
            // request — succeeds, so the screen is not empty, so the notice was
            // suppressed, and the only things left speaking for those two
            // requests were the "No external data sources." and "No warehouse
            // tables." lines that had already stated their absence as findings.
            // Reproduced in demo mode, where both paths answer 501 by design.
            //
            // The fix is split rather than widened here, because a failure has
            // two shapes and they want different sentences. A list that failed
            // with **nothing** to show says so in its own section, next to the
            // header the failed request belongs to — repeating it down here
            // would print the same decoder message a third time. A list that
            // failed while **still holding rows** cannot say so in its section:
            // it is drawing those rows, so nothing up there is a failure state.
            // That is this line, and it is also what makes "from an earlier
            // load" a true sentence — the rows are literally from one. Same
            // distinction `HeatmapsRoot.sectionErrorNote(_:hasEarlierData:)`
            // draws, arrived at from the other end.
            if store.hasStaleRows, let error = store.error {
                Label(
                    "Part of this screen is from an earlier load. \(error)",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            }

            // The **older** of the two loads, not the newer. Three lists from
            // two stores can succeed at different moments, and a label showing
            // the most recent success would date the whole screen by its
            // freshest part — overstating exactly when one half is stale.
            FreshnessLabel(date: [store.loadedAt, views.loadedAt].compactMap { $0 }.min())
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    /// The one-line note a section writes in place of its rows.
    ///
    /// Factored out only after a third copy of the same four modifiers appeared;
    /// it carries no logic, so a caller choosing the wrong string is still the
    /// caller's mistake.
    private func sectionNote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var filteredSources: [ExternalDataSource] {
        guard !search.isEmpty else { return store.sources }
        return store.sources.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.schemas.contains { $0.name.localizedCaseInsensitiveContains(search) }
        }
    }

    private var filteredTables: [WarehouseTable] {
        guard !search.isEmpty else { return store.tables }
        return store.tables.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.hogqlName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// Filtered locally, not through the endpoint's `search` parameter.
    ///
    /// The endpoint has one, but using it would spend a request per keystroke on
    /// an organisation-wide budget to filter a list already in memory. The
    /// server-side search only earns its cost once a project has more views than
    /// one page holds, which is the case `hasMorePages` reports rather than
    /// silently papers over.
    ///
    /// `query` is deliberately not searched: it is nil for every row here — the
    /// list serializer drops it — so matching on it would find nothing and read
    /// as a broken search rather than an absent field.
    private var filteredViews: [SavedQuery] {
        guard !search.isEmpty else { return views.views }
        return views.views.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.description ?? "").localizedCaseInsensitiveContains(search)
                || ($0.folderName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// Three requests, all `.crud`, issued concurrently.
    ///
    /// The views list is a third request on a screen that already made two. It
    /// is worth the budget because it is the only one of the three that can
    /// report data being *wrong* rather than merely absent — but it is one
    /// request per screen load, not per row, and the detail requests behind it
    /// are only made for a view the reader opens.
    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        async let warehouse: Void = store.load(client: client, projectID: projectID)
        async let modeling: Void = views.load(client: client, projectID: projectID)
        _ = await (warehouse, modeling)
    }
}

// MARK: - Alert banner

/// Sync failures are the reason to open this screen on a phone, so they get
/// stated at the top in words rather than left for the reader to spot by hue.
struct WarehouseAlertBanner: View {
    let sources: [ExternalDataSource]

    private var failed: [ExternalDataSource] { sources.filter { $0.health == .failed } }
    private var paused: [ExternalDataSource] { sources.filter { $0.health == .paused } }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(headline, systemImage: failed.isEmpty ? "pause.circle" : "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(failed.isEmpty ? Theme.Ink.secondary : Theme.Status.criticalInk)

                ForEach(sources) { source in
                    Text("\(source.displayName): \(source.latestError ?? source.health.title.lowercased()) · \(source.syncSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch (failed.count, paused.count) {
        case (0, let p): "\(p) source\(p == 1 ? "" : "s") not syncing"
        case (let f, 0): "\(f) source\(f == 1 ? "" : "s") failing"
        case (let f, let p): "\(f) failing, \(p) not syncing"
        }
    }
}

// MARK: - Rows

struct WarehouseSourceRowView: View {
    let source: ExternalDataSource

    var body: some View {
        DataRow(
            glyph: "arrow.down.circle",
            // The glyph takes the health tint so a failing import is findable by
            // colour down the column; the pill beside it still carries the word.
            tint: warehouseTint(source.health),
            title: source.displayName,
            subtitle: source.syncSummary,
            footnote: runLine,
            accessory: .pill(source.health.title, warehouseTint(source.health))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var runLine: String {
        if let error = source.latestError { return error }
        if let lastRun = source.lastRunAt {
            return "Last run \(lastRun.formatted(.relative(presentation: .named)))"
        }
        return "Never run"
    }

    private var spokenSummary: String {
        var parts = ["\(source.displayName), \(source.health.title)", source.syncSummary]
        if let error = source.latestError {
            parts.append("last error: \(error)")
        } else if let lastRun = source.lastRunAt {
            parts.append("last run \(lastRun.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never run")
        }
        return parts.joined(separator: ", ")
    }
}

struct WarehouseTableRowView: View {
    let table: WarehouseTable

    var body: some View {
        DataRow(
            // Imported tables and query-built ones behave differently — only the
            // first can go stale — so they are told apart before the name is
            // read, the way the dashboard list marks generated tiles.
            //
            // The glyph carries that distinction, not the tint: the row has no
            // pill and its `provenance` line is nil whenever the API omits
            // `sourceType`, which left teal-versus-orange as the only signal —
            // invisible to anyone who cannot separate the two hues, and absent
            // from VoiceOver entirely. The tint now only reinforces it.
            glyph: table.isManaged ? "tablecells.badge.ellipsis" : "tablecells",
            tint: table.isManaged ? Theme.accent : Theme.accentWarm,
            // The table name is what a developer types into a query, so it leads
            // the row rather than sitting on a secondary line. `DataRow` sets a
            // title in the app's headline face, which carries underscores at a
            // larger size than the monospaced caption it replaces.
            title: table.name,
            subtitle: shapeLine,
            footnote: provenance,
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var shapeLine: String {
        var parts: [String] = []
        if let format = table.format { parts.append(format) }
        parts.append("\(table.columns.count) columns")
        // Absent from the list payload; "0 rows" would be a claim about an empty
        // table that the API never made.
        if let rows = table.rowCount { parts.append("\(Double(rows).compactFormatted) rows") }
        return parts.joined(separator: " · ")
    }

    private var provenance: String? {
        guard let sourceType = table.sourceType else { return nil }
        return table.schemaName.map { "From \(sourceType) · \($0)" } ?? "From \(sourceType)"
    }

    private var spokenSummary: String {
        // Stated first, because sighted users get it from the glyph before they
        // reach the name and it is the difference between a table that can go
        // stale and one that cannot.
        var parts = [table.isManaged ? "\(table.name), imported table" : "\(table.name), query-built table"]
        if let format = table.format { parts.append("format \(format)") }
        parts.append("\(table.columns.count) columns")
        // Row count is genuinely absent from this endpoint; saying "0 rows"
        // would be a claim the API never made.
        parts.append(table.rowCount.map { "\($0.formatted()) rows" } ?? "row count unknown")
        if let sourceType = table.sourceType { parts.append("from \(sourceType)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Table detail

struct WarehouseTableDetailView: View {
    let table: WarehouseTable
    @State private var search = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Name") {
                    Text(table.name).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let hogqlName = table.hogqlName, hogqlName != table.name {
                    LabeledContent("Query as") {
                        Text(hogqlName).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let format = table.format {
                    LabeledContent("Format") { Text(format) }
                }
                LabeledContent("Rows") {
                    Text(table.rowCount.map { $0.formatted() } ?? "Not reported")
                }
                if let sourceType = table.sourceType {
                    LabeledContent("Source") { Text(sourceType) }
                }
                if let schemaName = table.schemaName {
                    LabeledContent("Schema") { Text(schemaName) }
                }
                if let synced = table.lastSyncedAt {
                    LabeledContent("Last synced") {
                        Text(synced, format: .relative(presentation: .named))
                    }
                }
            } header: {
                SectionLabel(text: "Table", systemImage: "tablecells")
            }

            Section {
                if filteredColumns.isEmpty {
                    Text(table.columns.isEmpty ? "No columns reported." : "No matching columns.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredColumns) { column in
                        HStack(alignment: .firstTextBaseline) {
                            Text(column.name)
                                .font(.subheadline.monospaced())
                            Spacer(minLength: 12)
                            Text(column.type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !column.schemaValid {
                                StatusPill(text: "Invalid", tint: Theme.Status.critical)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(column.name), type \(column.type)"
                                + (column.schemaValid ? "" : ", schema invalid")
                        )
                    }
                }
            } header: {
                SectionLabel(text: "\(table.columns.count) columns", systemImage: "list.bullet")
            }
        }
        .pageSurface()
        .navigationTitle(table.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search columns")
    }

    private var filteredColumns: [WarehouseColumn] {
        guard !search.isEmpty else { return table.columns }
        return table.columns.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.type.localizedCaseInsensitiveContains(search)
        }
    }
}

// MARK: - Row chrome and formatting
//
// File-private so concurrent work on other screens can't collide with the name.

private extension View {
    /// The list treatment from the dashboards screen: every row is its own card
    /// on the page ground, with the system separator suppressed because the gap
    /// between cards already does that work.
    func warehouseRowCard() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}

/// Tint for a sync state. Always paired with the state's text, never used alone.
private func warehouseTint(_ health: SyncHealth) -> Color {
    switch health {
    case .healthy: Theme.Status.good
    case .running: Theme.accent
    case .paused: .secondary
    case .failed: Theme.Status.critical
    case .unknown: .secondary
    }
}
