import SwiftUI
import Testing

@testable import GetHog

@Suite("Signal Grammar product marks")
@MainActor
struct BrandProductMarkTests {
    @Test("The vocabulary is closed to the Core Four and Project Stamp")
    func closedVocabulary() {
        #expect(BrandProductMark.allCases == [
            .dashboard, .event, .session, .flag, .projectStamp,
        ])
    }

    @Test("Every mark renders at toolbar, section, and summary sizes")
    func rendersAtIntendedSizes() {
        for mark in BrandProductMark.allCases {
            for size in [14.0, 18.0, 32.0, 72.0] {
                let renderer = ImageRenderer(
                    content: BrandProductMarkView(mark: mark, size: size)
                )
                #expect(renderer.uiImage != nil, "\(mark) failed at \(size)pt")
            }
        }
    }

}
