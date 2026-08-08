import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// Export for the screens that had none, and the statement the schema browser
/// composes.
///
/// Both are pure and neither is visible in a screenshot: a CSV is judged by what
/// a spreadsheet reads back, and a composed statement by whether PostHog will
/// run it.
@Suite("Table export")
struct TableExportTests {

    /// Parses back what a spreadsheet would see: BOM stripped, records split.
    private func records(_ data: Data) -> [String] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.components(separatedBy: "\r\n")
    }

    // MARK: - The query shape, which is the same everywhere

    @Test("writes the column list as the header, then one record per row")
    func queryShape() {
        let export = CSVExport.query(
            title: "Query result",
            columns: ["event", "count"],
            rows: [[.string("$pageview"), .number(3)], [.string("$autocapture"), .number(9)]]
        )
        #expect(export.rowCount == 2)
        #expect(records(export.data()) == ["event,count", "$pageview,3", "$autocapture,9"])
    }

    /// The reason a `/query/` export goes through `JSONValue` rather than being
    /// re-derived from decoded structs: `properties` is often the column somebody
    /// opened the console for, and it is the one a naive flattening drops.
    @Test("serialises a nested properties cell instead of emptying it")
    func nestedCell() {
        let export = CSVExport.query(
            title: "t",
            columns: ["properties"],
            rows: [[.object(["$browser": .string("Safari")])]]
        )
        #expect(records(export.data()).last == #""{""$browser"":""Safari""}""#)
    }

    @Test("counts rows without encoding, so a menu costs nothing to draw")
    func rowCountIsCheap() {
        // 20,000 rows: if `rowCount` encoded, this test would be visibly slow.
        let rows = (0..<20_000).map { [JSONValue.number(Double($0))] }
        let export = CSVExport.query(title: "t", columns: ["n"], rows: rows)
        #expect(export.rowCount == 20_000)
        #expect(!export.isEmpty)
    }

    @Test("reports an empty result as having nothing to export")
    func emptyResult() {
        #expect(CSVExport.query(title: "t", columns: ["a"], rows: []).isEmpty)
    }

    /// `.table` is given the header row inline, so its row count must exclude it
    /// — otherwise every menu overstates a table by one.
    @Test("does not count the header row as data")
    func tableRowCount() {
        let export = CSVExport.table(title: "t", rows: [["Label", "Value"], ["a", "1"]])
        #expect(export.rowCount == 1)
        #expect(CSVExport.table(title: "t", rows: [["Label", "Value"]]).isEmpty)
    }

    /// A title becomes a filename, and `/` is a path separator on every system
    /// this export can reach.
    @Test("sanitises a title into a usable filename")
    func fileName() {
        #expect(CSVExport.query(title: "Signups / week", columns: [], rows: []).fileName
            == "Signups - week.csv")
    }

    // MARK: - The SQL console

    @Test("offers no export until a query has returned rows")
    @MainActor
    func consoleWithoutResults() {
        #expect(SQLConsoleStore().export == nil)
    }

    /// The console holds the only raw `columns` + `rows` pair left in the app, so
    /// its export is the wire shape with nothing in between.
    @Test("exports a console result exactly as the API returned it")
    @MainActor
    func consoleExport() throws {
        let store = SQLConsoleStore()
        let json = """
            {"columns":["event","count"],"results":[["$pageview",3],["$autocapture",9]]}
            """
        store.response = try QueryResponse.decode(from: Data(json.utf8))

        let export = try #require(store.export)
        #expect(export.rowCount == 2)
        #expect(records(export.data()) == ["event,count", "$pageview,3", "$autocapture,9"])
    }

    // MARK: - Insights still work the same way

    /// The insight path was rerouted through `CSVExport`; the bytes must not have
    /// moved. `InsightCSVTests` pins the encoder, this pins the reroute.
    @Test("an insight exports the same bytes through the shared path")
    func insightUnchanged() throws {
        let model = InsightRenderModel.bigNumber(BigNumber(label: "Users", value: 1234))
        let export = try #require(ExportableInsight(title: "Users", model: model).csvExport)
        let direct = try #require(InsightCSV.encode(model))
        #expect(String(decoding: export.data(), as: UTF8.self) == direct)
    }

    @Test("an undecodable insight still has nothing to export")
    func unsupportedInsight() {
        let insight = ExportableInsight(title: "x", model: .unsupported(kind: "FutureInsightKind"))
        #expect(insight.csvExport == nil)
    }
}

@Suite("Schema query builder")
struct SchemaQueryBuilderTests {

    private let events = SchemaTable(name: "events", kind: .posthog, summary: nil)

    private func column(_ name: String) -> SchemaColumn {
        SchemaColumn(name: name, dataType: "String")
    }

    /// No selection means the reader opened a table to look at it, and `*` is
    /// what that asks for.
    @Test("selects every column when none was chosen")
    func selectAll() {
        #expect(
            SchemaQueryBuilder.select(from: events, columns: []) == """
                SELECT *
                FROM events
                LIMIT 100
                """
        )
    }

    /// The whole point of composing a statement rather than appending to the
    /// editor: a name needing backticks is one nobody can type on a phone.
    @Test("quotes a dollar-prefixed column in the select list")
    func quotesChosenColumns() {
        let statement = SchemaQueryBuilder.select(
            from: events,
            columns: [column("event"), column("$session_id")]
        )
        #expect(statement.hasPrefix("SELECT event, `$session_id`\n"))
    }

    /// The authored warehouse contract treats all three spellings of a dotted
    /// table as the same resource, so the plain name is used.
    @Test("writes a dotted warehouse table name unquoted")
    func warehouseTable() {
        let table = SchemaTable(name: "github.issues", kind: .dataWarehouse, summary: nil)
        #expect(
            SchemaQueryBuilder.select(from: table, columns: []).contains("FROM github.issues")
        )
    }

    /// Every composed statement is bounded. The console's own guard blocks
    /// writes; nothing else stops a `SELECT *` over `events`.
    @Test("always bounds the composed statement")
    func alwaysBounded() {
        #expect(SchemaQueryBuilder.select(from: events, columns: []).hasSuffix("LIMIT 100"))
        #expect(
            SchemaQueryBuilder.select(from: events, columns: [column("uuid")])
                .hasSuffix("LIMIT 100")
        )
    }

    /// A composed statement must survive the console's own read-only guard —
    /// otherwise the browser could write a query the Run button refuses.
    @Test("composes a statement the console's read-only guard accepts")
    @MainActor
    func passesReadOnlyGuard() {
        let statement = SchemaQueryBuilder.select(from: events, columns: [column("uuid")])
        #expect(SQLConsoleStore.blockedKeyword(in: statement) == nil)
    }
}
