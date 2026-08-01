import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Dashboard Signal Grammar")
struct SignalGrammarDashboardTests {
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

    @Test("Dashboard provenance maps to stable branded glyphs")
    func provenanceGlyphs() {
        #expect(DashboardBrandAppearance.glyph(for: .default) == .dashboard)
        #expect(DashboardBrandAppearance.glyph(for: .template) == .generatedDashboard)
        #expect(DashboardBrandAppearance.glyph(for: .duplicate) == .dashboard)
        #expect(DashboardBrandAppearance.glyph(for: .unknown) == .dashboard)
    }
}
