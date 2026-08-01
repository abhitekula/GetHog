import SwiftUI
import Testing

@testable import GetHog

@Suite("Signal Grammar components")
@MainActor
struct SignalGrammarComponentTests {
    @Test("Every object glyph renders", arguments: BrandObjectGlyph.allCases)
    func objectGlyphRenders(_ glyph: BrandObjectGlyph) {
        let renderer = ImageRenderer(
            content: BrandObjectGlyphView(glyph: glyph, size: 24)
        )
        #expect(renderer.uiImage != nil)
    }

    @Test("Legacy and branded rows both render")
    func rowFallbacksRender() {
        let legacy = ImageRenderer(content: DataRow(glyph: "bolt", title: "Legacy"))
        let branded = ImageRenderer(content: DataRow(
            glyph: "bolt",
            brandGlyph: .event,
            title: "Branded"
        ))
        #expect(legacy.uiImage != nil)
        #expect(branded.uiImage != nil)
    }

    @Test("Section labels and card headers remain opt-in")
    func passiveChromeRenders() {
        #expect(ImageRenderer(content: SectionLabel(text: "Plain")).uiImage != nil)
        #expect(ImageRenderer(content: SectionLabel(
            text: "Events",
            productMark: .event
        )).uiImage != nil)
        #expect(ImageRenderer(content: CardHeader(
            title: "Daily active people",
            showsBrandStitch: true
        )).uiImage != nil)
    }
}
