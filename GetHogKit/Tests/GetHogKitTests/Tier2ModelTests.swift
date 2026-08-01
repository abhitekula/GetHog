import Foundation
import Testing

@testable import GetHogKit

@Suite("Web analytics")
struct WebAnalyticsTests {
    @Test("synthetic overview uses authored metric values")

    func syntheticOverviewValues() throws {
        let response = try WebOverviewResponse.decode(from: Fixture.data("web_overview.json"))

        #expect(response.metrics.map(\.key) == [
            "sample conversions", "sample visitors", "sample sessions", "sample views",
            "sample bounce rate", "sample session duration",
        ])
        #expect(response.metrics.map(\.value) == [26, 312, 407, 1_035, 38.4, 172.4])
    }


    @Test("decodes web overview metrics")



    func decodesOverview() throws {
        let response = try WebOverviewResponse.decode(from: Fixture.data("web_overview.json"))

        #expect(response.metrics.count == 6)
        #expect(response.metrics.map(\.key) == [
            "sample conversions", "sample visitors", "sample sessions", "sample views",
            "sample bounce rate", "sample session duration",
        ])
        #expect(try #require(response.metric(named: "sample visitors")).value == 312)
        #expect(try #require(response.metric(named: "sample views")).value == 1_035)
        #expect(try #require(response.metric(named: "sample sessions")).value == 407)
    }

    @Test("formats each metric kind appropriately")



    func formatsByKind() throws {
        let response = try WebOverviewResponse.decode(from: Fixture.data("web_overview.json"))

        let duration = try #require(response.metric(named: "sample session duration"))
        #expect(duration.kind == .durationSeconds)
        #expect(duration.formattedValue == "2m 52s")

        let bounce = try #require(response.metric(named: "sample bounce rate"))
        #expect(bounce.kind == .percentage)
        #expect(bounce.formattedValue == "38.4%")
    }

    @Test("knows when a rise is bad, so trend arrows aren't misleading")

    func increaseDirection() throws {
        let response = try WebOverviewResponse.decode(from: Fixture.data("web_overview.json"))
        #expect(try #require(response.metric(named: "sample bounce rate")).isIncreaseBad == true)
        #expect(try #require(response.metric(named: "sample visitors")).isIncreaseBad != true)
    }
}

@Suite("Error tracking")
struct ErrorTrackingTests {

    @Test("decodes issues with their nested aggregations")
    func decodesIssues() throws {
        let page = try ErrorTrackingResponse.decode(from: Fixture.data("error_tracking.json"))
        #expect(page.issues.count == 7)

        let first = try #require(page.issues.first)
        #expect(first.id == "018f3300-0000-7000-8000-000000000901")
        #expect(first.name == "HarborRenderFault")
        #expect(first.status == "active")
        #expect(first.issueDescription == "Harbor card state was unavailable.")
        #expect(first.source == "app://quill-harbor/views/card.swift")
        // Counts live under the nested `aggregations` object.
        #expect(first.occurrences == 29)
        #expect(first.sessions == 11)
        #expect(first.users == 9)
        #expect(first.firstSeen != nil)
    }

    @Test("ranks issues by user impact")
    func rankByImpact() throws {
        let page = try ErrorTrackingResponse.decode(from: Fixture.data("error_tracking.json"))
        let ranked = page.issues.sorted { $0.users > $1.users }
        #expect(ranked.map(\.users) == [9, 8, 7, 6, 5, 4, 4])
        #expect(ranked.map(\.id) == [
            "018f3300-0000-7000-8000-000000000901",
            "018f3300-0000-7000-8000-000000000902",
            "018f3300-0000-7000-8000-000000000903",
            "018f3300-0000-7000-8000-000000000904",
            "018f3300-0000-7000-8000-000000000905",
            "018f3300-0000-7000-8000-000000000906",
            "018f9a00-0000-7000-8000-000000000008",
        ])
    }

    @Test("keeps every fictional issue identity and description exact")
    func exactIssueProfiles() throws {
        let issues = try ErrorTrackingResponse.decode(from: Fixture.data("error_tracking.json")).issues
        #expect(issues.map(\.name) == [
            "HarborRenderFault", "LedgerFetchFault", "ChartSpanFault",
            "AssetParcelFault", "DeferredExportFault", "RuleSetFault",
            "Synthetic added RuleSetFault",
        ])
        #expect(issues.map(\.issueDescription) == [
            "Harbor card state was unavailable.",
            "Ledger response could not be decoded.",
            "Selected chart span exceeds the demo window.",
            "Harbor asset parcel could not be loaded.",
            "Deferred export ended without a result.",
            "Rule set requires one demo clause.",
            "Rule set requires one demo clause.",
        ])
        #expect(issues.map(\.function) == [
            nil, "fetchHarborLedger", nil, "loadHarborParcel", nil, nil, nil,
        ])
    }

    /// The envelope reports its own cap and an explicit continuation flag,
    /// exercising truncation independently of any remote project.
    @Test("carries the envelope's own account of what it withheld")
    func decodesTruncationEnvelope() throws {
        let page = try ErrorTrackingResponse.decode(from: Fixture.data("error_tracking.json"))
        #expect(page.hasMore)
        #expect(page.appliedLimit == 88)
        #expect(page.resultCount == 7)
    }

    /// The explicit continuation flag remains authoritative even under the cap.
    @Test("a page at or over its cap is a page with more behind it")
    func coverageFromFixtureEnvelope() throws {
        let page = try ErrorTrackingResponse.decode(from: Fixture.data("error_tracking.json"))
        let coverage = page.coverage(requestedLimit: 50)
        // PostHog reported its own cap, so ours is not the one to quote.
        #expect(coverage.cap == 88)
        #expect(coverage.isTruncated)
        let note = coverage.note(shown: page.issues.count, window: "last 7 days")
        #expect(note.contains("7 issues"))
        #expect(note.contains("PostHog reported more"))
        // Never the word "total": the figures it qualifies are page sums.
        #expect(!note.lowercased().contains("total for"))
    }

    /// A short page states its completeness rather than going quiet, so the
    /// absence of a caveat is never itself the claim.
    @Test("a page under its cap says it is all of them")
    func coverageWhenComplete() {
        let coverage = ErrorIssueCoverage(issuesReturned: 6, cap: 50, envelopeHasMore: false)
        #expect(!coverage.isTruncated)
        #expect(coverage.note(shown: 6, window: "last 7 days").contains("all 6 issues"))
    }

    /// The flag alone, with a page nowhere near its cap: PostHog capping below
    /// what was asked for is the case a row comparison cannot see.
    @Test("the envelope flag is honoured under a short page")
    func coverageHonoursTheFlagAlone() {
        let coverage = ErrorIssueCoverage(issuesReturned: 3, cap: 50, envelopeHasMore: true)
        #expect(coverage.isTruncated)
    }
}

