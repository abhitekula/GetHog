import Foundation
import Testing

@testable import GetHogKit

/// The saved-insight collection: its list shape, its filters, and its paging.
///
/// The JSON below is a deterministic fictional collection. It keeps the fields
/// the library reads while omitting actor objects that are irrelevant here.
@Suite("Insight library")
struct InsightLibraryTests {

    /// Two fictional rows in the collection shape.
    ///
    /// Row one is the common case: a trends line graph on a dashboard, with a
    /// null `result`. Row two is the one that has to be handled differently: a
    /// `HogQLQuery`, which this app draws no chart for.
    private static let listJSON = """
    {
      "count": 2,
      "next": "https://app.example.com/api/projects/1001/insights/?limit=2&offset=2",
      "previous": null,
      "results": [
        {
          "id": 710101,
          "short_id": "example-meteor-report",
          "name": "Example meteor report",
          "derived_name": null,
          "filters": {},
          "query": {
            "kind": "InsightVizNode",
            "source": {
              "kind": "TrendsQuery",
              "series": [{"kind": "EventsNode", "math": "total", "event": "trial_started"}],
              "version": 7,
              "trendsFilter": {"display": "ActionsLineGraph"}
            }
          },
          "order": null,
          "deleted": false,
          "dashboards": [710900],
          "last_refresh": null,
          "result": null,
          "created_at": "2026-01-14T09:30:00.125000Z",
          "description": null,
          "updated_at": "2026-01-17T16:10:00.250000Z",
          "favorited": false,
          "saved": true,
          "last_modified_at": "2026-01-17T16:10:00.250000Z",
          "is_sample": false,
          "is_cached": false,
          "tags": [],
          "last_viewed_at": "2026-01-18T08:00:00.500000Z"
        },
        {
          "id": 710106,
          "short_id": "harbor-ledger-table",
          "name": "Harbor ledger table",
          "derived_name": null,
          "query": {"kind": "DataTableNode", "source": {"kind": "HogQLQuery"}},
          "deleted": false,
          "dashboards": [],
          "last_refresh": "2026-01-18T09:00:00Z",
          "result": null,
          "created_at": "2026-01-13T09:00:00Z",
          "description": "Fictional ledger rows grouped by demo interval.",
          "favorited": true,
          "saved": true,
          "last_modified_at": "2026-01-18T09:00:00Z",
          "is_cached": true,
          "tags": ["harbor-ledger"]
        }
      ]
    }
    """

    private func page() throws -> Page<Insight> {
        try Page<Insight>.decode(from: Data(Self.listJSON.utf8))
    }

    // MARK: - Decoding

    @Test("decodes the fields the library screen lists rows from")
    func decodesListFields() throws {
        let insight = try #require(page().results.first)

        #expect(insight.id == 710101)
        #expect(insight.shortID == "example-meteor-report")
        #expect(insight.title == "Example meteor report")
        #expect(insight.sourceKind == "TrendsQuery")
        #expect(insight.kind == .trends)
        #expect(insight.favorited == false)
        #expect(insight.deleted == false)
        #expect(insight.dashboards == [710900])
        #expect(insight.tags.isEmpty)
        // `description` is deliberately null, so the row has to survive its
        // absence rather than print a placeholder.
        #expect(insight.description == nil)
    }

    /// PostHog sends fractional-second and whole-second ISO 8601 in the same
    /// payload — row one's timestamps carry microseconds, row two's do not — and
    /// the client decodes every model with one plain `JSONDecoder`, so a
    /// `dateDecodingStrategy` could only ever get one of them right.
    @Test("parses both ISO 8601 spellings PostHog mixes into one response")
    func parsesBothTimestampSpellings() throws {
        let rows = try page().results

        let withFraction = try #require(rows[0].lastModifiedAt)
        let withoutFraction = try #require(rows[1].lastModifiedAt)
        #expect(withFraction > Date(timeIntervalSince1970: 1_700_000_000))
        #expect(withoutFraction > Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rows[0].createdAt != nil)
        // Null on this row, which is why the library uses `lastModifiedAt`.
        #expect(rows[0].lastRefresh == nil)
        #expect(rows[1].lastRefresh != nil)
    }

    @Test("a missing flag or array reads as its empty value, never as a decode failure")
    func absentFieldsDegrade() throws {
        // Row two omits `order`, `filters`, `is_sample` and `last_viewed_at`
        // entirely, and a dashboard tile omits far more than that. None of them
        // may fail the row.
        let insight = try #require(page().results.last)
        #expect(insight.favorited)
        #expect(insight.isCached)
        #expect(insight.dashboards.isEmpty)
        #expect(insight.tags == ["harbor-ledger"])
    }

    /// The dashboard payload nests an insight with almost none of these fields.
    /// Making any of them required would fail a whole dashboard to decode a
    /// field only the library screen reads.
    @Test("an insight nested in a dashboard tile still decodes")
    func nestedInsightDecodes() throws {
        let dashboard = try Dashboard.decode(from: Fixture.data("dashboard_detail_raw.json"))
        let insight = try #require(dashboard.tiles.compactMap(\.insight).first)
        #expect(insight.id > 0)
        #expect(!insight.deleted)
    }

    // MARK: - Kinds

    /// Every public filter value must map back to the saved-query source kind.
    @Test("every kind round-trips between its filter value and its query kind")
    func kindsRoundTrip() {
        for kind in InsightKind.allCases {
            #expect(InsightKind(sourceKind: kind.sourceKind) == kind)
            #expect(kind.apiValue == kind.apiValue.uppercased())
            #expect(!kind.title.isEmpty)
        }
    }

