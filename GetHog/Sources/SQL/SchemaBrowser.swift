import GetHogKit
import GetHogUI
import SwiftUI

/// The schema behind the SQL console: what you can select from, and what the
/// columns mean.
///
/// **Why this is worth more on a phone than at a desk.** At a desk the schema is
/// one window away, so a browser inside the console saves a keystroke. On a
/// phone there is no second window — checking whether the column is
/// `$session_id` or `session_id` means leaving the app, and coming back to an
/// editor that has kept your text but lost your place. That asymmetry is also
/// why the column list carries PostHog's prose descriptions: at a desk you would
/// have the docs open beside the query.
///
/// **Cost.** One `.query` request to open, one per table opened, both cached for
/// the life of the screen. `PostHogAPI+Schema.swift` records the measurements.
@MainActor
@Observable
final class SchemaStore {

    private(set) var tables: [SchemaTable] = []
    /// Columns by table name, filled in as tables are opened. The bounded schema
    /// response is retained for the lifetime of the screen.
    private(set) var columns: [String: [SchemaColumn]] = [:]

    var isLoadingTables = false
    /// The table whose columns are in flight, so one row can show a spinner
    /// without the list implying every row is loading.
    private(set) var loadingTable: String?
    var tablesFailure: LoadFailure?
    /// Keyed by table so a failure on one table does not label another as broken.
    private(set) var columnsFailure: [String: LoadFailure] = [:]

    /// Set when the table list may be a prefix of the project's real one.
    ///
    /// Two independent pieces of evidence, and both are needed because they
    /// cover disjoint cases.
    ///
    /// `QueryResponse.isTruncated` covers a service-applied cap. The row count
    /// also matters because a query-level limit can leave truncation metadata
    /// absent when the ceiling is reached.
    ///
    /// Counting `response.rows` rather than the decoded `tables` is deliberate
    /// for the same reason `SessionTimelineStore` was corrected to: one row that
    /// fails `SchemaTable.init(row:)` would put the decoded count under the
    /// ceiling and retire this notice, and a schema with an undecodable row is
    /// the case where the reader most needs telling that the list is partial.
    private(set) var mayBeTruncated = false

    private let tableLimit = 1000

    func loadTables(client: PostHogClient, projectID: Int) async {
        guard tables.isEmpty, !isLoadingTables else { return }
        isLoadingTables = true
        defer { isLoadingTables = false }

        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.schemaTables(projectID: projectID, limit: tableLimit)
            )
            tables = response.rows.compactMap(SchemaTable.init(row:))
            mayBeTruncated = response.isTruncated || response.rows.count >= tableLimit
            tablesFailure = nil
        } catch {
            tablesFailure = LoadFailure(error, loading: "the schema")
        }
    }

    func loadColumns(client: PostHogClient, projectID: Int, table: String) async {
        guard columns[table] == nil, loadingTable != table else { return }
        loadingTable = table
        defer { loadingTable = nil }

        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.schemaColumns(projectID: projectID, table: table)
            )
            columns[table] = response.rows.compactMap(SchemaColumn.init(row:))
            columnsFailure[table] = nil
        } catch {
            columnsFailure[table] = LoadFailure(error, loading: "columns for \(table)")
        }
    }

    /// A schema belongs to the project it was read from, so switching projects
    /// drops it rather than describing a new project with an old schema. Same
    /// reasoning as `SQLConsoleStore.clearResults`.
    func clear() {
        tables = []
        columns = [:]
        columnsFailure = [:]
        tablesFailure = nil
        mayBeTruncated = false
    }

    /// Tables grouped for display, in reading order.
    ///
    /// `.other` kinds are kept and grouped under their own raw name rather than
    /// folded into a known section — an unrecognised `table_type` should read as
    /// a category this build has not caught up with, not as a table that went
    /// missing.
    func sections(matching search: String) -> [(kind: SchemaTableKind, tables: [SchemaTable])] {
        let matches = filtered(search)
        return Dictionary(grouping: matches, by: \.kind)
            .map { (kind: $0.key, tables: $0.value.sorted { $0.name < $1.name }) }
            .sorted {
                $0.kind.sortOrder == $1.kind.sortOrder
                    ? $0.kind.title < $1.kind.title
                    : $0.kind.sortOrder < $1.kind.sortOrder
            }
    }

    /// Matches the name *and* the description.
    ///
    /// Searching descriptions is most of the value on a phone: somebody who
    /// remembers a concept rather than a table identifier can still find it.
    private func filtered(_ search: String) -> [SchemaTable] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return tables }
        return tables.filter {
            $0.name.localizedCaseInsensitiveContains(term)
                || ($0.summary?.localizedCaseInsensitiveContains(term) ?? false)
        }
    }
}

