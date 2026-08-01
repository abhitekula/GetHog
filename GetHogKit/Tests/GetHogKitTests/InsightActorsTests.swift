import Foundation
import Testing

@testable import GetHogKit

/// Drilling from a chart to the people behind it.
///
/// Request expectations follow the API's validation contract and use synthetic
/// data throughout.
@Suite("Insight actors drill-down")
struct InsightActorsTests {

    private var trendsSource: JSONValue {
        .object([
            "kind": .string("TrendsQuery"),
            "dateRange": .object(["date_from": .string("-7d")]),
            "series": .array([.object([
                "kind": .string("EventsNode"),
                "event": .string("$pageview"),
                "math": .string("dau"),
            ])]),
        ])
    }

    private func inner(_ query: JSONValue?) throws -> [String: JSONValue] {
        let query = try #require(query)
        guard case .object(let outer) = query,
              case .object(let source)? = outer["source"]
        else {
            Issue.record("expected ActorsQuery.source to be an object")
            return [:]
        }
        return source
    }

    // MARK: - Node selection

    @Test("wraps the drill in an ActorsQuery with paging")
    func wrapsInActorsQuery() throws {
        let query = try #require(InsightActors.query(
            source: trendsSource,
            drill: InsightDrill(
                kind: .trendsPoint(series: 0, day: "2026-01-11"),
                title: "28 Jul", expectedCount: 19
            ),
            limit: 100, offset: 200
        ))
        guard case .object(let outer) = query else {
            Issue.record("expected an object"); return
        }
        #expect(outer["kind"] == .string("ActorsQuery"))
        #expect(outer["limit"] == .number(100))
        #expect(outer["offset"] == .number(200))
    }

    @Test("a trends point selects InsightActorsQuery with series and day")
    func trendsPointNode() throws {
        let fields = try inner(InsightActors.query(
            source: trendsSource,
            drill: InsightDrill(
                kind: .trendsPoint(series: 2, day: "2026-01-11"),
                title: "28 Jul", expectedCount: 19
            )
        ))
        #expect(fields["kind"] == .string("InsightActorsQuery"))
        #expect(fields["series"] == .number(2))
        #expect(fields["day"] == .string("2026-01-11"))
        // A trends drill requires both the series and day dimensions.
        #expect(fields["day"] != nil)
    }

    @Test("a breakdown value selects InsightActorsQuery with breakdown")
    func breakdownNode() throws {
        let fields = try inner(InsightActors.query(
            source: trendsSource,
            drill: InsightDrill(
                kind: .breakdown(series: 0, value: "US"),
                title: "US", expectedCount: 35
            )
        ))
        #expect(fields["kind"] == .string("InsightActorsQuery"))
        #expect(fields["breakdown"] == .string("US"))
        #expect(fields["series"] == .number(0))
    }

    @Test("the null-breakdown sentinel is sent exactly, not as its display text")
    func breakdownSentinelIsRaw() throws {
        let fields = try inner(InsightActors.query(
            source: trendsSource,
            drill: InsightDrill(
                kind: .breakdown(series: 0, value: BreakdownLabel.nullSentinel),
                title: "(no value)", expectedCount: 537
            )
        ))
        #expect(fields["breakdown"] == .string("$$_posthog_breakdown_null_$$"))
    }

    @Test("a lifecycle band selects InsightActorsQuery with status and day")
    func lifecycleNode() throws {
        let fields = try inner(InsightActors.query(
            source: trendsSource,
            drill: InsightDrill(
                kind: .lifecycleBand(status: "dormant", day: "2026-01-09"),
                title: "26 Jul · Dormant", expectedCount: 3
            )
        ))
        #expect(fields["kind"] == .string("InsightActorsQuery"))
        #expect(fields["status"] == .string("dormant"))
        #expect(fields["day"] == .string("2026-01-09"))
    }

    @Test("a stickiness bucket selects StickinessActorsQuery, not InsightActorsQuery")
    func stickinessNode() throws {
        // `series` and `day` exist on both nodes, but a stickiness source under
        // an `InsightActorsQuery` is a different query. The dedicated node is
        // the one whose `day` means "was active on exactly n intervals".
        let fields = try inner(InsightActors.query(
            source: trendsSource,
            drill: InsightDrill(
                kind: .stickinessBucket(series: 0, intervals: 2),
                title: "2 days", expectedCount: 10
            )
        ))
        #expect(fields["kind"] == .string("StickinessActorsQuery"))
        #expect(fields["series"] == .number(0))
        #expect(fields["day"] == .number(2))
    }

    // MARK: - Funnel steps

    @Test("a funnel step is 1-based and positive when it means converted")
    func funnelConverted() throws {
        // Converted steps use the API's positive, 1-based representation.
        for (index, expected) in [(0, 1.0), (1, 2.0), (2, 3.0)] {
            let fields = try inner(InsightActors.query(
                source: trendsSource,
                drill: InsightDrill(
                    kind: .funnelStep(step: index, outcome: .converted),
                    title: "step", expectedCount: 0
                )
            ))
            #expect(fields["kind"] == .string("FunnelsActorsQuery"))
            #expect(fields["funnelStep"] == .number(expected))
        }
    }

    @Test("a funnel drop-off is the negated 1-based step")
    func funnelDroppedOff() throws {
        // The encoded step is the negated 1-based index.
        for (index, expected) in [(1, -2.0), (2, -3.0)] {
            let fields = try inner(InsightActors.query(
                source: trendsSource,
                drill: InsightDrill(
                    kind: .funnelStep(step: index, outcome: .droppedOff),
                    title: "step", expectedCount: 0
                )
            ))
            #expect(fields["funnelStep"] == .number(expected))
        }
    }

    @Test("no query is built for a drop-off from the first step")
    func firstStepHasNoDropOff() {
        // `funnelStep: -1` is not empty, it is HTTP 500 — PostHog does not
        // defend against being asked who dropped off before step one, and a 500
        // is indistinguishable from the service being down.
        let query = InsightActors.query(
            source: trendsSource,
            drill: InsightDrill(
                kind: .funnelStep(step: 0, outcome: .droppedOff),
                title: "step", expectedCount: 0
            )
        )
        #expect(query == nil)
    }

    @Test("the drop-off drill refuses to exist for the first step")
    func dropOffFactoryRefusesFirstStep() {
        let first = FunnelStep(name: "Signed up", count: 14, order: 0, averageConversionTime: nil)
        let second = FunnelStep(name: "Onboarded", count: 13, order: 1, averageConversionTime: nil)

        #expect(InsightDrill.funnelDropOff(step: first, index: 0, previous: nil) == nil)

        let drop = InsightDrill.funnelDropOff(step: second, index: 1, previous: first)
        #expect(drop?.expectedCount == 1)
        #expect(drop?.kind == .funnelStep(step: 1, outcome: .droppedOff))
    }

    @Test("a converted drill carries the step's own count")
    func convertedCarriesCount() {
        let step = FunnelStep(name: "Onboarded", count: 13, order: 1, averageConversionTime: nil)
        let drill = InsightDrill.funnelConverted(step: step, index: 1)
        #expect(drill.expectedCount == 13)
        #expect(drill.title == "Onboarded")
    }

    // MARK: - The saved query is passed through untouched

    @Test("keeps the whole saved source exactly")
    func preservesSource() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        let insight = try #require(dashboard.tiles.compactMap(\.insight).first)
        let source = try #require(insight.rawSource)

        let fields = try inner(InsightActors.query(
            source: source,
            drill: InsightDrill(
                kind: .trendsPoint(series: 0, day: "2026-01-11"),
                title: "28 Jul", expectedCount: 1
            )
        ))
        // Rebuilding the query from the decoded model would drop the series
        // definitions, property filters and breakdown, and return a different
        // population than the chart drew.
        #expect(fields["source"] == source)
    }

    @Test("refuses a source that is not an object")
    func refusesMalformedSource() {
        for source in [JSONValue.null, .string("TrendsQuery"), .array([])] {
            #expect(InsightActors.query(
                source: source,
                drill: InsightDrill(
                    kind: .trendsPoint(series: 0, day: "2026-01-11"),
                    title: "", expectedCount: 0
                )
            ) == nil)
        }
    }

    // MARK: - The endpoint

    @Test("posts to the query endpoint on the query budget")
    func endpointShape() throws {
        let endpoint = try #require(PostHogAPI.insightActors(
            projectID: 1_001,
            source: trendsSource,
            drill: InsightDrill(
                kind: .trendsPoint(series: 0, day: "2026-01-11"),
                title: "", expectedCount: 0
            )
        ))
        #expect(endpoint.path == "/api/projects/1001/query/")
        #expect(endpoint.method == "POST")
        #expect(endpoint.category == .query)
        #expect(endpoint.body != nil)
    }

    @Test("no endpoint at all when the drill cannot be expressed")
    func endpointRefusesImpossibleDrill() {
        #expect(PostHogAPI.insightActors(
            projectID: 1_001,
            source: trendsSource,
            drill: InsightDrill(
                kind: .funnelStep(step: 0, outcome: .droppedOff),
                title: "", expectedCount: 0
            )
        ) == nil)
    }
}

