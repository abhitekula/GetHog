import Foundation
import Testing

@testable import GetHogKit

// Authored saved-heatmap payload for synthetic project 1001. It preserves the
// contract's two identifiers for one object because the detail and content
// endpoints deliberately require different identifiers.

private let savedListJSON = """
{
  "results": [
    {
      "id": "018f7e00-0000-7000-8000-000000000003",
      "short_id": "heat0001",
      "name": "New heatmap",
      "url": "https://example.com/",
      "data_url": "https://example.com/",
      "target_widths": [320, 375, 425, 768, 1024, 1440, 1920],
      "type": "screenshot",
      "status": "completed",
      "has_content": true,
      "snapshots": [
        {"width": 320, "has_content": true},
        {"width": 375, "has_content": true},
        {"width": 425, "has_content": true},
        {"width": 768, "has_content": true},
        {"width": 1024, "has_content": true},
        {"width": 1440, "has_content": true},
        {"width": 1920, "has_content": true}
      ],
      "deleted": false,
      "created_at": "2026-05-15T18:14:15.733186Z",
      "updated_at": "2026-05-15T18:16:25.532522Z",
      "exception": null
    }
  ],
  "count": 1
}
"""

@Suite("Saved heatmap renders")
struct SavedHeatmapDecodingTests {

    private func sole() throws -> SavedHeatmap {
        let page = try Page<SavedHeatmap>.decode(from: Data(savedListJSON.utf8))
        return try #require(page.results.first)
    }

    @Test("keeps the UUID and the short id apart")
    func twoIdentifiers() throws {
        let saved = try sole()
        // The list is the only place both appear, and the app needs both: the
        // detail route is keyed by `short_id`, the image route by `id`. Reading
        // one where the other is wanted 404s.
        #expect(saved.id == "018f7e00-0000-7000-8000-000000000003")
        #expect(saved.shortID == "heat0001")
        #expect(saved.id != saved.shortID)
    }

    @Test("decodes the render's state and page")
    func fields() throws {
        let saved = try sole()
        #expect(saved.url == "https://example.com/")
        #expect(saved.name == "New heatmap")
        #expect(saved.type == "screenshot")
        #expect(saved.status == "completed")
        #expect(saved.targetWidths == [320, 375, 425, 768, 1024, 1440, 1920])
        #expect(saved.snapshots.count == 7)
        #expect(saved.updatedAt != nil)
    }

    @Test("a half-finished render is not renderable")
    func renderability() throws {
        #expect(try sole().isRenderable)

        // `status` and `has_content` move independently: a render is requested,
        // then produced. Overlaying clicks on a page that has not been drawn yet
        // would show them against nothing.
        #expect(!SavedHeatmap.stub(status: "processing").isRenderable)
        #expect(!SavedHeatmap.stub(status: "failed").isRenderable)
        // 'iframe' and 'recording' saves carry no image of their own.
        #expect(!SavedHeatmap.stub(type: "iframe").isRenderable)
        #expect(!SavedHeatmap.stub(snapshots: []).isRenderable)
    }

    @Test("offers only the widths that actually have an image")
    func availableWidths() {
        let partial = SavedHeatmap.stub(
            snapshots: [
                .init(width: 320, hasContent: true),
                .init(width: 375, hasContent: false),
                .init(width: 425, hasContent: true),
            ]
        )
        // `target_widths` is what was asked for; `snapshots[].has_content` is
        // what exists. Requesting a width from the first list that is missing
        // from the second is a request for an image the API has not got.
        #expect(partial.renderedWidths == [320, 425])
    }

    @Test("falls back to the requested widths when the API sends no snapshots")
    func widthsFallback() {
        let saved = SavedHeatmap.stub(targetWidths: [375, 1024], snapshots: [])
        #expect(saved.renderedWidths.isEmpty)
        #expect(!saved.isRenderable)
    }
}

@Suite("Choosing a render width")
struct SavedHeatmapWidthTests {

    private let widths = [320, 375, 425, 768, 1024, 1440, 1920]

    private func saved() -> SavedHeatmap {
        SavedHeatmap.stub(
            targetWidths: widths,
            snapshots: widths.map { .init(width: $0, hasContent: true) }
        )
    }

    @Test("picks the render nearest the width it will actually be drawn at")
    func nearest() {
        let saved = saved()
        // Hard-coding 375 was the tempting shortcut and it is wrong on every
        // current device: an iPhone 17 lays this out at 402 pt and an iPad far
        // wider, and a 375-wide render stretched to either is both blurry and a
        // different page layout than the one the clicks were recorded against.
        #expect(saved.renderWidth(nearest: 402) == 425)
        #expect(saved.renderWidth(nearest: 393) == 375)
        #expect(saved.renderWidth(nearest: 834) == 768)
        #expect(saved.renderWidth(nearest: 1210) == 1024)
        // Past both ends it clamps rather than returning nothing.
        #expect(saved.renderWidth(nearest: 100) == 320)
        #expect(saved.renderWidth(nearest: 4000) == 1920)
    }

    @Test("breaks an exact tie towards the wider render")
    func tieBreak() {
        let saved = SavedHeatmap.stub(
            targetWidths: [400, 500],
            snapshots: [.init(width: 400, hasContent: true), .init(width: 500, hasContent: true)]
        )
        // 450 is equidistant. The wider render downscales into the space; the
        // narrower one has to be stretched, which softens it and misplaces
        // nothing but looks like a defect.
        #expect(saved.renderWidth(nearest: 450) == 500)
    }

    @Test("never offers a width whose image is missing")
    func skipsEmptyWidths() {
        let saved = SavedHeatmap.stub(
            snapshots: [
                .init(width: 320, hasContent: true),
                .init(width: 425, hasContent: false),
                .init(width: 1024, hasContent: true),
            ]
        )
        #expect(saved.renderWidth(nearest: 420) == 320)
        #expect(SavedHeatmap.stub(snapshots: []).renderWidth(nearest: 400) == nil)
    }
}

