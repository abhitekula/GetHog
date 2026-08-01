import Foundation
import Testing

@testable import GetHogKit

@Suite("Outbound link clicks")
struct WebExternalClicksTests {
    @Test("synthetic fixture uses authored reserved destinations")
    func syntheticFixtureDestinations() throws {
        let rows = WebExternalClickRow.rows(
            from: try QueryResponse.decode(from: Fixture.data("web_external_clicks.json"))
        )

        #expect(rows.map(\.url) == [
            "https://example.com/docs",
            "https://example.net/status",
            "https://example.org/changelog",
            "https://maps.example/launchpad",
        ])
        #expect(rows.map(\.visitors) == [28, 17, 9, 4])
        #expect(rows.map(\.clicks) == [42, 29, 15, 6])
    }


    @Test("reads the current figure out of each [current, previous] pair")



    func unwrapsPairs() throws {
        let response = try QueryResponse.decode(from: Fixture.data("web_external_clicks.json"))
        let rows = WebExternalClickRow.rows(from: response)

        #expect(rows.count == 4)
        let first = try #require(rows.first)
        // Pair cells expose the current period through their leading value.
        #expect(first.visitors == 28)
        #expect(first.clicks == 42)
    }

    @Test("maps cells by column name, not by position")
    func columnsAreLookedUpByName() throws {
        // Same data, columns declared in a different order. Positional decoding
        // would silently report the URL as a click count.
        let json = """
        {
          "columns": ["context.columns.clicks", "context.columns.url", "context.columns.visitors"],
          "results": [[[7, 2], "https://example.com/a", [3, 1]]]
        }
        """
        let rows = WebExternalClickRow.rows(from: try QueryResponse.decode(from: Data(json.utf8)))

        let row = try #require(rows.first)
        #expect(row.url == "https://example.com/a")
        #expect(row.clicks == 7)
        #expect(row.visitors == 3)
    }

    @Test("tolerates scalar cells, since only the pair shape has been observed")
    func scalarCells() throws {
        let json = """
        {
          "columns": ["context.columns.url", "context.columns.visitors", "context.columns.clicks"],
          "results": [["https://example.com/b", 4, 9]]
        }
        """
        let row = try #require(
            WebExternalClickRow.rows(from: try QueryResponse.decode(from: Data(json.utf8))).first
        )
        #expect(row.visitors == 4)
        #expect(row.clicks == 9)
    }

    @Test("offers a destination only for web URLs")



    func destinations() throws {
        let response = try QueryResponse.decode(from: Fixture.data("web_external_clicks.json"))
        let rows = WebExternalClickRow.rows(from: response)
        #expect(rows.allSatisfy { $0.destination != nil })

        let mapsRow = try #require(rows.first { $0.url.contains("maps.example") })
        #expect(mapsRow.destination?.absoluteString.contains("/launchpad") == true)
        #expect(mapsRow.host == "maps.example")

        let scriptRow = WebExternalClickRow(url: "javascript:alert(1)", visitors: 1, clicks: 1)
        #expect(scriptRow.destination == nil)
    }

    @Test("skips rows without a URL rather than rendering blank entries")
    func skipsRowsWithoutURL() throws {
        let json = """
        {
          "columns": ["context.columns.url", "context.columns.visitors", "context.columns.clicks"],
          "results": [[null, [1, 0], [1, 0]], ["https://example.com/c", [2, 0], [5, 0]]]
        }
        """
        let rows = WebExternalClickRow.rows(from: try QueryResponse.decode(from: Data(json.utf8)))
        #expect(rows.count == 1)
        #expect(rows.first?.url == "https://example.com/c")
    }
}

@Suite("Notable changes")
struct WebNotableChangesTests {

    private func fixtureChanges() throws -> [WebNotableChange] {
        try WebNotableChangesResponse.decode(from: Fixture.data("web_notable_changes.json")).changes
    }

