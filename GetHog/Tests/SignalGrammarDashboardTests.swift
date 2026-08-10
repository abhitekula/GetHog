import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Dashboard Signal Grammar")
struct SignalGrammarDashboardTests {
    @Test("Dashboard search filters recent candidates with the collection")
    func dashboardSearchFiltersRecentCandidates() throws {
        let data = Data(#"""
        {"results":[
          {"id":725101,"name":"Example App metric 33","pinned":true,"last_refresh":"2026-07-31T12:00:00Z"},
          {"id":725102,"name":"Activation","pinned":false,"last_refresh":"2026-07-30T12:00:00Z"}
        ]}
        """#.utf8)
        let page = try JSONDecoder().decode(Page<DashboardSummary>.self, from: data)

        #expect(filteredDashboards(page.results, matching: "definitely-no-dashboard").isEmpty)
        #expect(filteredDashboards(page.results, matching: "activation").map(\.id) == [725_102])
    }

    @Test("Overview facts separate computed and generated dashboards")
    func overviewFacts() throws {
        let data = Data(#"""
        {"results":[
          {"id":1,"name":"Product health","pinned":true,"last_refresh":"2026-07-31T12:00:00Z","creation_mode":"default"},
          {"id":2,"name":"Activation","pinned":false,"last_refresh":"2026-07-30T12:00:00Z","creation_mode":"default"},
          {"id":3,"name":"Generated Dashboard: flag","pinned":false,"creation_mode":"template"}
        ]}
        """#.utf8)
        let page = try JSONDecoder().decode(Page<DashboardSummary>.self, from: data)
        let facts = DashboardOverviewFacts(dashboards: page.results)

        #expect(facts.dashboardCount == 3)
        #expect(facts.computedCount == 2)
        #expect(facts.generatedCount == 1)
        #expect(facts.pinned?.title == "Product health")
        #expect(facts.recentlyComputed.map(\.title) == ["Product health", "Activation"])
    }

    @Test("Computed total is not limited by the recent preview")
    func computedTotalBeyondPreviewLimit() throws {
        let data = Data(#"""
        {"results":[
          {"id":1,"name":"One","pinned":false,"last_refresh":"2026-07-31T12:00:00Z"},
          {"id":2,"name":"Two","pinned":false,"last_refresh":"2026-07-30T12:00:00Z"},
          {"id":3,"name":"Three","pinned":false,"last_refresh":"2026-07-29T12:00:00Z"},
          {"id":4,"name":"Four","pinned":false,"last_refresh":"2026-07-28T12:00:00Z"},
          {"id":5,"name":"Five","pinned":false,"last_refresh":"2026-07-27T12:00:00Z"},
          {"id":6,"name":"Six","pinned":false,"last_refresh":"2026-07-26T12:00:00Z"},
          {"id":7,"name":"Never computed","pinned":false}
        ]}
        """#.utf8)
        let page = try JSONDecoder().decode(Page<DashboardSummary>.self, from: data)
        let facts = DashboardOverviewFacts(dashboards: page.results)

        #expect(facts.computedCount == 6)
        #expect(facts.recentlyComputed.count == 5)
    }

    @Test("Dashboard provenance maps to stable branded glyphs")
    func provenanceGlyphs() {
        #expect(DashboardBrandAppearance.glyph(for: .default) == .dashboard)
        #expect(DashboardBrandAppearance.glyph(for: .template) == .generatedDashboard)
        #expect(DashboardBrandAppearance.glyph(for: .duplicate) == .dashboard)
        #expect(DashboardBrandAppearance.glyph(for: .unknown) == .dashboard)
    }
}
