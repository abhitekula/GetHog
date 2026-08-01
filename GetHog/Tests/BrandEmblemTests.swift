import SwiftUI
import Testing
@testable import GetHog

@Suite("Brand product-family emblems")
@MainActor
struct BrandEmblemTests {
    @Test("Every product-family section has one emblem")
    func everyFamilyMaps() {
        let expected: [(String, BrandEmblem)] = [
            ("Analyze", .analyze),
            ("Monitor", .monitor),
            ("Data", .data),
            ("Experiment", .experiment),
            ("Workspace", .workspace),
        ]

        #expect(AppTab.sections.count == expected.count)
        for (title, emblem) in expected {
            #expect(BrandEmblem(sectionTitle: title) == emblem)
        }
    }

    @Test("Every emblem renders at compact header size", arguments: BrandEmblem.allCases)
    func renders(_ emblem: BrandEmblem) {
        let renderer = ImageRenderer(content: BrandEmblemView(emblem: emblem, size: 16))
        #expect(renderer.uiImage != nil)
    }
}
