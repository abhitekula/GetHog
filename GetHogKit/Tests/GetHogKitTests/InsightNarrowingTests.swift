import Foundation
import Testing

@testable import GetHogKit

/// Narrowing a re-run insight by a property filter and a breakdown.
///
/// The suite exists mostly to pin one shape and one refusal, both of which are
/// easy to get wrong in a way that only fails on the wire:
///
/// * `properties` on an insight query node is a **bare array**, not the nested
///   `PropertyGroupFilter` correction 14 pins for `TraceSpansQuery.filterGroup`.
///   Two differently-typed fields; copying either onto the other is the trap.
/// * A key the node's kind cannot carry is not written at all, because pydantic
///   answers `Extra inputs are not permitted` and the request is spent.
@Suite("Insight narrowing")
struct InsightNarrowingTests {

    private func trendsSource() throws -> JSONValue {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        let insight = try #require(
            dashboard.tiles.compactMap(\.insight).first { $0.sourceKind == "TrendsQuery" }
        )
        return try #require(insight.rawSource)
    }

    // MARK: - The stored shape

    /// The fixture exercises the saved shape the client preserves: `properties`
    /// is a bare array on every saved insight that carries it.
    @Test("every saved insight carries `properties` as a bare array")
    func savedPropertiesAreArrays() throws {
        let page = try Page<Insight>.decode(from: Fixture.data("insights_list.json"))
        var checked = 0
        for insight in page.results {
            guard let properties = insight.rawSource?["properties"] else { continue }
            checked += 1
            guard case .array = properties else {
                Issue.record("\(insight.title) stored `properties` as \(properties)")
                continue
            }
        }
        #expect(checked > 0, "no saved insight carried a `properties` key at all")
    }

    /// The `breakdownFilter` this code writes must preserve both stored keys.
    @Test("the written breakdownFilter matches the stored shape")
    func storedBreakdownShape() throws {
        let page = try Page<Insight>.decode(from: Fixture.data("insights_list.json"))
        let stored = try #require(
            page.results.compactMap { $0.rawSource?["breakdownFilter"] }
                .first { $0["breakdowns"] != nil }
        )
        let breakdowns = try #require(stored["breakdowns"])
        guard case .array(let entries) = breakdowns, let first = entries.first else {
            Issue.record("stored breakdowns was not a non-empty array")
            return
        }
        let property = try #require(first["property"]?.stringValue)
        let scopeName = try #require(first["type"]?.stringValue)
        let scope = try #require(InsightBreakdown.Scope(rawValue: scopeName))

        // Rebuilt from the two facts the stored value carries, and required to equal
        // the stored value itself. A missing `breakdown_type`, an extra key, or a
        // renamed one all fail here.
        #expect(InsightBreakdown(scope: scope, property: property).jsonValue == stored)
    }

    // MARK: - Filters

    @Test("writes property filters as a bare array, never as a PropertyGroupFilter")
    func filtersAreABareArray() throws {
        let rebuilt = InsightRerun.source(
            try trendsSource(),
            dateFrom: "-7d",
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .saved
        )
        let properties = try #require(rebuilt["properties"])

        guard case .array(let entries) = properties else {
            Issue.record("properties was \(properties), not an array")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0] == .object([
            "key": .string("$browser"),
            "type": .string("event"),
            "operator": .string("exact"),
            // An array of one, which is what PostHog's console emits for `exact`.
            "value": .array([.string("Chrome")]),
        ]))
        // The `filterGroup` shape must not appear anywhere near this key.
        #expect(properties["type"] == nil)
        #expect(properties["values"] == nil)
    }

    @Test("negation writes is_not rather than a second key")
    func negatedFilter() {
        let filter = InsightPropertyFilter(
            scope: .person, key: "email", value: "person@example.com", isNegated: true
        )
        #expect(filter.jsonValue["operator"] == .string("is_not"))
        #expect(filter.jsonValue["type"] == .string("person"))
    }

    /// An empty filter list leaves the node's own `properties` alone. Replacing
    /// it with `[]` would silently discard whatever narrowing the insight was
    /// saved with, on a screen the user opened to change the *date*.
    @Test("no filters leaves the saved properties untouched")
    func emptyFiltersPreserveSaved() {
        let source = JSONValue.object([
            "kind": .string("TrendsQuery"),
            "properties": .array([.object(["key": .string("saved")])]),
        ])
        let rebuilt = InsightRerun.source(
            source, dateFrom: "-7d", compare: false, filters: [], breakdown: .saved
        )
        #expect(rebuilt["properties"] == source["properties"])
    }

    @Test("scope is part of a filter's identity")
    func scopeDistinguishesFilters() {
        let event = InsightPropertyFilter(scope: .event, key: "email", value: "person@example.com")
        let person = InsightPropertyFilter(scope: .person, key: "email", value: "person@example.com")
        #expect(event.id != person.id)
    }

    // MARK: - Breakdown

    @Test("replacing the breakdown writes both keys PostHog stores")
    func replacedBreakdown() throws {
        let rebuilt = InsightRerun.source(
            try trendsSource(),
            dateFrom: "-7d",
            compare: false,
            filters: [],
            breakdown: .property(InsightBreakdown(scope: .event, property: "$browser"))
        )
        #expect(rebuilt["breakdownFilter"] == .object([
            "breakdowns": .array([
                .object(["type": .string("event"), "property": .string("$browser")])
            ]),
            "breakdown_type": .string("event"),
        ]))
    }

    @Test("`.saved` and `.none` are different requests")
    func breakdownOverrideStates() {
        let source = JSONValue.object([
            "kind": .string("TrendsQuery"),
            "breakdownFilter": .object(["breakdown_type": .string("event")]),
        ])

        let untouched = InsightRerun.source(
            source, dateFrom: "-7d", compare: false, filters: [], breakdown: .saved
        )
        #expect(untouched["breakdownFilter"] == source["breakdownFilter"])

        let cleared = InsightRerun.source(
            source, dateFrom: "-7d", compare: false, filters: [], breakdown: .none
        )
        #expect(cleared["breakdownFilter"] == nil)
    }

    // MARK: - Kinds

    /// The list itself, pinned. When PostHog adds a query kind, this is the test
    /// that has to be updated deliberately rather than a screen that quietly
    /// stops offering a control.
    @Test("only the kinds that inherit InsightsQueryBase accept property filters")
    func filterableKinds() {
        for kind in [
            "TrendsQuery", "FunnelsQuery", "RetentionQuery",
            "PathsQuery", "LifecycleQuery", "StickinessQuery", "CalendarHeatmapQuery",
        ] {
            #expect(InsightNarrowing(sourceKind: kind).supportsPropertyFilters, "\(kind)")
        }
        #expect(!InsightNarrowing(sourceKind: "HogQLQuery").supportsPropertyFilters)
    }

    @Test("only trends, funnels and retention accept a breakdown")
    func breakdownableKinds() {
        for kind in ["TrendsQuery", "FunnelsQuery", "RetentionQuery"] {
            #expect(InsightNarrowing(sourceKind: kind).supportsBreakdown, "\(kind)")
        }
        for kind in ["LifecycleQuery", "StickinessQuery", "PathsQuery", "HogQLQuery"] {
            #expect(!InsightNarrowing(sourceKind: kind).supportsBreakdown, "\(kind)")
        }
    }

    /// The refusal that keeps a request from being spent on a certain 400.
    @Test("a kind that cannot carry a key never has one written")
    func unsupportedKindsAreNotRewritten() {
        let hogql = JSONValue.object(["kind": .string("HogQLQuery"), "query": .string("SELECT 1")])
        let rebuilt = InsightRerun.source(
            hogql,
            dateFrom: "-7d",
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .property(InsightBreakdown(scope: .event, property: "$os"))
        )
        #expect(rebuilt["properties"] == nil)
        #expect(rebuilt["breakdownFilter"] == nil)
        // The query itself survives untouched — this is a refusal, not a rewrite.
        #expect(rebuilt["query"] == .string("SELECT 1"))

        // A lifecycle insight can be filtered and cannot be broken down, so it
        // gets exactly one of the two.
        let lifecycle = JSONValue.object(["kind": .string("LifecycleQuery")])
        let mixed = InsightRerun.source(
            lifecycle,
            dateFrom: "-7d",
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .property(InsightBreakdown(scope: .event, property: "$os"))
        )
        #expect(mixed["properties"] != nil)
        #expect(mixed["breakdownFilter"] == nil)
    }

    @Test("an unnarrowable kind explains itself rather than going quiet")
    func unavailableReasonIsStated() {
        #expect(InsightNarrowing(sourceKind: "TrendsQuery").unavailableReason == nil)
        let reason = InsightNarrowing(sourceKind: "HogQLQuery").unavailableReason
        #expect(reason?.contains("SQL") == true)
    }

    // MARK: - Shared with the date-only form

    /// The long form must not have drifted from `source(_:dateFrom:compare:)`.
    /// They share `dated(_:…)`; this is what notices if somebody unshares them.
    @Test("the narrowing form applies the same date rewrite as the plain one")
    func dateBehaviourIsShared() throws {
        let source = try trendsSource()
        let plain = InsightRerun.source(source, dateFrom: "-90d", compare: true)
        let narrowed = InsightRerun.source(
            source, dateFrom: "-90d", compare: true, filters: [], breakdown: .saved
        )
        #expect(plain == narrowed)
    }

    @Test("leaves a non-object source alone")
    func ignoresNonObject() {
        let source = JSONValue.string("not a query")
        #expect(
            InsightRerun.source(
                source, dateFrom: "-7d", compare: false, filters: [], breakdown: .none
            ) == source
        )
    }
}
