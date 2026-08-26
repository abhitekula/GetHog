import SwiftUI
import Testing
@testable import GetHog

@Suite("Quick Preview core")
struct QuickPreviewCoreTests {
    @Test func accessibilityTypeUsesVerticalFacts() {
        #expect(QuickPreviewLayout.factsAxis(for: .accessibility3) == .vertical)
        #expect(QuickPreviewLayout.factsAxis(for: .large) == .horizontal)
    }

    @Test func staleStateRetainsItsLastValue() {
        let state = QuickPreviewEnrichment.loaded("cached", loadedAt: .distantPast)
            .retainingValueAfterFailure()
        #expect(state.value == "cached")
        #expect(state.statusText == "Refresh failed")
    }
}