// MARK: - Response decoding

@Suite("Actors response decoding")
struct ActorsPageTests {

    private func page() throws -> ActorsPage {
        try ActorsPage.decode(from: Fixture.data("insight_actors.json"))
    }

    @Test("reads the paging envelope")
    func envelope() throws {
        let page = try page()
        #expect(page.hasMore)
        #expect(page.offset == 7)
        #expect(page.actors.count == 6)
    }

    @Test("keeps the count of actors PostHog could not resolve")
    func missingActors() throws {
        // The synthetic envelope keeps this nonzero so unresolved people cannot
        // silently disappear from the heading count.
        #expect(try page().missingActorsCount == 11)
    }

    @Test("decodes the resolved person shape")
    func resolvedPerson() throws {
        let actor = try #require(try page().actors.first)
        #expect(actor.id == "018f9000-0000-7000-8000-000000000114")
        #expect(actor.isUnresolved == false)
        #expect(actor.isIdentified)
        #expect(actor.name == "Example App metric 483")
        #expect(actor.email == "alex+0041@example.com")
        #expect(actor.distinctIDs.count == 5)
        #expect(actor.createdAt != nil)
        #expect(actor.displayName == "Example App metric 483")
        #expect(actor.initials == "EA")
    }

    @Test("decodes the unresolved shape, which has no properties at all")
    func unresolvedPerson() throws {
        // The fixture carries both response shapes in one `results` array. The
        // second intentionally has no `properties` key.
        let actor = try #require(try page().actors.dropFirst().first)
        #expect(actor.isUnresolved)
        #expect(actor.name == nil)
        #expect(actor.email == nil)
        // Still has a distinct id, which is a real handle — more use to someone
        // than the word "Anonymous".
        #expect(actor.displayName == "018f9000-0000-7000-8000-000000000251")
    }