    @Test("synthetic fixture uses an authored comparison set")
    func syntheticFixtureComparisonSet() throws {
        let changes = try fixtureChanges()

        #expect(changes.count == 5)
        #expect(changes.map(\.dimensionValue) == [
            "/launchpad", "$direct", "Orion", "Canada", "/workbench",
        ])
        #expect(changes.map(\.impactScore) == [93.2, 75, 62.4, 48.1, 31.5])
        #expect(changes.allSatisfy { $0.hasComparablePrevious })
    }

    @Test("decodes object-shaped rows, which carry no columns array")



    func decodesObjectRows() throws {
        let changes = try fixtureChanges()

        #expect(changes.count == 5)
        let top = try #require(changes.first)
        #expect(top.metric == "sample sessions")
        #expect(top.dimensionType == "path")
        #expect(top.dimensionValue == "/launchpad")
        #expect(top.currentValue == 88)
    }

    // A percentage paired with a zero denominator is not comparable and must be hidden.
    @Test("suppresses the percentage when previous_value is zero")



    func zeroPreviousSuppressesPercentage() throws {
        let data = Data(#"{"results":[{"metric":"visitors","dimension_type":"path","dimension_value":"/zero-baseline","current_value":12,"previous_value":0,"percent_change":10,"impact_score":3}]}"#.utf8)
        let change = try #require(try WebNotableChangesResponse.decode(from: data).changes.first)

        #expect(change.previousValue == 0)
        #expect(change.comparablePercentChange == nil)
        #expect(!change.hasComparablePrevious)
        #expect(change.isImprovement == nil)
    }

    @Test("suppresses the percentage when previous_value is absent")
    func missingPreviousSuppressesPercentage() throws {
        let json = """
        {"results":[{"metric":"visitors","dimension_type":"Country","dimension_value":"US",
        "current_value":12.0,"percent_change":10.0,"impact_score":3.0}]}
        """
        let change = try #require(
            try WebNotableChangesResponse.decode(from: Data(json.utf8)).changes.first
        )
        #expect(change.previousValue == nil)
        #expect(change.comparablePercentChange == nil)
    }

    @Test("shows the percentage once a nonzero previous period exists")
    func nonzeroPreviousIsShown() throws {
        // Suppression is conditional: a meaningful denominator restores the figure.
        let json = """
        {"results":[{"metric":"visitors","dimension_type":"Country","dimension_value":"US",
        "current_value":120.0,"previous_value":100.0,"percent_change":20.0,"impact_score":9.0}]}
        """
        let change = try #require(
            try WebNotableChangesResponse.decode(from: Data(json.utf8)).changes.first
        )
        #expect(change.comparablePercentChange == 20)
        #expect(change.hasComparablePrevious)
        #expect(change.isImprovement == true)
    }

    @Test("never derives its own percentage from a zero previous value")
    func neverDividesByZero() throws {
        let changes = try fixtureChanges()
        // Dividing current by a zero previous is the infinity bug; the suppressed
        // value must be absent, not an infinite or NaN percentage.
        #expect(changes.allSatisfy { ($0.comparablePercentChange ?? 0).isFinite })
    }

    @Test("ranks by impact score, descending")



    func rankedByImpact() throws {
        let scores = try fixtureChanges().map(\.impactScore)
        #expect(scores == scores.sorted(by: >))
        #expect(scores.first == 93.2)
    }

    @Test("re-ranks rows the API returns out of order")
    func reranksUnorderedRows() throws {
        let json = """
        {"results":[
          {"metric":"visitors","dimension_type":"Page","dimension_value":"/a",
           "current_value":1.0,"previous_value":0.0,"percent_change":10.0,"impact_score":5.0},
          {"metric":"visitors","dimension_type":"Page","dimension_value":"/b",
           "current_value":9.0,"previous_value":0.0,"percent_change":10.0,"impact_score":90.0}
        ]}
        """
        let changes = try WebNotableChangesResponse.decode(from: Data(json.utf8)).changes
        #expect(changes.map(\.dimensionValue) == ["/b", "/a"])
    }

    @Test("treats a rising bounce rate as a regression, not a win")
    func bounceRateDirection() throws {
        let json = """
        {"results":[
          {"metric":"bounce rate","dimension_type":"Page","dimension_value":"/",
           "current_value":70.0,"previous_value":50.0,"percent_change":40.0,"impact_score":9.0},
          {"metric":"visitors","dimension_type":"Page","dimension_value":"/",
           "current_value":70.0,"previous_value":50.0,"percent_change":40.0,"impact_score":8.0}
        ]}
        """
        let changes = try WebNotableChangesResponse.decode(from: Data(json.utf8)).changes
        let bounce = try #require(changes.first { $0.metric == "bounce rate" })
        let visitors = try #require(changes.first { $0.metric == "visitors" })

        #expect(bounce.isIncreaseBad)
        #expect(bounce.isImprovement == false)
        #expect(!visitors.isIncreaseBad)
        #expect(visitors.isImprovement == true)
    }

    @Test("spells out PostHog's referrer sentinel instead of printing $direct")
    func directReferrerLabel() throws {
        let changes = try fixtureChanges()
        let direct = try #require(changes.first { $0.dimensionValue == "$direct" })
        #expect(direct.displayValue == "Direct")
        #expect(!changes.contains { $0.displayValue.hasPrefix("$") })
    }

    @Test("always has a dimension label, since it is drawn as a pill")
    func dimensionLabelIsNeverBlank() throws {
        let json = """
        {"results":[{"metric":"visitors","dimension_value":"US",
        "current_value":12.0,"previous_value":0.0,"percent_change":10.0,"impact_score":3.0}]}
        """
        let change = try #require(
            try WebNotableChangesResponse.decode(from: Data(json.utf8)).changes.first
        )
        #expect(change.dimensionType.isEmpty)
        #expect(change.displayDimension == "Dimension")
    }

    @Test("survives an empty result set")
    func emptyResults() throws {
        let empty = try WebNotableChangesResponse.decode(from: Data(#"{"results":[]}"#.utf8))
        #expect(empty.isEmpty)
    }

    @Test("reports a malformed payload as an error rather than as no findings")
    func malformedPayloadThrows() {
        // Swallowing this would render a failed request as a calm "nothing
        // notable", which is the same lie as showing stale data silently.
        #expect(throws: (any Error).self) {
            try WebNotableChangesResponse.decode(from: Data("not json".utf8))
        }
    }
}

@Suite("Web extras endpoints")
struct WebExtrasEndpointTests {

    @Test("builds an external clicks query")
    func externalClicks() throws {
        let endpoint = PostHogAPI.webExternalClicks(projectID: 1_001, dateFrom: "-30d")
        let body = String(decoding: try #require(endpoint.body), as: UTF8.self)

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1001/query/")
        #expect(body.contains("WebExternalClicksTableQuery"))
        #expect(body.contains("-30d"))
    }

    @Test("builds a notable changes query")
    func notableChanges() throws {
        let endpoint = PostHogAPI.webNotableChanges(projectID: 1_001, dateFrom: "-7d")
        let body = String(decoding: try #require(endpoint.body), as: UTF8.self)

        #expect(body.contains("WebNotableChangesQuery"))
        #expect(body.contains("-7d"))
        // Omitting `properties` returns HTTP 400 from the query endpoint.
        #expect(body.contains("properties"))
    }
}
