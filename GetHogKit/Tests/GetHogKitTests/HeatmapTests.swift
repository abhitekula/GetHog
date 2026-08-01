import Foundation
import Testing

@testable import GetHogKit

// Heatmaps and element stats are the two halves of a clickmap. Both fixtures
// are authored for synthetic project 1001 and retain the endpoint's less-obvious
// envelope, coordinate, and ancestor-chain shapes.

@Suite("Clickmap endpoints")
struct ClickmapEndpointTests {

    @Test("builds the heatmap endpoint against the shared analytics budget")
    func heatmapEndpoint() {
        let endpoint = PostHogAPI.heatmap(projectID: 1_001)

        #expect(endpoint.path == "/api/projects/1001/heatmaps/")
        #expect(endpoint.method == "GET")
        #expect(endpoint.category == .analytics)
        #expect(endpoint.query.contains { $0.name == "date_from" && $0.value == "-7d" })
        #expect(endpoint.query.contains { $0.name == "type" && $0.value == "click" })
        // Clicks at the origin are instrumentation noise, not a hotspot in the
        // top-left corner of every page in the project.
        #expect(endpoint.query.contains { $0.name == "hide_zero_coordinates" && $0.value == "true" })
        // No URL filter means "every page", which is the only thing that makes
        // sense with no screenshot to overlay.
        #expect(!endpoint.query.contains { $0.name == "url_exact" })
    }

    @Test("adds a page filter only when one was asked for")
    func heatmapURLFilter() {
        let endpoint = PostHogAPI.heatmap(projectID: 1_001, urlExact: "https://example.com/pricing")
        #expect(endpoint.query.contains {
            $0.name == "url_exact" && $0.value == "https://example.com/pricing"
        })
        #expect(!PostHogAPI.heatmap(projectID: 1_001, urlExact: "").query.contains {
            $0.name == "url_exact"
        })
    }

    @Test("fetches every click type in one request rather than one per filter")
    func elementStatsEndpoint() {
        let endpoint = PostHogAPI.elementStats(projectID: 1_001)

        #expect(endpoint.path == "/api/projects/1001/elements/stats/")
        #expect(endpoint.category == .analytics)
        // Omitting `include` returns autocapture, rage and dead clicks together.
        // Requesting them separately would spend three requests out of a
        // rate-limit budget shared with the user's other integrations.
        #expect(!endpoint.query.contains { $0.name == "include" })
        #expect(endpoint.query.contains { $0.name == "offset" && $0.value == "0" })
    }

    @Test("repeats the include parameter when a caller does narrow it")
    func elementStatsInclude() {
        let endpoint = PostHogAPI.elementStats(
            projectID: 1_001,
            include: ElementClickKind.requestableTypes
        )
        let included = endpoint.query.filter { $0.name == "include" }.compactMap(\.value)
        #expect(included == ["$autocapture", "$rageclick", "$dead_click"])
    }
}

@Suite("Heatmap points")
struct HeatmapPointTests {

    // This authored fixture deliberately reports more distinct positions in
    // `fold` than it includes as rows, preserving the endpoint's two different
    // units: position counts in the summary and click counts in each row.

    @Test("decodes an envelope with no count or next, but with fold and has_more")
    func decodesEnvelope() throws {
        // `/heatmaps/` is not a paginated collection: no `count`, no `next`.
        // `Page` reads it because its `count` is optional — but `Page` also
        // silently discards `fold` and `has_more`, which is why this endpoint
        // gets its own response type.
        let page = try Page<HeatmapPoint>.decode(from: Fixture.data("heatmap_clicks.json"))
        #expect(page.count == nil)
        #expect(page.next == nil)
        #expect(page.results.count == 41)

        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_clicks.json"))
        #expect(response.results.count == 41)
        #expect(!response.hasMore)

        let fold = try #require(response.fold)
        #expect(fold.totalCount == 120)
        #expect(fold.belowFoldCount == 36)
        // Sent as a percentage, not a fraction: 30 means 30%.
        #expect(abs(fold.pctBelowFold - 30.0) < 0.0001)
        #expect(abs(fold.belowFoldShare - 0.3) < 0.0001)
        #expect(fold.medianViewportHeight == 900)

        // `below_fold_count / total_count` reproduces the percentage exactly, so
        // all three fields count the same thing — positions. They are not click
        // counts: these 41 rows carry 3,240 clicks while the summary reports
        // 120 positions.
        let impliedShare = Double(fold.belowFoldCount) / Double(fold.totalCount)
        #expect(abs(impliedShare - fold.belowFoldShare) < 0.001)
    }

