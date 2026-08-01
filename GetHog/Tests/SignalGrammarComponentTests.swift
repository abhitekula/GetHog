import SwiftUI
import Testing
import UIKit

@testable import GetHog

@Suite("Signal Grammar components")
@MainActor
struct SignalGrammarComponentTests {
    private func renderedHeader(
        title: String,
        width: CGFloat,
        showsBrandStitch: Bool
    ) throws -> Data {
        let renderer = ImageRenderer(
            content: CardHeader(
                title: title,
                systemImage: "chart.xyaxis.line",
                showsBrandStitch: showsBrandStitch
            )
            .padding(Theme.Space.m)
            .frame(width: width, alignment: .leading)
            .background(Theme.cardBackground)
            .environment(\.dynamicTypeSize, .large)
        )
        renderer.scale = 3
        return try #require(renderer.uiImage?.pngData())
    }

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

    @Test("A narrow long title gets the same pixels with or without decoration")
    func narrowLongTitleSuppressesDecoration() throws {
        let title = "Weekly engagement by acquisition channel and returning cohort"
        let plain = try renderedHeader(
            title: title,
            width: 220,
            showsBrandStitch: false
        )
        let branded = try renderedHeader(
            title: title,
            width: 220,
            showsBrandStitch: true
        )

        #expect(
            branded == plain,
            "The stitch took pixels from a useful two-line title in a narrow card header."
        )
    }

    @Test("An ordinary-width short title keeps the branded stitch")
    func ordinaryWidthKeepsDecoration() throws {
        let plain = try renderedHeader(
            title: "Weekly engagement",
            width: 360,
            showsBrandStitch: false
        )
        let branded = try renderedHeader(
            title: "Weekly engagement",
            width: 360,
            showsBrandStitch: true
        )

        #expect(
            branded != plain,
            "The stitch disappeared even though the useful title and decoration both fit."
        )
    }
}