@Suite("Persons, cohorts and surveys")
struct DirectoryTests {

    @Test("decodes persons with distinct ids and properties")
    func decodesPersons() throws {
        let page = try Page<PersonSummary>.decode(from: Fixture.data("persons.json"))
        let first = try #require(page.results.first)

        #expect(page.results.count == 5)
        #expect(page.next == "https://example.net/api/people?limit=4&offset=4")
        #expect(page.previous == nil)
        #expect(first.id == "018f9000-0000-7000-8000-000000000426")
        #expect(first.name == "Sable Okafor")
        #expect(first.displayName == "Sable Okafor")
        #expect(first.initials == "SO")
        #expect(first.isIdentified)
        #expect(first.distinctIDs.count == 3)
        #expect(first.distinctIDs == [
            "person:sable:primary",
            "person:sable:tablet",
            "person:sable:browser",
        ])
        #expect(first.createdAt != nil)
    }

    @Test("decodes cohorts with their member counts")
    func decodesCohorts() throws {
        let page = try Page<Cohort>.decode(from: Fixture.data("cohorts.json"))
        let first = try #require(page.results.first)

        #expect(page.count == 4)
        #expect(page.results.count == 2)
        #expect(first.id == 48_017)
        #expect(first.name == "Example observatory test crew")
        #expect(first.count == 27)
        #expect(!first.isStatic)
        #expect(first.cohortType == "realtime")
        #expect(first.definition?.conditionCount == 4)
        #expect(first.isRecalculating == false)
    }

    @Test("decodes surveys with their questions")
    func decodesSurveys() throws {
        let page = try Page<Survey>.decode(from: Fixture.data("surveys.json"))
        let first = try #require(page.results.first)

        #expect(page.results.count == 6)
        #expect(first.name == "Example App metric 829")
        #expect(first.type == "popover")
        #expect(first.questions.count == 3)
        // No start date means it was never launched.
        #expect(!first.isRunning)
    }
}

@Suite("Tier 2 endpoints")
struct Tier2EndpointTests {

    @Test("builds the web overview query")
    func webOverview() throws {
        let endpoint = PostHogAPI.webOverview(projectID: 1_001, dateFrom: "-7d")
        #expect(endpoint.method == "POST")
        #expect(endpoint.category == .query)

        let body = String(decoding: try #require(endpoint.body), as: UTF8.self)
        #expect(body.contains("WebOverviewQuery"))
        #expect(body.contains("-7d"))
    }

    @Test("includes volumeResolution, which the API rejects the query without")
    func errorTrackingRequiredField() throws {
        let endpoint = PostHogAPI.errorTrackingIssues(projectID: 1_001, dateFrom: "-7d", limit: 25)
        let body = String(decoding: try #require(endpoint.body), as: UTF8.self)
        #expect(body.contains("ErrorTrackingQuery"))
        // Omitting this returns HTTP 400 with a pydantic validation error.
        #expect(body.contains("volumeResolution"))
    }

    @Test("builds directory endpoints")
    func directoryEndpoints() {
        #expect(PostHogAPI.persons(projectID: 1_001).path == "/api/projects/1001/persons/")
        #expect(PostHogAPI.cohorts(projectID: 1_001).path == "/api/projects/1001/cohorts/")
        #expect(PostHogAPI.surveys(projectID: 1_001).path == "/api/projects/1001/surveys/")
        #expect(PostHogAPI.experiments(projectID: 1_001).path == "/api/projects/1001/experiments/")
        #expect(PostHogAPI.insights(projectID: 1_001).path == "/api/projects/1001/insights/")
    }
}