    @Test("falls back to the email when a person has no name")
    func emailFallback() throws {
        let actor = try #require(try page().actors.last)
        #expect(actor.name == nil)
        #expect(actor.displayName == "alex+0044@example.com")
        #expect(actor.subtitle == "Example distinct ids 0500")
    }

    @Test("an empty response decodes to an empty page rather than throwing")
    func emptyResponse() throws {
        let page = try ActorsPage.decode(from: Data(#"{"columns":[],"results":[]}"#.utf8))
        #expect(page.actors.isEmpty)
        #expect(page.hasMore == false)
        #expect(page.missingActorsCount == 0)
    }

    @Test("finds the person column wherever it sits")
    func personColumnPosition() throws {
        // Funnel and lifecycle drills return three columns, trends four; nothing
        // promises `person` stays first.
        let json = """
            {"columns":["id","person"],"results":[["abc",{"id":"x","distinct_ids":["d1"]}]]}
            """
        let page = try ActorsPage.decode(from: Data(json.utf8))
        #expect(page.actors.first?.id == "x")
    }
}

// MARK: - Which insights offer the affordance

@Suite("Drill-down availability")
struct InsightDrilldownAxisTests {

    @Test("trends time-series displays drill to a point")
    func trendsAxes() {
        for display in [
            nil, "Auto", "ActionsLineGraph", "ActionsBar", "ActionsUnstackedBar",
            "ActionsStackedBar", "ActionsAreaGraph", "ActionsLineGraphCumulative",
            "Metric", "SlopeGraph", "TwoDimensionalHeatmap",
        ] {
            #expect(
                InsightDrilldown.axis(
                    sourceKind: "TrendsQuery", display: display, hasBreakdown: false
                ) == .trendsPoint,
                "\(display ?? "nil")"
            )
        }
    }

    @Test("aggregated displays drill to a breakdown value, but only with a breakdown")
    func aggregatedAxes() {
        for display in ["ActionsBarValue", "ActionsPie", "ActionsTable", "WorldMap"] {
            #expect(InsightDrilldown.axis(
                sourceKind: "TrendsQuery", display: display, hasBreakdown: true
            ) == .breakdown, "\(display)")
            // Without a breakdown each bar is a series, so no drill affordance
            // is offered for an incomplete actors query.
            #expect(InsightDrilldown.axis(
                sourceKind: "TrendsQuery", display: display, hasBreakdown: false
            ) == nil, "\(display)")
        }
    }

    @Test("lifecycle, funnels and stickiness each drill on their own axis")
    func otherKinds() {
        #expect(InsightDrilldown.axis(
            sourceKind: "LifecycleQuery", display: nil, hasBreakdown: false
        ) == .lifecycleBand)
        #expect(InsightDrilldown.axis(
            sourceKind: "FunnelsQuery", display: nil, hasBreakdown: false
        ) == .funnelStep)
        #expect(InsightDrilldown.axis(
            sourceKind: "StickinessQuery", display: nil, hasBreakdown: false
        ) == .stickinessBucket)
    }

    @Test("kinds that cannot be drilled honestly offer nothing")
    func undrillableKinds() {
        // Retention: `interval` is accepted and returns people, but against a
        // live 186 / 57 grid it returned 186 and **62**. PostHog's own
        // `InsightActorsQueryOptions` reports `interval: null` for retention.
        #expect(InsightDrilldown.axis(
            sourceKind: "RetentionQuery", display: nil, hasBreakdown: false
        ) == nil)
        // Paths: no per-edge parameter exists. Filtering the source by
        // pathStartKey/pathEndKey returned 10 people for an edge labelled 27.
        #expect(InsightDrilldown.axis(
            sourceKind: "PathsQuery", display: nil, hasBreakdown: false
        ) == nil)
        // HogQL is not in the `InsightActorsQuery.source` union at all.
        #expect(InsightDrilldown.axis(
            sourceKind: "HogQLQuery", display: nil, hasBreakdown: false
        ) == nil)
        // A single figure has nothing discrete to point at.
        #expect(InsightDrilldown.axis(
            sourceKind: "TrendsQuery", display: "BoldNumber", hasBreakdown: true
        ) == nil)
        // Routed to `.unsupported`; there is no chart to tap.
        for display in ["CalendarHeatmap", "BoxPlot"] {
            #expect(InsightDrilldown.axis(
                sourceKind: "TrendsQuery", display: display, hasBreakdown: true
            ) == nil, "\(display)")
        }
        #expect(InsightDrilldown.axis(
            sourceKind: "SomethingNew", display: nil, hasBreakdown: false
        ) == nil)
    }

    @Test("reads a breakdown out of either spelling of the saved query")
    func breakdownDetection() {
        // v2 saved queries, which is what this project's WorldMap insights are.
        #expect(InsightDrilldown.hasBreakdown(source: .object([
            "kind": .string("TrendsQuery"),
            "breakdownFilter": .object([
                "breakdown": .string("$geoip_country_code"),
                "breakdown_type": .string("person"),
            ]),
        ])))
        // Multi-breakdown.
        #expect(InsightDrilldown.hasBreakdown(source: .object([
            "breakdownFilter": .object(["breakdowns": .array([.object([:])])]),
        ])))
        // Older flat spelling.
        #expect(InsightDrilldown.hasBreakdown(source: .object([
            "breakdown": .string("$browser"),
        ])))
        // Present but empty.
        #expect(!InsightDrilldown.hasBreakdown(source: .object([
            "breakdownFilter": .object(["breakdown": .null]),
        ])))
        #expect(!InsightDrilldown.hasBreakdown(source: .object(["kind": .string("TrendsQuery")])))
        #expect(!InsightDrilldown.hasBreakdown(source: nil))
    }
}
