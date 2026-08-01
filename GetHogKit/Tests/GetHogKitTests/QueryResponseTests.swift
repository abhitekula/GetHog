import Foundation
import Testing

@testable import GetHogKit

@Suite("HogQL query responses")
struct QueryResponseTests {

    @Test("decodes column-oriented results into name-addressable rows")
    func decodesRows() throws {
        let response = try QueryResponse.decode(from: Fixture.data("query_hogql.json"))

        #expect(response.columns == ["event", "timestamp", "distinct_id", "$current_url"])
        #expect(response.rows.count == 4)

        // Results arrive as positional arrays, not objects, so values must be
        // resolved against the parallel `columns` array.
        let first = response.rows[0]
        #expect(first.string("event") == "meteor_report_opened")
        #expect(first.string("distinct_id") == "person-example-meteor-201")
        #expect(first.string("$current_url") == "https://app.example.com/lab/meteor")
    }

    @Test("returns nil for a column that does not exist rather than crashing")
    func unknownColumn() throws {
        let response = try QueryResponse.decode(from: Fixture.data("query_hogql.json"))
        #expect(response.rows[0].string("no_such_column") == nil)
    }

    @Test("maps rows to typed events")
    func mapsEventRows() throws {
        let response = try QueryResponse.decode(from: Fixture.data("query_hogql.json"))
        let events = response.rows.compactMap(EventRow.init(row:))

        #expect(events.count == 4)
        #expect(events[0].event == "meteor_report_opened")
        #expect(events[0].distinctID == "person-example-meteor-201")
        #expect(events[0].timestamp != nil)
    }

    @Test("derives a keyset cursor from the oldest row in the page")
    func keysetCursor() throws {
        let response = try QueryResponse.decode(from: Fixture.data("query_hogql.json"))
        let events = response.rows.compactMap(EventRow.init(row:))

        // OFFSET pagination is rejected by PostHog for personal API keys (HTTP 400),
        // so the next page is fetched with `timestamp < cursor`.
        let cursor = try #require(response.keysetCursor(column: "timestamp"))
        let oldest = try #require(events.compactMap(\.timestamp).min())
        #expect(abs(cursor.timeIntervalSince(oldest)) < 0.001)
    }
}

// MARK: - Silent truncation

extension QueryResponseTests {

    /// PostHog caps a `LIMIT`-less HogQL query at 100 rows and says so nowhere
    /// except these two fields — HTTP 200, no error, no warning. Measured
    /// against a 141-table project, which answered with 100.
    @Test("a truncated response says so instead of looking complete")
    func truncationIsVisible() throws {
        let capped = try QueryResponse.decode(from: Data(#"""
        {"columns":["table_name"],"results":[["events"],["persons"]],
         "hasMore":true,"limit":100}
        """#.utf8))

        #expect(capped.hasMore)
        #expect(capped.isTruncated)
        #expect(capped.appliedLimit == 100)
    }

    @Test("a complete response is not reported as truncated")
    func completeIsNotTruncated() throws {
        let whole = try QueryResponse.decode(from: Data(#"""
        {"columns":["table_name"],"results":[["events"]],"hasMore":false,"limit":100}
        """#.utf8))

        #expect(whole.isTruncated == false)
        #expect(whole.appliedLimit == 100)
    }

    /// Older response shapes predate these fields, and each is still a complete
    /// answer. Absent must therefore read as "not truncated" — but the
    /// applied limit stays `nil` rather than being invented, because "PostHog
    /// did not say" and "PostHog applied no cap" are different facts.
    @Test("a response that reports neither field is read as complete")
    func absentFieldsAreComplete() throws {
        let silent = try QueryResponse.decode(from: Data(#"""
        {"columns":["event"],"results":[["$pageview"]]}
        """#.utf8))

        #expect(silent.isTruncated == false)
        #expect(silent.appliedLimit == nil)
    }
}