    @Test("keeps a fold block that omits the viewport height")
    func foldWithoutHeight() throws {
        let json = """
        {"results": [], "fold": {"total_count": 12, "below_fold_count": 3, "pct_below_fold": 25.0}}
        """
        let response = try HeatmapResponse.decode(from: Data(json.utf8))
        let fold = try #require(response.fold)

        #expect(fold.totalCount == 12)
        #expect(fold.medianViewportHeight == nil)
    }

    @Test("treats a fold-less response as complete rather than guessing")
    func missingFold() throws {
        let json = #"{"results": [{"count": 5, "pointer_y": 10, "pointer_relative_x": 0.5}]}"#
        let response = try HeatmapResponse.decode(from: Data(json.utf8))

        #expect(response.fold == nil)
        #expect(response.hasMore == false)
    }

    @Test("x is relative and y is absolute, and the model keeps them apart")
    func axesAreAsymmetric() throws {
        // The asymmetry is deliberate on PostHog's side: page width varies with
        // the viewport so x is normalised, while scroll depth does not so y stays
        // in pixels. Treating them alike would silently mangle one of them.
        let page = try Page<HeatmapPoint>.decode(from: Fixture.data("heatmap_clicks.json"))
        let first = try #require(page.results.first)

        #expect(first.count == 99)
        #expect(first.pointerY == 125)
        #expect(abs(first.pointerRelativeX - 0.103) < 0.0001)
        #expect(!first.isTargetFixed)
        #expect(page.results.allSatisfy { (0...1).contains($0.pointerRelativeX) })
    }

    @Test("tolerates missing fields rather than dropping the whole page")
    func tolerantDecoding() throws {
        let json = #"{"results": [{"count": 3}, {}]}"#
        let page = try Page<HeatmapPoint>.decode(from: Data(json.utf8))

        #expect(page.results.count == 2)
        #expect(page.results[0].count == 3)
        #expect(page.results[0].pointerY == 0)
        #expect(page.results[0].isTargetFixed == false)
    }
}

@Suite("Scroll depth banding")
struct HeatmapProfileTests {

    private func point(y: Int, x: Double = 0.5, count: Int, fixed: Bool = false) -> HeatmapPoint {
        HeatmapPoint(count: count, pointerY: y, pointerRelativeX: x, isTargetFixed: fixed)
    }

    @Test("buckets clicks into contiguous bands, including the empty ones")
    func contiguousBands() {
        let profile = HeatmapProfile.make(
            points: [point(y: 20, count: 5), point(y: 250, count: 3)],
            bandSize: 100
        )

        // A depth axis with holes punched out of it reads as if nobody scrolled
        // past 100px, so the gap band is present and explicitly zero.
        #expect(profile.depthBands.map(\.start) == [0, 100, 200])
        #expect(profile.depthBands.map(\.clicks) == [5, 0, 3])
    }

    @Test("keeps fixed-position clicks out of the depth profile")
    func fixedClicksExcluded() {
        // `pointer_target_fixed` marks a sticky nav or footer. Its y is a screen
        // position, not a scroll depth, so averaging it into the depth profile
        // invents a hotspot at whatever height the nav happens to sit.
        let profile = HeatmapProfile.make(
            points: [
                point(y: 40, count: 10, fixed: true),
                point(y: 40, count: 4),
            ],
            bandSize: 100
        )

        #expect(profile.depthBands.map(\.clicks) == [4])
        #expect(profile.scrollableClicks == 4)
        #expect(profile.fixedClicks == 10)
        #expect(profile.sampledClicks == 14)
    }

