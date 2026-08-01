import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Flag Signal Grammar")
@MainActor
struct SignalGrammarFlagTests {
    @Test("Overview facts use true project totals and effective state")
    func overviewFacts() throws {
        let data = Data(#"""
        {"results":[
          {"id":1,"key":"checkout-v2","active":true,"filters":{"groups":[{"rollout_percentage":60}]}},
          {"id":2,"key":"onboarding-copy","active":true,"filters":{"groups":[{"rollout_percentage":100}],"multivariate":{"variants":[{"key":"a","rollout_percentage":50},{"key":"b","rollout_percentage":50}]}}},
          {"id":3,"key":"old-flag","active":false,"archived":true}
        ]}
        """#.utf8)
        let page = try JSONDecoder().decode(Page<FeatureFlag>.self, from: data)
        let store = FlagsStore()
        store.flags = page.results
        let facts = FlagOverviewFacts(store: store)

        #expect(facts.flagCount == 3)
        #expect(facts.enabledCount == 2)
        #expect(facts.multivariateCount == 1)
        #expect(facts.partialRollouts.map(\.key) == ["checkout-v2"])
        #expect(facts.statusCounts[.archived] == 1)
    }

    @Test("Flag kinds map to stable branded glyphs")
    func glyphKinds() {
        #expect(FlagBrandAppearance.glyph(isMultivariate: false, isArchived: false) == .flag)
        #expect(FlagBrandAppearance.glyph(isMultivariate: true, isArchived: false) == .multivariateFlag)
        #expect(FlagBrandAppearance.glyph(isMultivariate: false, isArchived: true) == .archivedFlag)
    }
}