    /// The one place PostHog's two vocabularies genuinely disagree. A screen
    /// offering "HogQL" would not match the console, and a filter sending
    /// `HOGQL` returns zero rows rather than an error — the silent-empty failure
    /// that makes this worth pinning.
    @Test("SQL is the filter's name for what the saved query calls HogQLQuery")
    func sqlIsHogQL() {
        #expect(InsightKind.sql.apiValue == "SQL")
        #expect(InsightKind.sql.sourceKind == "HogQLQuery")
        #expect(InsightKind(sourceKind: "HogQLQuery") == .sql)
        // A kind the app has no name for stays unnamed rather than being
        // folded onto the nearest one.
        #expect(InsightKind(sourceKind: "CalendarHeatmapQuery") == nil)
    }

    @Test("an insight reports the kind its saved query declares")
    func insightReportsItsKind() throws {
        let rows = try page().results
        #expect(rows[0].kind == .trends)
        #expect(rows[1].kind == .sql)
    }

    // MARK: - Link identity

    /// The console builds every link a user is *given* from the short id, so a
    /// link this app generates has to match one they may already have. The
    /// numeric fallback exists because a dashboard tile's insight can arrive
    /// without a handle.
    @Test("prefers the console handle for a link, falling back to the numeric id")
    func linkIDPrefersTheHandle() throws {
        let rows = try page().results
        #expect(rows[0].linkID == "example-meteor-report")

        let noHandle = try JSONDecoder().decode(
            Insight.self,
            from: Data(#"{"id": 42, "query": {"kind": "InsightVizNode"}}"#.utf8)
        )
        #expect(noHandle.linkID == "42")
        #expect(noHandle.shortID == nil)
    }

    // MARK: - Endpoints

    @Test("pages the collection with limit and offset")
    func pagesWithOffset() {
        let first = PostHogAPI.insights(projectID: 1_001, limit: 50)
        #expect(first.path == "/api/projects/1001/insights/")
        #expect(first.query.contains { $0.name == "limit" && $0.value == "50" })
        // Omitted at zero so the first page's URL is byte-identical to one the
        // response cache may already hold.
        #expect(!first.query.contains { $0.name == "offset" })

        let second = PostHogAPI.insights(projectID: 1_001, limit: 50, offset: 50)
        #expect(second.query.contains { $0.name == "offset" && $0.value == "50" })
    }

    @Test("narrowing the list is a server parameter, never a local filter")
    func filtersAreServerSide() {
        let endpoint = PostHogAPI.insights(
            projectID: 1,
            search: "signup",
            kind: .funnels,
            favoritedOnly: true
        )
        #expect(endpoint.query.contains { $0.name == "search" && $0.value == "signup" })
        #expect(endpoint.query.contains { $0.name == "insight" && $0.value == "FUNNELS" })
        #expect(endpoint.query.contains { $0.name == "favorited" && $0.value == "true" })
    }

    /// A blank or whitespace-only field must not become `?search=`, which
    /// PostHog treats as a real (empty) term rather than as no filter — and
    /// which would also make the URL differ from the unfiltered one for no
    /// reason, defeating the cache.
    @Test("an empty search term is not sent at all")
    func emptySearchIsOmitted() {
        for term in ["", "   ", "\n"] {
            let endpoint = PostHogAPI.insights(projectID: 1, search: term)
            #expect(!endpoint.query.contains { $0.name == "search" }, "sent search for \(term.debugDescription)")
        }
        let none = PostHogAPI.insights(projectID: 1)
        #expect(!none.query.contains { $0.name == "insight" })
        #expect(!none.query.contains { $0.name == "favorited" })
    }

    /// A collection request filtered to one row, not `/insights/<handle>/`. The
    /// Overloading one path segment with two id namespaces would let an all-digit handle select a different
    /// insight. It also returns an empty page rather than a 404 for an unknown
    /// handle, which is how the caller tells "no such insight" from "the request
    /// failed".
    @Test("resolves a console handle through the collection rather than the path")
    func shortIDLookupUsesTheCollection() {
        let endpoint = PostHogAPI.insight(projectID: 1_001, shortID: "example-meteor-report")
        #expect(endpoint.path == "/api/projects/1001/insights/")
        #expect(endpoint.query.contains { $0.name == "short_id" && $0.value == "example-meteor-report" })
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "1" })
    }

    /// Three refresh promises, three different words, and they are not
    /// interchangeable: `force_cache` never computes, `lazy_async` returns
    /// immediately with a `query_status` and expects polling, and `blocking`
    /// waits and returns the numbers.
    @Test("each insight refresh mode asks for what it actually promises")
    func refreshModesAreDistinct() {
        let cached = PostHogAPI.insight(projectID: 1, insightID: 2)
        #expect(cached.query.contains { $0.name == "refresh" && $0.value == "force_cache" })

        let lazy = PostHogAPI.insight(projectID: 1, insightID: 2, refresh: true)
        #expect(lazy.query.contains { $0.name == "refresh" && $0.value == "lazy_async" })

        let blocking = PostHogAPI.computeInsight(projectID: 1, insightID: 2)
        #expect(blocking.path == "/api/projects/1/insights/2/")
        #expect(blocking.query.contains { $0.name == "refresh" && $0.value == "blocking" })
        // Charged to the analytics budget, like every other computation.
        #expect(blocking.category == .analytics)
    }
}
