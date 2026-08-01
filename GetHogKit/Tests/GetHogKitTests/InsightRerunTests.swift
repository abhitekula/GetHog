import Foundation
import Testing

@testable import GetHogKit

/// Re-running a saved insight over a different time range.
///
/// The decoded `QuerySource` keeps only `kind` and the display type — enough to
/// choose a renderer, nowhere near enough to reconstruct the query. Rebuilding a
/// request from it would drop the series definitions, property filters and
/// breakdowns and quietly return a *different* insight's numbers under the
/// user's title. So the raw source subtree is preserved exactly and only the
/// date range is overwritten.
@Suite("Insight re-run with an overridden date range")
struct InsightRerunTests {

    private func firstSource() throws -> JSONValue {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        let insight = try #require(dashboard.tiles.compactMap(\.insight).first)
        return try #require(insight.rawSource)
    }

    @Test("keeps the whole original source, not just the decoded fields")
    func preservesRawSource() throws {
        let source = try firstSource()
        guard case .object(let fields) = source else {
            Issue.record("source was not an object")
            return
        }
        // `kind` is the only field the typed model keeps. If the raw subtree has
        // nothing beyond it, this whole mechanism is pointless.
        #expect(fields["kind"] != nil)
        #expect(fields.count > 1)
        #expect(fields["series"] != nil || fields["query"] != nil)
    }

    @Test("overrides only the date range")
    func overridesOnlyDateRange() throws {
        let source = try firstSource()
        let rebuilt = InsightRerun.source(source, dateFrom: "-90d", compare: false)

        guard case .object(let before) = source, case .object(let after) = rebuilt else {
            Issue.record("expected objects")
            return
        }
        #expect(after["dateRange"] == .object(["date_from": .string("-90d")]))
        for (key, value) in before where key != "dateRange" {
            #expect(after[key] == value, "\(key) was modified")
        }
    }

    @Test("adds a date range to a source that had none")
    func addsDateRangeWhenAbsent() {
        let source = JSONValue.object(["kind": .string("TrendsQuery")])
        let rebuilt = InsightRerun.source(source, dateFrom: "-7d", compare: false)
        #expect(rebuilt == .object([
            "kind": .string("TrendsQuery"),
            "dateRange": .object(["date_from": .string("-7d")]),
        ]))
    }

    // `compareFilter` asks PostHog for current and previous entries per series.
    @Test("asks for the previous period only when comparing")
    func compareFilter() {
        let source = JSONValue.object(["kind": .string("TrendsQuery")])

        let compared = InsightRerun.source(source, dateFrom: "-7d", compare: true)
        guard case .object(let fields) = compared else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["compareFilter"] == .object(["compare": .bool(true)]))

        let plain = InsightRerun.source(source, dateFrom: "-7d", compare: false)
        guard case .object(let plainFields) = plain else {
            Issue.record("expected an object")
            return
        }
        // Absent, not `false`: sending `compare: false` is a different request
        // from not asking to compare, and PostHog need not treat them alike.
        #expect(plainFields["compareFilter"] == nil)
    }

    @Test("leaves a non-object source alone rather than corrupting it")
    func ignoresNonObject() {
        let source = JSONValue.string("not a query")
        #expect(InsightRerun.source(source, dateFrom: "-7d", compare: false) == source)
    }
}
