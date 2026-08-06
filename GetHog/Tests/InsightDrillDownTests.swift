import Foundation
import GetHogKit
import GetHogUI
import Testing

@testable import GetHog

/// The gate that decides whether a chart offers a drill-down at all.
///
/// This is the whole degradation strategy: a screen that cannot drill puts
/// nothing in the environment, and every affordance is written to not exist when
/// the context is absent. So the thing worth testing is that the context refuses
/// to be built for the kinds that would fail.
@Suite("Insight drill-down availability")
struct InsightDrillDownTests {

    private func insight(
        kind: String,
        display: String? = nil,
        breakdown: String? = nil
    ) throws -> Insight {
        var source: [String: Any] = ["kind": kind, "series": []]
        if let display {
            source["trendsFilter"] = ["display": display]
        }
        if let breakdown {
            source["breakdownFilter"] = ["breakdown": breakdown, "breakdown_type": "person"]
        }
        let payload: [String: Any] = [
            "id": 1,
            "name": "Probe",
            "query": ["kind": "InsightVizNode", "source": source],
            "result": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(Insight.self, from: data)
    }

    private func context(_ insight: Insight) -> InsightDrillContext? {
        InsightDrillContext(insight: insight) { _ in }
    }

    @Test("a trends line offers a point drill")
    func trendsLine() throws {
        let ctx = try #require(context(insight(kind: "TrendsQuery", display: "ActionsLineGraph")))
        #expect(ctx.axis == .trendsPoint)
    }

    @Test("a WorldMap with a breakdown offers a breakdown drill")
    func worldMap() throws {
        // The point of routing WorldMap to the bar-value shape: its rows are
        // breakdown values, and a breakdown value resolves to people exactly.
        let ctx = try #require(context(
            insight(kind: "TrendsQuery", display: "WorldMap", breakdown: "$geoip_country_code")
        ))
        #expect(ctx.axis == .breakdown)
    }

    @Test("an aggregated display with no breakdown offers nothing")
    func aggregatedWithoutBreakdown() throws {
        // Each bar is a series rather than a breakdown value, and a series alone
        // resolves to zero people.
        #expect(context(try insight(kind: "TrendsQuery", display: "WorldMap")) == nil)
        #expect(context(try insight(kind: "TrendsQuery", display: "ActionsPie")) == nil)
    }

    @Test("funnels and lifecycle offer their own axes")
    func otherKinds() throws {
        #expect(try context(insight(kind: "FunnelsQuery"))?.axis == .funnelStep)
        #expect(try context(insight(kind: "LifecycleQuery"))?.axis == .lifecycleBand)
    }

    @Test("retention, paths, SQL and bold numbers offer nothing at all")
    func undrillable() throws {
        // Each of these is measured, not assumed — see `InsightDrilldown.axis`.
        #expect(context(try insight(kind: "RetentionQuery")) == nil)
        #expect(context(try insight(kind: "PathsQuery")) == nil)
        #expect(context(try insight(kind: "HogQLQuery")) == nil)
        #expect(context(try insight(kind: "TrendsQuery", display: "BoldNumber")) == nil)
        #expect(context(try insight(kind: "TrendsQuery", display: "CalendarHeatmap")) == nil)
        #expect(context(try insight(kind: "TrendsQuery", display: "BoxPlot")) == nil)
    }

    @Test("an insight with no saved query offers nothing")
    func noSavedQuery() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "name": "Bare"])
        let bare = try JSONDecoder().decode(Insight.self, from: data)
        #expect(context(bare) == nil)
    }

    @Test("the actor row shows a name, then an email, then a distinct id")
    func actorNaming() throws {
        let page = try ActorsPage.decode(from: Data(#"""
            {"columns":["person"],"results":[
              [{"id":"a","distinct_ids":["d1"],"properties":{"name":"Zadie Quell"}}],
              [{"id":"b","distinct_ids":["d2"],"properties":{"email":"actor.reader@example.org"}}],
              [{"id":"c","distinct_ids":["d3"],"is_unresolved":true}]
            ]}
            """#.utf8))
        #expect(page.actors.map(\.displayName) == [
            "Zadie Quell", "actor.reader@example.org", "d3",
        ])
        // Only the unresolved one has no person record to push to.
        #expect(page.actors.map(\.isUnresolved) == [false, false, true])
    }

    @Test("a resolved actor converts to the shape the people screen already takes")
    func bridgesToPersonSummary() throws {
        // The same person object `/persons/` returns, which is why the bridge is
        // a decode rather than a conversion.
        let page = try ActorsPage.decode(from: Data(#"""
            {"columns":["person"],"results":[[{
              "id":"018f4400-0000-7000-8000-000000000401",
              "created_at":"2026-01-12T09:00:00Z",
              "distinct_ids":["synthetic-person-44081","actor.reader@example.org"],
              "is_identified":true,
              "properties":{"name":"Zadie Quell","email":"actor.reader@example.org"}
            }]]}
            """#.utf8))
        let resolved = try #require(page.actors.first)
        let person = try #require(resolved.personSummary)
        #expect(person.id == resolved.id)
        #expect(person.distinctIDs == resolved.distinctIDs)
        #expect(person.isIdentified)
    }
}