    @Test("widens the band so a very tall page stays readable")
    func widensBands() {
        // 100px bands over a 20,000px page is 200 rows nobody will scroll. The
        // band grows to a multiple of the requested size instead of truncating
        // the page, because truncation would hide the deepest clicks entirely.
        let profile = HeatmapProfile.make(
            points: [point(y: 0, count: 1), point(y: 19_999, count: 1)],
            bandSize: 100,
            maxBands: 40
        )

        #expect(profile.bandSize == 500)
        #expect(profile.depthBands.count == 40)
        #expect(profile.depthBands.last?.clicks == 1)
    }

    @Test("clamps a negative y into the first band instead of dropping it")
    func negativeY() {
        let profile = HeatmapProfile.make(points: [point(y: -30, count: 2)], bandSize: 100)
        #expect(profile.depthBands.map(\.clicks) == [2])
    }

    @Test("splits horizontal position into columns with 1.0 in the last one")
    func horizontalColumns() {
        // `pointer_relative_x` is inclusive of 1.0, so the naive `x * columns`
        // index produces an eleventh column containing the right-hand edge.
        let profile = HeatmapProfile.make(
            points: [
                point(y: 10, x: 0.0, count: 1),
                point(y: 10, x: 0.55, count: 2),
                point(y: 10, x: 1.0, count: 4),
            ],
            columnCount: 10
        )

        #expect(profile.horizontalBands.count == 10)
        #expect(profile.horizontalBands[0].clicks == 1)
        #expect(profile.horizontalBands[5].clicks == 2)
        #expect(profile.horizontalBands[9].clicks == 4)
    }

    @Test("counts fixed clicks in the horizontal profile")
    func horizontalIncludesFixed() {
        // Left/right bias is a real question for a sticky header too, unlike
        // scroll depth, so the horizontal profile keeps every point.
        let profile = HeatmapProfile.make(
            points: [point(y: 10, x: 0.05, count: 3, fixed: true)],
            columnCount: 10
        )
        #expect(profile.horizontalBands[0].clicks == 3)
        #expect(profile.horizontalTotal == 3)
    }

    @Test("profiles the synthetic project without inventing depth from fixed controls")
    func syntheticPayload() throws {
        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_clicks.json"))
        let profile = HeatmapProfile.make(response)

        // Six authored points are fixed controls. Their 467 clicks remain in
        // the horizontal profile but never create fictional scroll depth.
        #expect(profile.scrollableClicks == 2_773)
        #expect(profile.fixedClicks == 467)
        #expect(profile.peakDepthBand?.start == 600)
        #expect(profile.peakDepthBand?.clicks == 279)
        #expect(profile.peakHorizontalClicks > 0)
    }

    @Test("reports empty rather than a single zero band")
    func empty() {
        let profile = HeatmapProfile.make(points: [])
        #expect(profile.isEmpty)
        #expect(profile.depthBands.isEmpty)
        #expect(profile.horizontalBands.isEmpty)
    }

    @Test("still reports fixed clicks when nothing is scroll-positioned")
    func onlyFixed() {
        // The depth chart has nothing to draw, but saying "no clicks" would be a
        // lie — the screen must be able to say "all of them were on fixed UI".
        let profile = HeatmapProfile.make(points: [point(y: 40, count: 9, fixed: true)])
        #expect(profile.depthBands.isEmpty)
        #expect(profile.fixedClicks == 9)
        #expect(!profile.isEmpty)
    }

    @Test("labels bands in pixels, which is the unit the API reports")
    func bandLabels() {
        let profile = HeatmapProfile.make(points: [point(y: 150, count: 1)], bandSize: 100)
        #expect(profile.depthBands.last?.label == "100–200")
        #expect(profile.depthBands.last?.spokenLabel == "100 to 200 pixels")
        #expect(profile.horizontalBands.first?.label == "0–10%")
    }
}

