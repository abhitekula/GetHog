import GetHogKit
import SwiftUI

@MainActor
@Observable
final class WarehouseStore {
    var sources: [ExternalDataSource] = []
    var tables: [WarehouseTable] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var isEmpty: Bool { sources.isEmpty && tables.isEmpty }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }

        // Two independent lists. A failure in either must not blank the other:
        // a sources outage should still leave the table catalog on screen, so
        // each is caught on its own and only a total failure empties the view.
        var failures: [String] = []

        do {
            let page: Page<ExternalDataSource> = try await client.send(
                Self.sourcesEndpoint(projectID: projectID)
            )
            // Trouble first: this screen exists to surface a broken sync.
            sources = page.results.sorted {
                ($0.health.severity, $0.displayName) < ($1.health.severity, $1.displayName)
            }
        } catch {
            failures.append(Self.message(for: error))
        }

        do {
            let page: Page<WarehouseTable> = try await client.send(
                Self.tablesEndpoint(projectID: projectID)
            )
            tables = page.results.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            failures.append(Self.message(for: error))
        }

        error = failures.isEmpty ? nil : failures.joined(separator: " ")
        if failures.count < 2 { loadedAt = Date() }
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

struct WarehouseRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = WarehouseStore()
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle("Warehouse")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search sources and tables")
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
            .navigationDestination(for: WarehouseTable.self) { table in
                WarehouseTableDetailView(table: table)
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
        } else if let error = store.error, store.isEmpty {
            EmptyStateView(
                title: "Couldn't load the warehouse",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "Nothing in the warehouse",
                systemImage: "cylinder.split.1x2",
                message: "The warehouse holds tables imported from outside PostHog — a Stripe account, a Postgres replica, files in an S3 bucket. This project has no sources connected and no tables, which is where every project starts."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !store.unhealthySources.isEmpty && search.isEmpty {
                Section {
                    WarehouseAlertBanner(sources: store.unhealthySources)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }

            Section {
                if filteredSources.isEmpty {
                    Text(store.sources.isEmpty ? "No external data sources." : "No matching sources.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
                if filteredTables.isEmpty {
                    Text(store.tables.isEmpty ? "No warehouse tables." : "No matching tables.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredTables) { table in
                        NavigationLink(value: table) {
                            WarehouseTableRowView(table: table)
                        }
                        .warehouseRowCard()
                    }
                }
            } header: {
                SectionLabel(text: "Tables", systemImage: "tablecells")
            }

            if let error = store.error, !store.isEmpty {
                Label("Part of this screen is from an earlier load. \(error)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
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

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
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
                    .foregroundStyle(failed.isEmpty ? Color.secondary : Theme.Status.critical)

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
