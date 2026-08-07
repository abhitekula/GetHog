import Foundation
import Testing

@testable import GetHogKit

/// What one fetch may cost from a small screen on a small battery.
///
/// Every assertion here is about a *bound* holding, and about the bounded
/// request being identical to the unbounded builder's output for the same
/// numbers — the budget layer forwards, it does not fork. A second copy of the
/// SQL rules or the path spellings is exactly what this file exists to prevent.
@Suite("Wrist query budget")
struct QueryBudgetTests {

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The preset

    @Test("the wrist preset is wrist-scale")
    func wristPreset() {
        // Pinned exactly rather than "small enough": these three numbers are a
        // product decision about what a watch face is allowed to spend, and a
        // silent widening is the failure mode.
        #expect(QueryBudget.wrist.hours == 24)
        #expect(QueryBudget.wrist.pageSize == 10)
        #expect(QueryBudget.wrist.maxSeries == 3)
    }

    @Test("one bound, two spellings that cannot disagree")
    func boundHasOneSource() {
        // Query nodes take a relative string, HogQL builders take a `Date`
        // floor. Both are derived from `hours`, so a budget cannot be 24h in
        // one request and 6h in the next.
        #expect(QueryBudget.wrist.dateFrom == "-24h")
        #expect(QueryBudget.wrist.since(now: Self.fixedNow)
            == Self.fixedNow.addingTimeInterval(-24 * 3_600))