@Suite("Truncated heatmap samples")
struct HeatmapTruncationTests {

    @Test("counts clicks from the rows and positions from the fold, never mixed")
    func clicksAndPositionsAreDifferentUnits() throws {
        // The trap: `fold.total_count` looks like a click total and is not. The
        // The 41 authored positions carry 3,240 clicks, while `fold` reports
        // 120 *positions*. Treating the latter as clicks mixes the units.
        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_clicks.json"))
        let profile = HeatmapProfile.make(response)

        #expect(profile.sampledClicks == 3_240)
        #expect(profile.sampledPositions == 41)
        #expect(profile.reportedPositions == 120)
    }

    @Test("says what the click figure spans without claiming a total")
    func coverageNote() throws {
        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_clicks.json"))
        let profile = HeatmapProfile.make(response)

        #expect(!profile.isTruncated)
        #expect(!profile.isSampleComplete)
        #expect(profile.coverageNote == "Across the 41 hottest positions, of 120 recorded.")
    }

    @Test("says so plainly when the response held everything")
    func completeSample() {
        let profile = HeatmapProfile.make(
            points: [HeatmapPoint(count: 12, pointerY: 10, pointerRelativeX: 0.5, isTargetFixed: false)],
            fold: HeatmapFold(
                totalCount: 1, belowFoldCount: 0, pctBelowFold: 0, medianViewportHeight: 800
            ),
            isTruncated: false
        )

        #expect(profile.isSampleComplete)
        #expect(profile.coverageNote == "Across all 1 recorded positions.")
    }

    @Test("admits a cap it cannot size when the response omits the fold")
    func truncatedWithoutFold() {
        let profile = HeatmapProfile.make(
            points: [HeatmapPoint(count: 4, pointerY: 10, pointerRelativeX: 0.5, isTargetFixed: false)],
            isTruncated: true
        )

        #expect(profile.reportedPositions == nil)
        #expect(profile.coverageNote == "Across the 1 hottest positions; PostHog had more.")
    }

    @Test("still warns when has_more is set even if the position counts agree")
    func truncatedDespiteMatchingCounts() {
        // `has_more` is the endpoint's own word for "there was more"; a matching
        // count is not permission to overrule it.
        let profile = HeatmapProfile.make(
            points: [HeatmapPoint(count: 12, pointerY: 10, pointerRelativeX: 0.5, isTargetFixed: false)],
            fold: HeatmapFold(
                totalCount: 1, belowFoldCount: 0, pctBelowFold: 0, medianViewportHeight: 800
            ),
            isTruncated: true
        )

        #expect(!profile.isSampleComplete)
        #expect(profile.coverageNote.contains("hottest"))
    }

    @Test("never derives the below-fold share from the biased sample")
    func belowFoldShareIsNotRecomputable() throws {
        // Rows arrive hottest-first and hot positions cluster near the top, so
        // the sample's own below-fold share is far lower than the truth. This
        // pins the gap so nobody later "simplifies" the card by computing it
        // from the rows.
        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_deep_tail.json"))
        let fold = try #require(response.fold)

        #expect(response.results.contains { $0.pointerRelativeX == 1 })

        let sampledBelowFold = response.results.filter {
            !$0.isTargetFixed && $0.pointerY > (fold.medianViewportHeight ?? 0)
        }
        let sampledShare = Double(sampledBelowFold.count) / Double(response.results.count)

        #expect(abs(fold.belowFoldShare - 0.4) < 0.001)
        #expect(sampledShare != fold.belowFoldShare)
    }

    @Test("places the median fold line in the band that contains it")
    func foldBand() throws {
        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_clicks.json"))
        let profile = HeatmapProfile.make(response)

        // Median viewport height is 900px. The authored distribution widens
        // the phone-readable axis to 300px bands, so the fold lands here.
        #expect(profile.foldBandLabel == "900–1200")
    }

