import Foundation
import Testing

@testable import GetHogKit

/// `WebStatsTableQuery` returns the breakdown value in five different JSON
/// shapes depending on the dimension, and this decoder used to keep one of them.
/// Every payload below is deliberately fictional while preserving those public
/// response shapes.
@Suite("Web stats breakdown shapes")
struct WebStatsBreakdownTests {

    private func response(_ json: String) throws -> QueryResponse {
        try QueryResponse.decode(from: Data(json.utf8))
    }

    private static let columns = """
        ["context.columns.breakdown_value", "context.columns.visitors",
         "context.columns.views", "context.columns.ui_fill_fraction",
         "context.columns.cross_sell"]
        """

    /// The unchanged case: a string dimension, and the `[current, previous]`
    /// pairs the README records.
    @Test("reads a string breakdown and takes the current half of each pair")
    func stringBreakdown() throws {
        let payload = try response("""
            {"columns": \(Self.columns),
             "results": [["/harbor", [418, null], [922, null], 0.42, ""],
                         ["/harbor/setup", [173, null], [301, null], 0.18, ""]]}
            """)
        let rows = WebStatsRow.rows(from: payload)
        #expect(rows.map(\.breakdownValue) == ["/harbor", "/harbor/setup"])
        #expect(rows[0].visitors == 418)
        #expect(rows[0].views == 922)
    }

    /// **The regression this decoder was carrying.** `Viewport`, `Region` and
    /// `City` break down by an array and `JSONValue.stringValue` is nil for one,
    /// so every row was dropped and the table said "PostHog returned no regions"
    /// about a project with five.
    @Test("keeps array-valued breakdowns instead of dropping every row")
    func arrayBreakdownsSurvive() throws {
        let viewport = try response("""
            {"columns": \(Self.columns),
             "results": [[[1440.0, 900.0], [72, null], [104, null], 0.16, ""],
                         [[390.0, 844.0], [41, null], [68, null], 0.09, ""]]}
            """)
        #expect(WebStatsRow.rows(from: viewport).count == 2)

        let region = try response("""
            {"columns": \(Self.columns),
             "results": [[["XZ", null, null], [286, null], [701, null], 0.37, ""],
                         [["XZ", "N1", "Synthetic North"], [94, null], [218, null], 0.12, ""]]}
            """)
        let rows = WebStatsRow.rows(from: region)
        #expect(rows.count == 2)
        #expect(rows[0].visitors == 286)
        #expect(rows[1].visitors == 94)
    }

    /// `Timezone` breaks down by a bare number, including fractional offsets.
    @Test("keeps a numeric breakdown")
    func numericBreakdown() throws {
        let payload = try response("""
            {"columns": \(Self.columns),
             "results": [[-3.0, [211, null], [640, null], 0.31, ""],
                         [9.5, [58, null], [133, null], 0.08, ""]]}
            """)
        let rows = WebStatsRow.rows(from: payload)
        #expect(rows.count == 2)
        #expect(rows[0].visitors == 211)
        #expect(rows[1].visitors == 58)
    }

    /// A null UTM bucket can be the largest one, so losing it hides most of the
    /// traffic and rescales every remaining proportion bar against an absent peak.
    @Test("keeps the null bucket, which is usually the biggest row")
    func nullBreakdownIsARealBucket() throws {
        let payload = try response("""
            {"columns": \(Self.columns),
             "results": [[null, [512, null], [1408, null], 0.73, ""],
                         ["fixture-campaign", [133, null], [241, null], 0.19, ""]]}
            """)
        let rows = WebStatsRow.rows(from: payload)
        #expect(rows.count == 2)
        #expect(rows[0].visitors == 512)
        // The default label leaves it empty, which `WebStatsRowView` already
        // draws as "(not set)". The app passes a dimension-aware label instead —
        // "No campaign" — because this row is *everyone who arrived without one*,
        // not a gap in the data.
        #expect(rows[0].breakdownValue.isEmpty)
        #expect(rows[1].breakdownValue == "fixture-campaign")
    }

    /// `Language` rows carry four values while `columns` advertises five —
    /// `ui_fill_fraction` is simply absent. Harmless because the two figures read
    /// are at 1 and 2 for every dimension, and pinned so it stays harmless.
    @Test("reads a row that is shorter than its own columns array")
    func shortRowStillYieldsBothFigures() throws {
        let payload = try response("""
            {"columns": \(Self.columns),
             "results": [["zz-ZZ", [377, null], [916, null], ""]]}
            """)
        let rows = WebStatsRow.rows(from: payload)
        #expect(rows.count == 1)
        #expect(rows[0].breakdownValue == "zz-ZZ")
        #expect(rows[0].visitors == 377)
        #expect(rows[0].views == 916)
    }

    @Test("a caller's label decides the text, and nothing else changes")
    func labelClosureIsRespected() throws {
        let payload = try response("""
            {"columns": \(Self.columns),
             "results": [[[1440.0, 900.0], [72, null], [104, null], 0.16, ""]]}
            """)
        let rows = WebStatsRow.rows(from: payload) { value in
            guard case .array(let parts) = value else { return "?" }
            let numbers = parts.compactMap { part -> Int? in
                guard case .number(let d) = part else { return nil }
                return Int(d)
            }
            return numbers.map(String.init).joined(separator: "x")
        }
        #expect(rows.first?.breakdownValue == "1440x900")
        #expect(rows.first?.visitors == 72)
    }

    /// A truly empty table is still empty. Nothing above should have turned
    /// "no rows" into a row.
    @Test("returns nothing for a genuinely empty result")
    func emptyStaysEmpty() throws {
        let payload = try response("""
            {"columns": \(Self.columns), "results": []}
            """)
        #expect(WebStatsRow.rows(from: payload).isEmpty)
    }
}