@Suite("Viewport band for an overlay")
struct SavedHeatmapViewportBandTests {

    private let widths = [320, 375, 425, 768, 1024, 1440, 1920]

    private func saved() -> SavedHeatmap {
        SavedHeatmap.stub(
            targetWidths: widths,
            snapshots: widths.map { .init(width: $0, hasContent: true) }
        )
    }

    @Test("spans halfway to each neighbouring render")
    func midpoints() {
        // `pointer_y` is absolute pixels down the document, and how far down the
        // document anything sits depends on how wide the viewport was. Painting
        // every recorded click onto one width's render therefore puts clicks
        // from a 1,920 px desktop somewhere arbitrary on a 425 px phone page.
        // The bands assign each recorded viewport to the render nearest it, so
        // every click is drawn exactly once and against its closest layout.
        let band = saved().viewportBand(for: 425)
        #expect(band.min == 400)   // midpoint with 375
        #expect(band.max == 596)   // midpoint with 768
    }

    @Test("leaves the outermost bands open-ended")
    func openEnds() {
        // Clamping the narrowest band at 320 would silently drop every visitor
        // on a smaller viewport, and clamping the widest would drop every
        // ultrawide monitor. Both are still nearest to their end render.
        let narrow = saved().viewportBand(for: 320)
        #expect(narrow.min == nil)
        #expect(narrow.max == 347)

        let wide = saved().viewportBand(for: 1920)
        #expect(wide.min == 1680)
        #expect(wide.max == nil)
    }

    @Test("a lone render claims every viewport")
    func singleWidth() {
        let saved = SavedHeatmap.stub(
            targetWidths: [375],
            snapshots: [.init(width: 375, hasContent: true)]
        )
        let band = saved.viewportBand(for: 375)
        #expect(band.min == nil)
        #expect(band.max == nil)
    }

    @Test("an unrendered width gets no band at all")
    func unknownWidth() {
        let band = saved().viewportBand(for: 999)
        #expect(band.min == nil)
        #expect(band.max == nil)
    }
}

@Suite("Heatmap screenshot endpoints")
struct HeatmapScreenshotEndpointTests {

    @Test("lists saved renders off the CRUD budget, not the analytics one")
    func savedList() {
        let endpoint = PostHogAPI.savedHeatmaps(projectID: 1_001)

        // `/saved/` at the project root, as documented by the current endpoint.
        // The expectation pins the public route without retaining a tenant
        // response.
        #expect(endpoint.path == "/api/projects/1001/saved/")
        #expect(endpoint.method == "GET")
        // This reads a stored record, not aggregated event data. Spending the
        // analytics allowance on it would take slots from the click queries that
        // genuinely need them — the budget is organisation-wide.
        #expect(endpoint.category == .crud)
    }

    @Test("addresses a single saved render by short id")
    func savedDetail() {
        let endpoint = PostHogAPI.savedHeatmap(projectID: 1_001, shortID: "heat0001")
        // The `short_id`, never the UUID: this route is the human-facing one and
        // does not resolve the `id` the sibling content route requires.
        #expect(endpoint.path == "/api/projects/1001/saved/heat0001/")
    }

    @Test("addresses the image by UUID, and always names a width")
    func content() {
        let endpoint = PostHogAPI.heatmapScreenshotContent(
            projectID: 1_001,
            screenshotID: "018f7e00-0000-7000-8000-000000000003",
            width: 425
        )
        // The UUID, not the short id — the mirror image of the route above, and
        // the single easiest thing to get backwards in this feature.
        #expect(
            endpoint.path
                == "/api/projects/1001/heatmap_screenshots/018f7e00-0000-7000-8000-000000000003/content/"
        )
        #expect(endpoint.query.contains { $0.name == "width" && $0.value == "425" })
        #expect(endpoint.category == .crud)
    }

    @Test("narrows clicks to the viewports a given render represents")
    func heatmapViewportFilter() {
        let endpoint = PostHogAPI.heatmap(
            projectID: 1,
            urlExact: "https://example.com/",
            viewportWidthMin: 400,
            viewportWidthMax: 596
        )
        #expect(endpoint.query.contains { $0.name == "viewport_width_min" && $0.value == "400" })
        #expect(endpoint.query.contains { $0.name == "viewport_width_max" && $0.value == "596" })
        #expect(endpoint.query.contains { $0.name == "url_exact" })
    }

    @Test("omits the viewport filter when the caller wants every width")
    func heatmapNoViewportFilter() {
        // The existing numbers-only clickmap deliberately aggregates every
        // viewport; adding a default band here would silently change what that
        // screen has always reported.
        let endpoint = PostHogAPI.heatmap(projectID: 1)
        #expect(!endpoint.query.contains { $0.name.hasPrefix("viewport_width") })
    }
}

// MARK: - Stub

extension SavedHeatmap {
    fileprivate static func stub(
        id: String = "uuid",
        shortID: String = "short",
        url: String = "https://example.com/",
        type: String = "screenshot",
        status: String = "completed",
        targetWidths: [Int] = [320, 375, 425],
        snapshots: [SavedHeatmapSnapshot] = [
            .init(width: 320, hasContent: true),
            .init(width: 375, hasContent: true),
            .init(width: 425, hasContent: true),
        ]
    ) -> SavedHeatmap {
        SavedHeatmap(
            id: id,
            shortID: shortID,
            name: nil,
            url: url,
            type: type,
            status: status,
            targetWidths: targetWidths,
            snapshots: snapshots,
            updatedAt: nil,
            exception: nil
        )
    }
}