    @Test("draws no fold line when the response reported no viewport height")
    func noFoldLine() {
        let profile = HeatmapProfile.make(
            points: [HeatmapPoint(count: 1, pointerY: 50, pointerRelativeX: 0.5, isTargetFixed: false)],
            fold: HeatmapFold(
                totalCount: 1, belowFoldCount: 0, pctBelowFold: 0, medianViewportHeight: nil
            )
        )
        #expect(profile.foldBandLabel == nil)
    }

    @Test("extends the depth axis to the fold when every click is above it")
    func axisReachesTheFold() {
        // Nobody clicked below 50px, but the fold sits at 800. Stopping the axis
        // at the deepest click would hide the actual finding — that the whole
        // click distribution fits on the first screen.
        let profile = HeatmapProfile.make(
            points: [HeatmapPoint(count: 1, pointerY: 50, pointerRelativeX: 0.5, isTargetFixed: false)],
            fold: HeatmapFold(
                totalCount: 1, belowFoldCount: 0, pctBelowFold: 0, medianViewportHeight: 800
            )
        )

        #expect(profile.depthBands.count == 9)
        #expect(profile.foldBandLabel == "800–900")
        #expect(profile.depthBands.last?.clicks == 0)
    }

    @Test("does not extend the axis for a project with no clicks at all")
    func noExtensionWithoutClicks() {
        let profile = HeatmapProfile.make(
            points: [],
            fold: HeatmapFold(
                totalCount: 0, belowFoldCount: 0, pctBelowFold: 0, medianViewportHeight: 800
            )
        )
        #expect(profile.depthBands.isEmpty)
        #expect(profile.foldBandLabel == nil)
    }

    @Test("keeps the fixed-click share pinned to the sample it was counted from")
    func fixedShareIsSampleScoped() throws {
        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_clicks.json"))
        let profile = HeatmapProfile.make(response)

        // 467 of 3,180 sampled clicks, not 467 of the 120 reported positions.
        #expect(abs(profile.fixedShare - 467.0 / 3_240.0) < 0.0001)
    }
}

@Suite("Depth axis on a synthetic long tail")
struct HeatmapDeepTailTests {

    // This hand-authored distribution keeps two low-volume deep outliers so the
    // chart must aggregate the tail without copying any tenant's behavior.

    private func profile() throws -> HeatmapProfile {
        HeatmapProfile.make(
            try HeatmapResponse.decode(from: Fixture.data("heatmap_deep_tail.json"))
        )
    }

    @Test("refuses to let two deep clicks set the scale for the whole page")
    func outlierDoesNotSetTheScale() throws {
        let profile = try profile()

        #expect(profile.depthBands.contains { $0.start > 12_000 } == false)
        #expect(profile.bandSize == 300)
        #expect(profile.depthBands.count == 11)
    }

    @Test("keeps the band count inside what a phone can show")
    func boundedBandCount() throws {
        let profile = try profile()
        // At most `maxBands` real bands plus the one overflow row.
        #expect(profile.depthBands.filter { !$0.isOverflow }.count <= 14)
        #expect(profile.depthBands.count <= 15)
    }

    @Test("aggregates the tail into one labelled band instead of dropping it")
    func overflowBandCarriesTheTail() throws {
        let profile = try profile()
        let overflow = try #require(profile.overflowBand)

        #expect(overflow.isOverflow)
        #expect(overflow.start == 3_000)
        #expect(overflow.label == "3000+")
        #expect(overflow.spokenLabel == "3000 pixels and deeper")
        // Both deep positions remain counted without stretching the axis.
        #expect(overflow.clicks == 38)

        // Nothing is lost: every scroll-positioned click is in some band.
        #expect(profile.depthBands.reduce(0) { $0 + $1.clicks } == profile.scrollableClicks)
    }

    @Test("does not put the fold line inside the catch-all band")
    func foldLineAvoidsOverflow() throws {
        let profile = try profile()
        // 950 px median fold, 300 px bands: the line belongs on 900–1200.
        #expect(profile.foldBandLabel == "900–1200")
        #expect(profile.overflowBand?.label != profile.foldBandLabel)
    }