        let sixHours = QueryBudget(hours: 6, pageSize: 5, maxSeries: 1)
        #expect(sixHours.dateFrom == "-6h")
        #expect(sixHours.since(now: Self.fixedNow)
            == Self.fixedNow.addingTimeInterval(-6 * 3_600))
    }

    // MARK: - Endpoint overloads

    @Test("dashboards on a budget ask for one small page")
    func dashboardsOnABudget() {
        let budgeted = PostHogAPI.dashboards(projectID: 1, budget: .wrist)
        let explicit = PostHogAPI.dashboards(projectID: 1, limit: 10)

        #expect(budgeted.path == "/api/projects/1/dashboards/")
        #expect(budgeted.category == .crud)
        #expect(budgeted.query.contains { $0.name == "limit" && $0.value == "10" })
        // Byte-identical to the builder it forwards to: the overload adds a
        // number, never a second spelling of the request.
        #expect(budgeted.query == explicit.query)
        #expect(budgeted.path == explicit.path)
    }

    @Test("feature flags on a budget ask for one small page")
    func featureFlagsOnABudget() {
        let budgeted = PostHogAPI.featureFlags(projectID: 1, budget: .wrist)
        let explicit = PostHogAPI.featureFlags(projectID: 1, limit: 10)

        #expect(budgeted.path == "/api/projects/1/feature_flags/")
        #expect(budgeted.category == .crud)
        #expect(budgeted.query.contains { $0.name == "limit" && $0.value == "10" })
        #expect(budgeted.query == explicit.query)
        #expect(budgeted.path == explicit.path)
    }

    @Test("web overview on a budget asks for the short range")
    func webOverviewOnABudget() throws {
        let endpoint = PostHogAPI.webOverview(projectID: 1, budget: .wrist)
        let body = try #require(endpoint.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try #require(json["query"] as? [String: Any])
        let range = try #require(query["dateRange"] as? [String: Any])

        #expect(query["kind"] as? String == "WebOverviewQuery")
        #expect(range["date_from"] as? String == "-24h")
    }

    // MARK: - Event lines

    @Test("recent event lines drop the properties column entirely")
    func recentEventLinesAreThin() throws {
        let endpoint = PostHogAPI.recentEventLines(
            projectID: 1, limit: 10, since: Self.fixedNow.addingTimeInterval(-86_400)
        )
        let sql = try #require(Self.decodedSQL(from: endpoint))

        // The whole point: `properties` is the bulk of an event row, and a
        // wrist feed shows a name and a time. `properties.$current_url` is out
        // for the same reason plus a second one — it is a JSON extraction over
        // every row in the scan, which is the cost the budget exists to avoid.
        #expect(!sql.contains("properties"))
        #expect(sql.contains("SELECT uuid, event, timestamp, distinct_id"))
        #expect(sql.contains("FROM events"))
    }

    @Test("recent event lines carry the same bounds the full feed does")
    func recentEventLinesAreBounded() throws {
        let floor = Self.fixedNow.addingTimeInterval(-86_400)
        let endpoint = PostHogAPI.recentEventLines(projectID: 1, limit: 10, since: floor)

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1/query/")
        #expect(endpoint.category == .query)

        let sql = try #require(Self.decodedSQL(from: endpoint))
        // The floor is not optional in the full feed's signature because an
        // unbounded `ORDER BY timestamp DESC` over `events` does not reliably
        // complete. That is a property of the table, not of the columns, so it
        // holds here identically.
        #expect(sql.contains("timestamp > toDateTime64('\(PostHogAPI.sqlTimestamp(floor))', 6)"))
        #expect(sql.contains("LIMIT 10"))
        // Tie-safe ordering, so a cursor built from the last row resumes
        // exactly where this page stopped.
        #expect(sql.contains("ORDER BY timestamp DESC, uuid DESC"))
        // Keyset paging, because PostHog rejects OFFSET for personal keys.
        #expect(!sql.uppercased().contains("OFFSET"))
    }

    @Test("event lines on a budget bound both the scan and the page")
    func recentEventLinesOnABudget() throws {
        let budgeted = PostHogAPI.recentEventLines(
            projectID: 1, budget: .wrist, now: Self.fixedNow
        )
        let explicit = PostHogAPI.recentEventLines(
            projectID: 1,
            limit: 10,
            since: Self.fixedNow.addingTimeInterval(-24 * 3_600)
        )
        // The decoded SQL rather than the JSON bytes: `hogql` serialises a
        // dictionary, whose key order is not stable between two calls, and this
        // assertion is about the query being identical rather than about
        // `JSONSerialization`'s hashing.
        #expect(Self.decodedSQL(from: budgeted) == Self.decodedSQL(from: explicit))

        let sql = try #require(Self.decodedSQL(from: budgeted))
        #expect(sql.contains("LIMIT 10"))
        #expect(sql.contains(PostHogAPI.sqlTimestamp(QueryBudget.wrist.since(now: Self.fixedNow))))
    }

    // MARK: - Trimmed insight sources

    @Test("a budgeted insight source is dated, uncompared, and capped")
    func budgetedSourceIsTrimmed() throws {
        let series: [JSONValue] = (1...5).map { .object(["event": .string("event-\($0)")]) }
        let source = JSONValue.object([
            "kind": .string("TrendsQuery"),
            "series": .array(series),
            "compareFilter": .object(["compare": .bool(true)]),
            "properties": .array([]),
            "dateRange": .object(["date_from": .string("-90d")]),
        ])

        let rebuilt = InsightRerun.source(source, budget: .wrist)
        guard case .object(let before) = source, case .object(let after) = rebuilt else {
            Issue.record("expected objects")
            return
        }

        #expect(after["dateRange"] == .object(["date_from": .string("-24h")]))
        // Removed rather than set false, exactly as the dated rerun does: a
        // compared query is two series per series, which is the opposite of a
        // budget.
        #expect(after["compareFilter"] == nil)
        #expect(after["series"] == .array(Array(series.prefix(3))))
        // The first three in saved order — not a sample, not a re-sort. The
        // user's leading series is what a wrist has room for.
        for (key, value) in before where !["dateRange", "compareFilter", "series"].contains(key) {
            #expect(after[key] == value, "\(key) was modified")
        }
    }

    @Test("a node under budget is not padded, and one with no series is left alone")
    func budgetDoesNotInvent() {
        let two: [JSONValue] = [.object(["event": .string("a")]), .object(["event": .string("b")])]
        let underBudget = InsightRerun.source(
            .object(["kind": .string("TrendsQuery"), "series": .array(two)]),
            budget: .wrist
        )
        #expect(underBudget == .object([
            "kind": .string("TrendsQuery"),
            "series": .array(two),
            "dateRange": .object(["date_from": .string("-24h")]),
        ]))

        // A HogQL node has no series axis to cap. It gains the date range the
        // existing rerun already gives it, and nothing else.
        let hogql = InsightRerun.source(
            .object(["kind": .string("HogQLQuery"), "query": .string("SELECT 1")]),
            budget: .wrist
        )
        #expect(hogql == .object([
            "kind": .string("HogQLQuery"),
            "query": .string("SELECT 1"),
            "dateRange": .object(["date_from": .string("-24h")]),
        ]))
    }

    @Test("a series key that is not an array is left exactly as found")
    func budgetLeavesAMalformedSeriesAlone() {
        // A malformed saved query should fail its own request and degrade one
        // tile, not be rewritten here into something that looks valid.
        let rebuilt = InsightRerun.source(
            .object(["kind": .string("TrendsQuery"), "series": .string("broken")]),
            budget: .wrist
        )
        #expect(rebuilt == .object([
            "kind": .string("TrendsQuery"),
            "series": .string("broken"),
            "dateRange": .object(["date_from": .string("-24h")]),
        ]))
    }

    @Test("a non-object source passes through unchanged")
    func nonObjectPassesThrough() {
        #expect(InsightRerun.source(.string("broken"), budget: .wrist) == .string("broken"))
        #expect(InsightRerun.source(.null, budget: .wrist) == .null)
    }

    // MARK: - Helpers

    private static func decodedSQL(from endpoint: Endpoint) -> String? {
        guard let body = endpoint.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let query = json["query"] as? [String: Any]
        else { return nil }
        return query["query"] as? String
    }
}
