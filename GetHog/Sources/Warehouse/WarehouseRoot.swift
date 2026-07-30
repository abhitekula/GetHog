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
        NavigationStack {
            content
                .navigationTitle("Warehouse")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search sources and tables")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
                .navigationDestination(for: WarehouseTable.self) { table in
                    WarehouseTableDetailView(table: table)
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
        } else if let error = store.error, store.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load the warehouse", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No warehouse data",
                systemImage: "cylinder.split.1x2",
                description: Text("This project has no external data sources or warehouse tables.")
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
                } else {
                    ForEach(filteredSources) { source in
                        WarehouseSourceRowView(source: source)
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Managed imports that write into the warehouse on a schedule.")
            }

            Section {
                if filteredTables.isEmpty {
                    Text(store.tables.isEmpty ? "No warehouse tables." : "No matching tables.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTables) { table in
                        NavigationLink(value: table) {
                            WarehouseTableRowView(table: table)
                        }
                    }
                }
            } header: {
                Text("Tables")
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(source.displayName)
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: 8)

                StatusPill(text: source.health.title, tint: warehouseTint(source.health))
            }

            Text(source.syncSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = source.latestError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.Status.critical)
                    .lineLimit(2)
            } else if let lastRun = source.lastRunAt {
                Text("Last run \(lastRun.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Never run")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
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
        VStack(alignment: .leading, spacing: 4) {
            // The table name is what a developer types into a query, so it is
            // set monospaced to keep underscores unambiguous.
            Text(table.name)
                .font(.subheadline.monospaced())
                .lineLimit(1)

            HStack(spacing: 10) {
                if let format = table.format { Text(format) }
                Text("\(table.columns.count) columns")
                if let rows = table.rowCount {
                    Text("\(Double(rows).compactFormatted) rows")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let sourceType = table.sourceType {
                Text(
                    table.schemaName.map { "From \(sourceType) · \($0)" } ?? "From \(sourceType)"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        var parts = [table.name]
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
            Section("Table") {
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
                Text("\(table.columns.count) columns")
            }
        }
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

// MARK: - Formatting
//
// File-private so concurrent work on other screens can't collide with the name.

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