    @Test("adds no overflow row when the tail already fits")
    func noOverflowWhenUnnecessary() {
        let profile = HeatmapProfile.make(
            points: [
                HeatmapPoint(count: 5, pointerY: 20, pointerRelativeX: 0.5, isTargetFixed: false),
                HeatmapPoint(count: 3, pointerY: 250, pointerRelativeX: 0.5, isTargetFixed: false),
            ],
            bandSize: 100
        )
        #expect(profile.overflowBand == nil)
        #expect(profile.depthBands.allSatisfy { !$0.isOverflow })
    }

    @Test("produces a phone-readable axis from an authored depth distribution")
    func syntheticDistributionIsReadable() throws {
        // This fixture records only `count` and `pointer_y`, because those are
        // the fields the depth profile consumes. Omitting horizontal position
        // avoids inventing a second distribution just to fill a field.
        let response = try HeatmapResponse.decode(from: Fixture.data("heatmap_live_depth.json"))
        let profile = HeatmapProfile.make(response)

        #expect(profile.scrollableClicks == 720)

        #expect(profile.bandSize == 600)
        #expect(profile.depthBands.count == 13)
        #expect(profile.depthBands.map(\.clicks)
            == [250, 200, 100, 86, 14, 14, 0, 14, 0, 0, 0, 14, 28])

        let overflow = try #require(profile.overflowBand)
        #expect(overflow.start == 7_200)
        // Under 5% of clicks pooled — the tail really is that thin.
        #expect(Double(overflow.clicks) / Double(profile.scrollableClicks) < 0.05)

        #expect(profile.peakDepthBand?.start == 0)
        #expect(profile.foldBandLabel == "600–1200")
    }

    @Test("reports clicks and positions separately for the long-tail fixture")
    func unitsStaySeparate() throws {
        let profile = try profile()

        #expect(profile.sampledClicks == 1_518)
        #expect(profile.sampledPositions == 18)
        #expect(profile.reportedPositions == 180)
        #expect(profile.coverageNote == "Across the 18 hottest positions, of 180 recorded.")
    }
}

@Suite("Element click stats")
struct ElementStatTests {

    @Test("decodes the results envelope and its ancestor chains")
    func decodesEnvelope() throws {
        let page = try Page<ElementStat>.decode(from: Fixture.data("element_stats.json"))

        // No `count`, but `next` is present as a reserved-host continuation URL.
        #expect(page.count == nil)
        #expect(page.next == "https://app.example.com/api/projects/1001/elements/stats/?limit=2&offset=2")
        #expect(page.results.count == 3)

        let first = try #require(page.results.first)
        #expect(first.count == 64)
        #expect(first.hash == "018f1000-0000-7000-8000-000000000201")
        #expect(first.elements.count == 7)
    }

    @Test("treats order 0 as the clicked element, not the outermost ancestor")
    func orderZeroIsTheTarget() throws {
        let page = try Page<ElementStat>.decode(from: Fixture.data("element_stats.json"))
        let first = try #require(page.results.first)

        #expect(first.target?.tagName == "svg")
        #expect(first.target?.order == 0)
        // …and the chain really does run outward from it.
        #expect(first.elements.last?.tagName == "html")
    }

    @Test("separates autocapture from dead and rage clicks")
    func clickKinds() throws {
        let page = try Page<ElementStat>.decode(from: Fixture.data("element_stats.json"))

        #expect(page.results[0].kind == .autocapture)
        // The endpoint mixes `$dead_click` and `$rageclick` rows into the same
        // list. Ranking
        // them together as "most clicked" would claim engagement for a click
        // that did nothing at all.
        #expect(page.results[1].kind == .deadClick)
        #expect(ElementClickKind(eventType: "$rageclick") == .rageClick)
        #expect(ElementClickKind(eventType: "$pageview") == .other)
        #expect(ElementClickKind(eventType: nil) == .other)
    }

