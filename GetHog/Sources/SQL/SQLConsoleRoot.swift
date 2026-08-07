import GetHogKit
import GetHogUI
import SwiftUI

@MainActor
@Observable
final class SQLConsoleStore {
    var response: QueryResponse?
    /// Message from PostHog. A HogQL syntax error is ordinary usage, so it is
    /// rendered as content, never as a failure state for the whole screen.
    var error: String?
    /// Set when the read-only guard rejected a statement before it was sent.
    var blockedKeyword: String?
    var isRunning = false
    var elapsed: Duration?
    private(set) var history: [String]

    private static let defaultsKey = "gethog.sqlConsole.history"
    private static let historyLimit = 20

    /// Statements the console refuses to submit. PostHog's query API is
    /// read-only anyway, but failing here names the reason instead of returning
    /// a generic server error.
    private static let blockedKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "TRUNCATE",
    ]

    init() {
        history = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func run(client: PostHogClient, projectID: Int, sql: String) async {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let keyword = Self.blockedKeyword(in: trimmed) {
            blockedKeyword = keyword
            response = nil
            error = nil
            elapsed = nil
            return
        }

        blockedKeyword = nil
        error = nil
        isRunning = true
        defer { isRunning = false }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result: QueryResponse = try await client.send(
                PostHogAPI.hogql(projectID: projectID, sql: trimmed)
            )
            elapsed = clock.now - start
            response = result
            remember(trimmed)
        } catch {
            elapsed = clock.now - start
            response = nil
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Results belong to the project they were run against, so switching
    /// projects clears them rather than leaving them under a new project's name.
    func clearResults() {
        response = nil
        error = nil
        blockedKeyword = nil
        elapsed = nil
    }

    var elapsedSeconds: Double? {
        guard let elapsed else { return nil }
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    /// What PostHog said about this result being a prefix of the real one.
    ///
    /// `nil` when there is no result, or when PostHog said nothing — which is
    /// **not** the same as "nothing was cut". Measured and recorded in
    /// `PostHogAPI+Groups.swift`: `hasMore` and `limit` appear in a HogQL
    /// response only when PostHog applied *its own* cap. A query with no `LIMIT`
    /// came back `hasMore: false, limit: 100` over 63 rows and `hasMore: true,
    /// limit: 100` over 423; the identical query written `LIMIT 200` came back
    /// with **neither field**, holding 200 rows of 423.
    ///
    /// So this console can tell the reader one thing truthfully and not the
    /// other: when *PostHog* capped the query, say so and say at what. When the
    /// reader's own `LIMIT` capped it, the envelope is silent and so is this —
    /// claiming completeness there would be inventing a fact, and claiming
    /// truncation would be crying wolf on every `LIMIT 20` that happened to
    /// match twenty rows.
    var appliedCap: Int? {
        guard let response, response.isTruncated else { return nil }
        return response.appliedLimit
    }

    var isTruncated: Bool { response?.isTruncated ?? false }

    /// The result as a CSV somebody can take away.
    ///
    /// This screen holds the only raw `columns` + `rows` pair left in the app —
    /// every other surface decodes into structs and drops the wire shape — which
    /// is why it is also the export that needs no translation at all.
    ///
    /// **The title carries the cap when there is one**, and the title is not
    /// decoration: it is the share-sheet preview, the accessibility label of the
    /// export control, and — through `CSVExport.fileName` — the name of the file
    /// itself. A CSV is the artifact that reaches somebody who never saw this
    /// screen, so "Query result.csv" holding the first hundred rows of a hundred
    /// thousand is the one place the truncation had to survive. It does not go
    /// into the bytes: `InsightCSV.data(columns:rows:)` writes the wire's own
    /// columns and nothing else, and a prose row spliced into a machine-read
    /// table is read as data by whatever opens it.
    ///
    /// **Nothing is computed here.** This is read from a `View` body, which runs
    /// on every toolbar re-render, so even the `rows.map(\.values)` projection is
    /// deferred into the closure alongside the encoding. That map is cheap per
    /// element — the inner `[JSONValue]` arrays are copy-on-write, so it gathers
    /// one reference per row rather than copying the data — but "cheap per
    /// element" times 50,000 rows times every render is not cheap, and a result
    /// that large is exactly the case this screen has to survive.
    var export: CSVExport? {
        guard let response, !response.rows.isEmpty else { return nil }
        let title = isTruncated
            ? "Query result (first \(response.rows.count), PostHog capped)"
            : "Query result"
        return CSVExport(title: title, rowCount: response.rows.count) {
            InsightCSV.data(columns: response.columns, rows: response.rows.map(\.values))
        }
    }

    // MARK: - History

    private func remember(_ sql: String) {
        history.removeAll { $0 == sql }
        history.insert(sql, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        UserDefaults.standard.set(history, forKey: Self.defaultsKey)
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        UserDefaults.standard.set(history, forKey: Self.defaultsKey)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - Read-only guard

    /// Returns the blocked keyword a statement starts with, if any.
    ///
    /// Comments are stripped first so a leading `-- note` or `/* … */` can't
    /// disguise the first real word.
    static func blockedKeyword(in sql: String) -> String? {
        var text = sql

        while let open = text.range(of: "/*"),
              let close = text.range(of: "*/", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }

        let firstStatementLine = text
            .split(whereSeparator: \.isNewline)
            .map { line -> Substring in
                guard let marker = line.range(of: "--") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let line = firstStatementLine,
              let word = line
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" })
                  .first
        else { return nil }

        let upper = word.uppercased()
        return blockedKeywords.contains(upper) ? upper : nil
    }
}

struct SQLConsoleRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(CSVExportCoordinator.self) private var exporter: CSVExportCoordinator?
    @State private var store = SQLConsoleStore()
    @State private var schema = SchemaStore()
    @State private var sql = SQLConsoleRoot.seedQuery
    @State private var showHistory = false
    @State private var showSchema = false
    @FocusState private var editorFocused: Bool

    /// The editor is measured in **lines**, not points.
    ///
    /// It was a `@ScaledMetric(relativeTo: .callout) = 128`, and at AX5 that box
    /// fitted three lines of monospaced text and then a fourth sliced
    /// horizontally through the letter bodies — a point constant and a line box
    /// do not grow on the same curve, so no constant lands on a line boundary at
    /// every text size. A line count does, at all of them.
    ///
    /// Three lines at accessibility sizes rather than five: five AX5 lines are
    /// most of a phone, and the results this console exists to show have to keep
    /// somewhere to appear.
    private var editorLines: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 5
    }

    /// A harmless, universally valid starting point: it answers "what is this
    /// project even sending?" without the user having to know a schema.
    static let seedQuery = """
        SELECT event, count()
        FROM events
        GROUP BY event
        ORDER BY count() DESC
        LIMIT 20
        """

    var body: some View {
        Group {
            if model.isAvailable(.events) {
                console
            } else {
                LockedCapabilityView(
                    capability: .events,
                    scope: model.lockedScope(for: .events)
                ) {
                    Task { await model.refreshCapabilities() }
                }
            }
        }
        .navigationTitle("SQL")
        // Was `.inline` at every width, which made this the one root in the app
        // whose title was centred and small while its neighbours carried a large
        // title over the project name. `.projectSubtitle()` decides the mode —
        // large on iPhone, inline on iPad where the tab bar already names the
        // section — so SQL now matches every screen either side of it. There was
        // no layout reason for the exception: the editor sits below the bar and
        // is unaffected by the title's height.
        .projectSubtitle()
        .toolbar {
            ProjectSwitcher()
            // The schema comes before history in the bar because it is the one
            // you need *before* you have written anything, and history is the
            // one you need after.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSchema = true
                } label: {
                    Label("Schema", systemImage: "tablecells.badge.ellipsis")
                }
                .accessibilityLabel("Browse tables and columns")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHistory = true
                } label: {
                    Label("Query history", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Query history")
                .disabled(store.history.isEmpty)
            }
            if let export = store.export {
                ToolbarItem(placement: .topBarTrailing) {
                    CSVShareMenu(export: export)
                }
            }
            // The accessory bar above the software keyboard, so a multi-line
            // editor has a way to give focus back. `.keyboard` is unavailable
            // on visionOS — the virtual keyboard there is a window of its own
            // with its own dismissal, and there is no bar to attach to.
            #if !os(visionOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editorFocused = false }
            }
            #endif
        }
        // The console's result table behind File ▸ Export CSV and Edit ▸ Copy
        // CSV — the most obviously exportable table in the app, and the one a
        // greyed-out Export item would read as broken on.
        .focusedSceneValue(
            \.insightCSVExport,
            InsightCSVExportAction.routing(store.export, through: exporter)
        )
        .onChange(of: model.projectID) { _, _ in
            store.clearResults()
            // The schema describes the project it was read from. Same reasoning
            // as `clearResults` — a table list from the previous project under
            // this project's name is a wrong answer, not a stale one.
            schema.clear()
        }
        .sheet(isPresented: $showHistory) {
            SQLHistorySheet(store: store) { recalled in
                sql = recalled
                showHistory = false
            }
        }
        .sheet(isPresented: $showSchema) {
            SchemaBrowserSheet(store: schema) { statement in
                sql = statement
                showSchema = false
                // Not run automatically. The statement it composed is a
                // `SELECT * … LIMIT 100` against a table whose size is unknown,
                // and spending an organisation-wide query budget on something
                // the reader has not read yet is exactly the reflex this app
                // avoids everywhere else.
            }
        }
    }

    // The page itself is a fixed VStack — nothing here scrolls sideways except
    // the results table, which owns its own horizontal scroll view. What it
    // does now do is scroll *down*: the editor is a fixed five lines plus a
    // button row, which on an iPhone in landscape leaves the results region
    // shorter than the states it has to hold. See `scrollingIfNeeded`.
    private var console: some View {
        VStack(spacing: 0) {
            editor
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageSurface()
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A vertical-axis `TextField` rather than a `TextEditor`: it is the
            // only multi-line input SwiftUI will size in whole lines, which is
            // what stops the box cutting through a glyph. It still takes a
            // Return, still scrolls past the reserved lines, and reads the same.
            TextField("HogQL query", text: $sql, axis: .vertical)
                .font(.callout)
                .monospaced()
                .lineLimit(editorLines, reservesSpace: true)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($editorFocused)
                .padding(Theme.Space.s)
                .background(Theme.cardBackground, in: .rect(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityLabel("HogQL query")

            HStack(spacing: 12) {
                Button {
                    Task { await run() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                // See `Theme.inkOnAccent`: a prominent button's default white
                // label is 2.09:1 on the dark accent. Ordered above `.disabled`
                // to match the three onboarding buttons, which is the only
                // reason for the order — what an explicit `foregroundStyle`
                // does to the *disabled* rendering has not been measured here,
                // and WCAG exempts an inactive control from the text floor
                // either way.
                .foregroundStyle(Theme.inkOnAccent)
                .disabled(store.isRunning || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if store.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Running query")
                }

                Spacer()

                Text(statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
    }

    /// Row count, elapsed time, and — when PostHog capped the result — that it
    /// did.
    ///
    /// This line read "\(n) rows" unconditionally, on the one screen in the app
    /// where the *reader* writes the query and is therefore most likely to omit
    /// a `LIMIT`. `SELECT * FROM events` was answered "100 rows", which is not a
    /// partial answer but a wrong one: the number is the cap, and nothing on the
    /// screen said so. See `SQLConsoleStore.appliedCap` for why the console can
    /// state this when PostHog capped the query and must stay silent when the
    /// reader's own `LIMIT` did.
    private var statusText: String {
        if store.isRunning { return "Running…" }
        guard let response = store.response else { return "" }
        let rows = response.rows.count == 1 ? "1 row" : "\(response.rows.count) rows"
        // "capped" and not "of more": the envelope says a cap was applied and
        // that rows were withheld, never how many there were.
        let counted = store.isTruncated ? "\(rows) · capped" : rows
        guard let seconds = store.elapsedSeconds else { return counted }
        return "\(counted) · \(seconds.formatted(.number.precision(.fractionLength(2))))s"
    }

    /// The full sentence, under the results, whenever PostHog held rows back.
    ///
    /// The status line has one line and shares it with a timing, so it can only
    /// carry the word; this carries what to do about it. **It says "add a
    /// `LIMIT`" rather than offering to re-run**, and that was a decision rather
    /// than an omission:
    ///
    /// - A re-run costs a second `.query` request against a budget that is
    ///   organisation-wide and shared with whatever else the reader has
    ///   integrated. This app declines to spend that on the reader's behalf
    ///   everywhere else it comes up — the schema browser composes a statement
    ///   and deliberately does not run it, for exactly this reason.
    /// - Re-running means editing the reader's SQL, and there is no safe edit.
    ///   Appending `LIMIT 1000` to arbitrary HogQL lands after a trailing `--`
    ///   comment, after an existing `LIMIT`, or inside a subquery's tail; the
    ///   console's `TextField` publishes no cursor position, which is the same
    ///   constraint that made `SchemaQueryBuilder` compose whole statements
    ///   rather than insert fragments.
    /// - The remedy is one word of typing in a box the reader is already in, and
    ///   it leaves the query theirs. Naming the cap is what they could not get
    ///   anywhere else — PostHog returned HTTP 200 with no warning in it.
    @ViewBuilder
    private var truncationNote: some View {
        if store.isTruncated {
            Label {
                Text(
                    store.appliedCap.map {
                        "PostHog capped this at \($0) rows and there are more. A query with no LIMIT of its own is capped silently — add one to read further."
                    }
                        ?? "PostHog held rows back from this result. A query with no LIMIT of its own is capped silently — add one to read further."
                )
            } icon: {
                Image(systemName: "scissors")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground)
        }
    }

    @ViewBuilder
    private var results: some View {
        if let keyword = store.blockedKeyword {
            noticeCard(
                title: "\(keyword) statements are blocked",
                systemImage: "hand.raised",
                // Not a crash and not a bug — the console only reads.
                detail: "This console only runs read queries. PostHog's query API is read-only too, so a \(keyword) would be rejected server-side; refusing it here just says so sooner. Start the statement with SELECT.",
                // Warm rather than red: the statement was refused, but nothing
                // went wrong.
                accent: Theme.accentWarm
            )
        } else if let error = store.error {
            noticeCard(
                title: "Query failed",
                systemImage: "exclamationmark.triangle",
                detail: error,
                accent: Theme.Status.critical,
                monospacedDetail: true
            )
        } else if let response = store.response {
            if response.rows.isEmpty {
                scrollingIfNeeded(
                    EmptyStateView(
                        title: "No rows",
                        systemImage: "tablecells",
                        message: "The query ran successfully and matched nothing."
                    )
                )
            } else {
                // The note sits **below** the grid rather than above it: the
                // grid owns a vertical scroll view, so a note above it would be
                // the thing that scrolls away, and this is the one fact about
                // the result that must still be true after the reader has
                // scrolled to the last row — which is precisely where a capped
                // result stops looking capped.
                VStack(spacing: 0) {
                    QueryResultsTable(response: response)
                    truncationNote
                }
            }
        } else {
            scrollingIfNeeded(
                EmptyStateView(
                    title: "Run a query",
                    systemImage: "terminal",
                    // No backticks: `EmptyStateView` renders plain text, and
                    // unrendered markdown reads as a typo, not as code.
                    message: "Results appear here. HogQL reads like ClickHouse SQL over your events, persons and sessions tables."
                )
            )
        }
    }

    /// Centres its content when the region is tall enough and lets it scroll
    /// when it isn't.
    ///
    /// `ContentUnavailableView` centres itself in whatever height it is handed
    /// and overflows in *both* directions when that is too little. On an iPhone
    /// in landscape the results region is about a third of a portrait one, and
    /// the "Run a query" state lost its glyph off the top and its closing words
    /// — "`sessions` tables." — under the floating tab bar at the same time,
    /// with nothing to scroll because the page was a plain stack. A bare
    /// `ScrollView` would reach the text and give up the centring that makes the
    /// state look deliberate in portrait; the container-height floor keeps both,
    /// and `.basedOnSize` stops a state that already fits from bouncing.
    private func scrollingIfNeeded(_ content: some View) -> some View {
        GeometryReader { proxy in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Not an `EmptyStateView`: both notices carry a message that has to stay
    /// selectable and, for a HogQL error, monospaced — a syntax error is
    /// something you copy back into the editor, not something you read past.
    private func noticeCard(
        title: String,
        systemImage: String,
        detail: String,
        accent: Color,
        monospacedDetail: Bool = false
    ) -> some View {
        ScrollView {
            Card(accent: accent) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Text(detail)
                        .font(monospacedDetail ? .caption.monospaced() : .callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func run() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        editorFocused = false
        await store.run(client: client, projectID: projectID, sql: sql)
    }
}

// MARK: - Results table

/// A column-oriented result grid.
///
/// Query results are arbitrarily wide, so the grid — and only the grid — scrolls
/// horizontally inside its own container. The surrounding page never moves
/// sideways.
struct QueryResultsTable: View {
    let response: QueryResponse

    /// Character counts, measured once at init. Multiplying by a scaled
    /// character width at layout time keeps columns legible under Dynamic Type
    /// without re-scanning rows on every pass.
    private let widestCell: [Int]

    @ScaledMetric(relativeTo: .caption) private var characterWidth: CGFloat = 7.5

    init(response: QueryResponse) {
        self.response = response
        // Sampling the head is enough to size columns; scanning every row of a
        // large result to pick a width is not worth the time.
        let sample = response.rows.prefix(60)
        widestCell = response.columns.enumerated().map { index, name in
            var longest = name.count
            for row in sample where index < row.values.count {
                longest = max(longest, Self.display(row.values[index]).count)
            }
            return longest
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(response.rows.enumerated()), id: \.offset) { index, row in
                        cells(for: row)
                            .background(index.isMultiple(of: 2) ? Color.clear : Theme.cardBackground.opacity(0.6))
                        Divider()
                    }
                } header: {
                    headerRow
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(response.columns.enumerated()), id: \.offset) { index, column in
                Text(column)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: width(at: index), alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
            }
        }
        // Opaque, otherwise pinned header text overlaps the rows sliding under it.
        .background(Theme.cardBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func cells(for row: QueryRow) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(response.columns.enumerated()), id: \.offset) { index, column in
                let text = index < row.values.count ? Self.display(row.values[index]) : ""
                Text(text)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: width(at: index), alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 6)
                    .textSelection(.enabled)
                    .accessibilityLabel("\(column): \(text.isEmpty ? "empty" : text)")
            }
        }
    }

    private func width(at index: Int) -> CGFloat {
        let characters = index < widestCell.count ? widestCell[index] : 12
        return min(max(CGFloat(characters) * characterWidth + 16, 76), 300)
    }

    private static func display(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): String(b)
        case .string(let s): s
        case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
        case .array(let a): a.isEmpty ? "[]" : "[\(a.count)]"
        case .object(let o): o.isEmpty ? "{}" : "{\(o.count)}"
        }
    }
}

// MARK: - History

struct SQLHistorySheet: View {
    let store: SQLConsoleStore
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty {
                    EmptyStateView(
                        title: "No history yet",
                        systemImage: "clock",
                        message: "Queries that run successfully are kept here."
                    )
                } else {
                    List {
                        Section {
                            // Deliberately not a `DataRow`: the whole row is SQL,
                            // and a row type that can only monospace its second
                            // line would set the statement in prose type.
                            ForEach(Array(store.history.enumerated()), id: \.offset) { _, query in
                                Button {
                                    onSelect(query)
                                } label: {
                                    Text(query)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    Theme.cardBackground
                                        .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                        .padding(.vertical, 1)
                                )
                                .listRowSeparator(.hidden)
                            }
                            .onDelete { store.removeHistory(at: $0) }
                        } header: {
                            SectionLabel(text: "Recent queries", systemImage: "clock.arrow.circlepath")
                        } footer: {
                            Text("The last 20 successful queries, kept on this device only.")
                        }
                    }
                    .listRowSpacing(Theme.Space.xs)
                    .pageSurface()
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear", role: .destructive) { store.clearHistory() }
                        .disabled(store.history.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