// MARK: - Statement composition

enum SchemaQueryBuilder {

    /// A complete, runnable statement for a table and a set of its columns.
    ///
    /// **This is the answer to a problem that only exists on a phone.** The
    /// console's editor is a `TextField`, which publishes no cursor position, so
    /// there is nowhere to "insert at". Rather than appending identifiers to the
    /// end of whatever is in the box — which lands them after `LIMIT 20` as
    /// often as inside a select list — the browser composes the *whole*
    /// statement. Tapping six rows is something a touch keyboard is good at;
    /// typing ``SELECT `$session_id`, `$window_id` `` is not.
    ///
    /// No selection means `*`, which is what somebody who opened a table to look
    /// at it wants.
    static func select(from table: SchemaTable, columns: [SchemaColumn]) -> String {
        let list = columns.isEmpty
            ? "*"
            : columns.map(\.hogqlIdentifier).joined(separator: ", ")
        return """
            SELECT \(list)
            FROM \(table.fromClause)
            LIMIT 100
            """
    }
}

// MARK: - Sheet

struct SchemaBrowserSheet: View {
    let store: SchemaStore
    /// Hands a composed statement back to the console.
    let onUse: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Schema")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $search,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search tables"
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = store.tablesFailure, store.tables.isEmpty {
            LoadFailureState(
                title: "Couldn't load the schema",
                failure: failure,
                retry: { Task { await load() } }
            )
        } else if store.tables.isEmpty && store.isLoadingTables {
            ProgressView("Reading the schema")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appGround()
        } else if store.tables.isEmpty {
            EmptyStateView(
                title: "No tables",
                systemImage: "tablecells",
                message: "The schema query returned nothing for this project."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            let sections = store.sections(matching: search)

            if sections.isEmpty {
                Section {
                    Text("No table name or description matches “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(sections, id: \.kind) { section in
                Section {
                    ForEach(section.tables) { table in
                        NavigationLink(value: table) {
                            SchemaTableRow(table: table)
                        }
                        .listRowBackground(rowBackground)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    SectionLabel(text: section.kind.title, systemImage: glyph(for: section.kind))
                } footer: {
                    Text(section.kind.summary)
                }
            }

            if store.mayBeTruncated {
                Section {
                    Text("This project has at least \(store.tables.count) tables and the list may be incomplete. Use the search field, or query `system.information_schema.tables` directly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationDestination(for: SchemaTable.self) { table in
            SchemaTableDetail(table: table, store: store, onUse: onUse)
        }
    }

    private var rowBackground: some View {
        Theme.cardBackground
            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            .padding(.vertical, 1)
    }

    private func glyph(for kind: SchemaTableKind) -> String {
        switch kind {
        case .posthog: "chart.bar.doc.horizontal"
        case .dataWarehouse: "externaldrive.connected.to.line.below"
        case .system: "gearshape"
        case .informationSchema: "info.circle"
        case .other: "questionmark.folder"
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadTables(client: client, projectID: projectID)
    }
}

private struct SchemaTableRow: View {
    let table: SchemaTable

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(table.name)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
            if let summary = table.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        // The name is a table identifier, not prose — the same reason `DataRow`
        // sets `zxx`. Without it, `web_pre_aggregated_bounces` acquires a soft
        // hyphen that renders as a real one, and a reader cannot tell an
        // invented hyphen in an identifier from one that was always there.
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One table

struct SchemaTableDetail: View {
    let table: SchemaTable
    let store: SchemaStore
    let onUse: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var search = ""
    /// Column names, not indices: the list is filtered by the search field, so an
    /// index means something different from one keystroke to the next.
    @State private var picked: Set<String> = []

    private var columns: [SchemaColumn] { store.columns[table.name] ?? [] }

    private var matches: [SchemaColumn] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return columns }
        return columns.filter {
            $0.name.localizedCaseInsensitiveContains(term)
                || ($0.summary?.localizedCaseInsensitiveContains(term) ?? false)
        }
    }

    /// Selection order is the table's own declaration order, so the composed
    /// select list reads like the schema rather than like the order rows were
    /// tapped in.
    private var selected: [SchemaColumn] {
        columns.filter { picked.contains($0.name) }
    }

    var body: some View {
        content
            .navigationTitle(table.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search columns"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // No `dismiss()` here. This view is *pushed* inside the
                    // sheet's own `NavigationStack`, so `dismiss` pops back to
                    // the table list rather than closing the sheet — the sheet
                    // is closed by `onUse`, which the console owns. Calling both
                    // would animate a pop underneath a dismissal.
                    Button {
                        onUse(SchemaQueryBuilder.select(from: table, columns: selected))
                    } label: {
                        Label(useTitle, systemImage: "arrow.down.doc")
                    }
                    .accessibilityLabel(useAccessibilityLabel)
                }
            }
            .task { await load() }
    }

    /// Names what the button will actually write, because the two outcomes are
    /// different queries and the difference is invisible otherwise.
    private var useTitle: String {
        selected.isEmpty ? "Query" : "Query \(selected.count)"
    }

    private var useAccessibilityLabel: String {
        selected.isEmpty
            ? "Write a query selecting every column of \(table.name)"
            : "Write a query selecting \(selected.count) chosen \(selected.count == 1 ? "column" : "columns") of \(table.name)"
    }

    @ViewBuilder
    private var content: some View {
        if let failure = store.columnsFailure[table.name], columns.isEmpty {
            LoadFailureState(
                title: "Couldn't load columns",
                failure: failure,
                retry: { Task { await load() } }
            )
        } else if columns.isEmpty && store.loadingTable == table.name {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appGround()
        } else if columns.isEmpty {
            EmptyStateView(
                title: "No columns",
                systemImage: "tablecells",
                message: "`system.information_schema.columns` returned nothing for \(table.name)."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if let summary = table.summary {
                Section {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if matches.isEmpty {
                    Text("No column name or description matches “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                ForEach(matches) { column in
                    SchemaColumnRow(
                        column: column,
                        isPicked: picked.contains(column.name),
                        toggle: { toggle(column) }
                    )
                    .listRowBackground(
                        Theme.cardBackground
                            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                            .padding(.vertical, 1)
                    )
                    .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(
                    text: "\(columns.count) \(columns.count == 1 ? "column" : "columns")",
                    systemImage: "list.bullet.rectangle"
                )
            } footer: {
                Text("Choose columns to build a SELECT, or use none for every column. Long-press a column to copy its name.")
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
    }

    /// A namespace column is not a value — selecting `person` yields a query
    /// PostHog rejects — so it cannot join a select list. The row says why
    /// rather than looking tappable and doing nothing.
    private func toggle(_ column: SchemaColumn) {
        guard !column.isNamespace else { return }
        if picked.contains(column.name) {
            picked.remove(column.name)
        } else {
            picked.insert(column.name)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadColumns(client: client, projectID: projectID, table: table.name)
    }
}

private struct SchemaColumnRow: View {
    let column: SchemaColumn
    let isPicked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                // Selection carries a glyph, not just a tint: state by colour
                // alone is unreadable to a third of the people this app is for,
                // and a filled circle against an empty one is legible without it.
                // No `.accessibilityHidden(true)` on this glyph. The row is
                // marked `.combine` below. The selection state reaches VoiceOver
                // through `accessibilityValue`, where a reader expects it.
                Image(systemName: mark)
                    .font(.body)
                    .foregroundStyle(isPicked ? Theme.accent : Color.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(column.name)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)

                    Text(typeLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    // **No line limit, deliberately**: column descriptions can
                    // contain the detail needed to select a field correctly.
                    //
                    // The description is this row's payload, not its supporting
                    // detail: it is the reason to open a schema browser on a
                    // phone at all, and unlike the table list above there is no
                    // deeper screen it can be read on. That is the same
                    // distinction `DataRow.subtitleLineLimit` exists for, where
                    // Logs is the surface whose subtitle *is* the message.
                    //
                    // Descriptions are concise enough to remain practical in the
                    // list while preserving their useful detail.
                    if let summary = column.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(column.isNamespace)
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(column.isNamespace ? [] : .isButton)
        .accessibilityValue(column.isNamespace ? "" : (isPicked ? "Chosen" : "Not chosen"))
        .contextMenu {
            Button {
                UIPasteboard.general.string = column.hogqlIdentifier
            } label: {
                Label("Copy \(column.hogqlIdentifier)", systemImage: "doc.on.doc")
            }
        }
    }

    private var mark: String {
        if column.isNamespace { return "folder" }
        return isPicked ? "checkmark.circle.fill" : "circle"
    }

    /// The type, plus only the facts that are not already the default. A line
    /// reading every default property repeatedly says nothing; exceptions are
    /// the useful information.
    private var typeLine: String {
        var parts = [column.dataType]
        if column.isArray { parts.append("array") }
        if column.isNullable { parts.append("nullable") }
        if column.isNamespace {
            parts.append("namespace — select a field inside it")
        } else if column.fieldKind != "column" {
            parts.append(column.fieldKind)
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [column.name, column.dataType]
        if let summary = column.summary { parts.append(summary) }
        return parts.joined(separator: ", ")
    }
}