    @Test("prefers text, then aria-label, then href, then a selector")
    func labelPrecedence() {
        // The fixture's main targets carry no text or link, so this inline shape
        // pins the complete precedence ladder.
        let json = """
        {"results": [
          {"count": 9, "type": "$autocapture", "elements": [
            {"order": 0, "tag_name": "a", "text": "  Example\\n pricing  ",
             "href": "https://example.com/x", "attributes": {"attr__aria-label": "ignored"}}]},
          {"count": 8, "type": "$autocapture", "elements": [
            {"order": 0, "tag_name": "button", "text": null,
             "href": "https://example.com/y", "attributes": {"attr__aria-label": "Dismiss"}}]},
          {"count": 7, "type": "$autocapture", "elements": [
            {"order": 0, "tag_name": "a", "text": "", "href": "https://example.com/z",
             "attributes": {}}]},
          {"count": 6, "type": "$autocapture", "elements": [
            {"order": 0, "tag_name": "div", "attr_id": "hero",
             "attr_class": ["card", "wide"], "attributes": {}}]}
        ]}
        """
        let page = try! Page<ElementStat>.decode(from: Data(json.utf8))

        // Whitespace and newlines inside element text are common and would
        // otherwise blow a list row's height out.
        #expect(page.results[0].label == "Example pricing")
        #expect(page.results[1].label == "Dismiss")
        #expect(page.results[2].label == "https://example.com/z")
        #expect(page.results[3].label == "div#hero.card")
    }

    @Test("falls back to a bare tag when the element carries nothing at all")
    func bareTag() {
        let json = #"{"results": [{"count": 1, "elements": [{"order": 0, "tag_name": "span"}]}]}"#
        let page = try! Page<ElementStat>.decode(from: Data(json.utf8))
        #expect(page.results[0].label == "span")
    }

    @Test("says so rather than guessing when the chain is empty")
    func emptyChain() {
        let json = #"{"results": [{"count": 1, "elements": []}]}"#
        let page = try! Page<ElementStat>.decode(from: Data(json.utf8))
        #expect(page.results[0].target == nil)
        #expect(page.results[0].label == "Unidentified element")
        #expect(page.results[0].tagName == nil)
    }

    @Test("surfaces the nearest labelled ancestor when the target is anonymous")
    func ancestorLabel() throws {
        let page = try Page<ElementStat>.decode(from: Fixture.data("element_stats.json"))
        let first = try #require(page.results.first)

        // The clicked SVG is anonymous; its nearest labelled button supplies
        // the human-readable action.
        #expect(first.label == "svg.synthetic-icon")
        #expect(first.ancestorLabel == "Open Example App navigation")
    }

    @Test("survives attribute maps mangled by malformed page markup")
    func malformedAttributes() throws {
        let page = try Page<ElementStat>.decode(from: Fixture.data("element_stats.json"))
        let target = try #require(page.results.first?.target)

        // The authored malformed-key case preserves the loose attribute-map
        // contract without retaining page markup from any real application.
        #expect(target.attributes["attr__alt"] == "Synthetic navigation icon")
        #expect(target.attributes.keys.contains { !$0.hasPrefix("attr__") })
        #expect(target.ariaLabel == nil)
    }

    @Test("keeps a null attr_class as no classes rather than failing the row")
    func nullClasses() throws {
        let page = try Page<ElementStat>.decode(from: Fixture.data("element_stats.json"))
        let chain = try #require(page.results.first?.elements)
        let anonymous = try #require(chain.first { $0.order == 3 })

        #expect(anonymous.classes.isEmpty)
        #expect(anonymous.nthChild == nil)
        #expect(anonymous.selector == "section")
    }

    @Test("ranks by count and can be narrowed to one kind of click")
    func ranking() throws {
        let page = try Page<ElementStat>.decode(from: Fixture.data("element_stats.json"))

        #expect(ElementStat.ranked(page.results, kind: nil).map(\.count) == [64, 51, 37])
        #expect(ElementStat.ranked(page.results, kind: .deadClick).map(\.count) == [51])
        #expect(ElementStat.ranked(page.results, kind: .rageClick).isEmpty)
    }
}
