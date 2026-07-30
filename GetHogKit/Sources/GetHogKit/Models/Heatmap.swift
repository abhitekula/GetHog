import Foundation

// PostHog's web heatmap draws click coordinates over a rendered image of the
// page. That image is fetchable — see `HeatmapScreenshot.swift` — but only for
// URLs somebody saved as a heatmap in the web console, which is a small and
// deliberate subset of a project's pages.
//
// So this file builds the parts of a clickmap that survive with no image at
// all, and they carry the common case: where down the page people click, and
// how far left or right.

// MARK: - Points

/// One aggregated click coordinate from `/api/projects/:id/heatmaps/`.
///
/// The axes are **not symmetric**, and that is the single most important thing
/// about this payload: `pointer_relative_x` is a 0…1 fraction of the viewport
/// width, while `pointer_y` is absolute pixels down the document. PostHog does
/// this because page width changes with the viewport but scroll depth does not.
/// Treating them as the same kind of number silently mangles one of them.
public struct HeatmapPoint: Sendable, Decodable, Hashable {
    /// How many clicks landed on this coordinate. Not a page-size envelope —
    /// the response has no `count` field of its own.
    public let count: Int
    public let pointerY: Int
    public let pointerRelativeX: Double

    /// The click was on a fixed-position element — a sticky nav, a floating
    /// chat bubble, a pinned footer. Its `pointer_y` is a screen position, not a
    /// scroll depth, so it must never be folded into the depth profile.
    public let isTargetFixed: Bool

    enum CodingKeys: String, CodingKey {
        case count
        case pointerY = "pointer_y"
        case pointerRelativeX = "pointer_relative_x"
        case pointerTargetFixed = "pointer_target_fixed"
    }

    public init(count: Int, pointerY: Int, pointerRelativeX: Double, isTargetFixed: Bool) {
        self.count = count
        self.pointerY = pointerY
        self.pointerRelativeX = pointerRelativeX
        self.isTargetFixed = isTargetFixed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        // Decoded as a Double first: the values observed are integral, but a
        // sub-pixel y from a scaled viewport would otherwise fail the whole page.
        pointerY = try c.decodeIfPresent(Double.self, forKey: .pointerY).map { Int($0.rounded()) } ?? 0
        pointerRelativeX = try c.decodeIfPresent(Double.self, forKey: .pointerRelativeX) ?? 0
        isTargetFixed = try c.decodeIfPresent(Bool.self, forKey: .pointerTargetFixed) ?? false
    }
}

// MARK: - Fold summary

/// The `fold` block the heatmaps endpoint returns alongside its coordinates.
///
/// **Everything here counts positions, not clicks.** A result row is one (x, y)
/// position carrying a `count` of the clicks recorded at it, and `fold` is a
/// summary over positions: on the captured project `total_count` is 900 while
/// the 500 returned positions carry 1,354 clicks between them. Reading
/// `total_count` as a click total understates reality by a factor of one and a
/// half and contradicts the rows on the same screen.
public struct HeatmapFold: Sendable, Decodable, Hashable {
    /// Distinct click **positions** recorded in the window, including the ones
    /// `limit` kept out of `results`.
    public let totalCount: Int

    /// Positions that sit below the fold.
    public let belowFoldCount: Int

    /// Share of **positions** below the fold, as a percentage (PostHog sends
    /// `33.1`, not `0.331`); `below_fold_count / total_count`.
    ///
    /// This cannot be recomputed from `results`, and must not be: rows come back
    /// hottest-first, and hot positions cluster above the fold. On the captured
    /// project only 12.8% of the *returned* positions are below the fold against
    /// 33.1% across all of them — so deriving the share from the sample would
    /// understate it nearly threefold. That sampling bias is presumably why
    /// PostHog ships this block separately at all.
    public let pctBelowFold: Double

    /// Median viewport height in CSS pixels. A **median**: half of visitors saw
    /// less of the page than this, so it is a reference line and never a claim
    /// about any individual visit.
    public let medianViewportHeight: Int?

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case belowFoldCount = "below_fold_count"
        case pctBelowFold = "pct_below_fold"
        case medianViewportHeight = "median_viewport_height"
    }

    public init(
        totalCount: Int,
        belowFoldCount: Int,
        pctBelowFold: Double,
        medianViewportHeight: Int?
    ) {
        self.totalCount = totalCount
        self.belowFoldCount = belowFoldCount
        self.pctBelowFold = pctBelowFold
        self.medianViewportHeight = medianViewportHeight
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try c.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
        belowFoldCount = try c.decodeIfPresent(Int.self, forKey: .belowFoldCount) ?? 0
        pctBelowFold = try c.decodeIfPresent(Double.self, forKey: .pctBelowFold) ?? 0
        medianViewportHeight = try c.decodeIfPresent(Double.self, forKey: .medianViewportHeight)
            .map { Int($0.rounded()) }
    }

    /// As a 0…1 fraction, for `.percent` formatting.
    public var belowFoldShare: Double { pctBelowFold / 100 }
}

/// The whole heatmaps response.
///
/// Not `Page<HeatmapPoint>`: the envelope carries no `count`/`next`, but it does
/// carry `fold` and `has_more`, and dropping those is how a screen ends up
/// quietly reporting a truncated sample as a total.
public struct HeatmapResponse: Sendable, Decodable {
    public let results: [HeatmapPoint]
    public let fold: HeatmapFold?

    /// True when PostHog had more coordinates than `limit` allowed it to send.
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case results, fold
        case hasMore = "has_more"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = (try? c.decodeIfPresent([HeatmapPoint].self, forKey: .results)) ?? []
        fold = try? c.decodeIfPresent(HeatmapFold.self, forKey: .fold)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    public static func decode(from data: Data) throws -> HeatmapResponse {
        try JSONDecoder().decode(HeatmapResponse.self, from: data)
    }
}

// MARK: - Bands

/// One horizontal slice of the page, and the clicks that landed in it.
public struct ClickDepthBand: Sendable, Hashable, Identifiable {
    public let start: Int
    public let size: Int
    public let clicks: Int

    /// The final catch-all band, holding everything below where the axis stops.
    public let isOverflow: Bool

    public init(start: Int, size: Int, clicks: Int, isOverflow: Bool = false) {
        self.start = start
        self.size = size
        self.clicks = clicks
        self.isOverflow = isOverflow
    }

    public var id: Int { start }
    public var end: Int { start + size }

    /// Terse on purpose: this is drawn on a phone's chart axis, where "0–200 px"
    /// on a dozen rows is what pushes labels over the plot area. The unit is
    /// stated once, in the chart's own caption.
    public var label: String { isOverflow ? "\(start)+" : "\(start)–\(end)" }

    /// Spoken form, which has room for the unit the axis label drops.
    public var spokenLabel: String {
        isOverflow ? "\(start) pixels and deeper" : "\(start) to \(end) pixels"
    }
}

/// One vertical slice of the viewport width, as a share of it.
public struct ClickColumnBand: Sendable, Hashable, Identifiable {
    public let index: Int
    public let lowerBound: Double
    public let upperBound: Double
    public let clicks: Int

    public var id: Int { index }

    public var label: String {
        "\(Int((lowerBound * 100).rounded()))–\(Int((upperBound * 100).rounded()))%"
    }
}

// MARK: - Profile

/// The two distributions a screenshot-free clickmap can honestly show.
///
/// Lives in the kit rather than the view because the banding is real logic with
/// real edge cases — fixed elements, an inclusive right-hand edge, pages tall
/// enough to produce hundreds of bands — and all three are worth a test.
public struct HeatmapProfile: Sendable, Hashable {
    public let depthBands: [ClickDepthBand]
    public let horizontalBands: [ClickColumnBand]

    /// The band height actually used, which may be wider than requested on a
    /// very tall page.
    public let bandSize: Int

    /// Clicks on elements that scroll with the page — the only ones whose y
    /// means anything as a depth. Counted over the returned sample.
    public let scrollableClicks: Int

    /// Clicks on fixed-position elements, reported separately rather than
    /// dropped: on many sites they are most of the traffic, and their absence
    /// from the depth chart needs explaining. Counted over the returned sample.
    public let fixedClicks: Int

    public let fold: HeatmapFold?

    /// PostHog had more positions than it returned.
    public let isTruncated: Bool

    /// How many (x, y) positions the response actually carried.
    public let sampledPositions: Int

    /// Clicks across the rows the API sent. Deliberately **not** named
    /// `totalClicks`: the endpoint returns only the hottest positions, so this
    /// sum is a floor, and every caller has to see that in the name.
    ///
    /// There is no honest click *total* to offer alongside it. `fold.total_count`
    /// counts positions, and the positions PostHog withheld carry an unknown
    /// number of clicks — so this type deliberately exposes no such property for
    /// a screen to reach for.
    public var sampledClicks: Int { scrollableClicks + fixedClicks }

    /// Distinct positions recorded, when the response said.
    public var reportedPositions: Int? { fold?.totalCount }

    public var isEmpty: Bool { sampledClicks == 0 }

    /// True when the returned rows account for every recorded position.
    public var isSampleComplete: Bool {
        guard !isTruncated else { return false }
        guard let reportedPositions else { return true }
        return reportedPositions <= sampledPositions
    }

    /// States what the click figure actually spans. Always says something —
    /// "these are all of them" is as much a fact as "these are some of them".
    public var coverageNote: String {
        guard !isSampleComplete else {
            return "Across all \(sampledPositions.formatted()) recorded positions."
        }
        guard let reportedPositions else {
            return "Across the \(sampledPositions.formatted()) hottest positions; PostHog had more."
        }
        return "Across the \(sampledPositions.formatted()) hottest positions, of \(reportedPositions.formatted()) recorded."
    }

    /// Clicks in the final catch-all band, if there is one.
    public var overflowBand: ClickDepthBand? { depthBands.last { $0.isOverflow } }

    /// The depth band the median fold line falls in, when there is one to draw.
    ///
    /// A band rather than an exact pixel because the chart's depth axis is
    /// categorical. Never the overflow band: a line inside a catch-all that
    /// spans the rest of the document would imply a precision it has not got.
    public var foldBandLabel: String? {
        guard let height = fold?.medianViewportHeight, height > 0 else { return nil }
        return depthBands.first { !$0.isOverflow && height >= $0.start && height < $0.end }?.label
    }

    public var peakDepthBand: ClickDepthBand? {
        depthBands.max { $0.clicks < $1.clicks }
    }

    public var peakDepthClicks: Int { peakDepthBand?.clicks ?? 0 }
    public var peakHorizontalClicks: Int { horizontalBands.map(\.clicks).max() ?? 0 }
    public var horizontalTotal: Int { horizontalBands.reduce(0) { $0 + $1.clicks } }

    /// Share of the **sampled** clicks that landed on fixed-position UI. Derived
    /// from the rows, so it can only ever be quoted about the sample.
    public var fixedShare: Double {
        sampledClicks == 0 ? 0 : Double(fixedClicks) / Double(sampledClicks)
    }

    public static func make(
        points: [HeatmapPoint],
        fold: HeatmapFold? = nil,
        isTruncated: Bool = false,
        sampledPositions: Int? = nil,
        bandSize: Int = 100,
        maxBands: Int = 14,
        coverage: Double = 0.95,
        columnCount: Int = 10
    ) -> HeatmapProfile {
        let scrollable = points.filter { !$0.isTargetFixed }
        let scrollableClicks = scrollable.reduce(0) { $0 + $1.count }
        let fixedClicks = points.filter(\.isTargetFixed).reduce(0) { $0 + $1.count }

        let extent = axisExtent(
            for: scrollable, foldHeight: fold?.medianViewportHeight, coverage: coverage
        )
        let size = effectiveBandSize(extent: extent, bandSize: bandSize, maxBands: maxBands)

        return HeatmapProfile(
            depthBands: depthBands(for: scrollable, extent: extent, size: size),
            horizontalBands: columnBands(for: points, columnCount: columnCount),
            bandSize: size,
            scrollableClicks: scrollableClicks,
            fixedClicks: fixedClicks,
            fold: fold,
            isTruncated: isTruncated,
            sampledPositions: sampledPositions ?? points.count
        )
    }

    public static func make(
        _ response: HeatmapResponse,
        bandSize: Int = 100,
        maxBands: Int = 14,
        coverage: Double = 0.95,
        columnCount: Int = 10
    ) -> HeatmapProfile {
        make(
            points: response.results,
            fold: response.fold,
            isTruncated: response.hasMore,
            sampledPositions: response.results.count,
            bandSize: bandSize,
            maxBands: maxBands,
            coverage: coverage,
            columnCount: columnCount
        )
    }

    /// Grows the requested band height until the profile fits in `maxBands`.
    ///
    /// The alternative — cutting the page off at band 40 — would hide the
    /// deepest clicks, which are the ones a scroll-depth chart exists to find.
    private static func effectiveBandSize(extent: Int?, bandSize: Int, maxBands: Int) -> Int {
        let size = max(1, bandSize)
        guard let extent, maxBands > 0 else { return size }
        let needed = extent / size + 1
        let factor = max(1, Int((Double(needed) / Double(maxBands)).rounded(.up)))
        return size * factor
    }

    /// How far down the axis reaches.
    ///
    /// Not the deepest click. Real pages produce a long, thin tail — the live
    /// capture ran to 25,872 px on two clicks — and scaling an axis to that
    /// squeezes every band that matters into 700 px steps of empty space. So the
    /// axis is cut at the depth covering `coverage` of the clicks, and anything
    /// past it is aggregated into one labelled overflow band rather than dropped.
    ///
    /// It still reaches the fold when the fold is deeper: "every click was above
    /// the fold" is a finding about the page, and an axis stopping short of the
    /// fold line hides it.
    private static func axisExtent(
        for points: [HeatmapPoint],
        foldHeight: Int?,
        coverage: Double
    ) -> Int? {
        guard !points.isEmpty else { return nil }
        let total = points.reduce(0) { $0 + $1.count }
        let target = Double(total) * min(max(coverage, 0), 1)

        var running = 0
        var cap = 0
        for point in points.sorted(by: { $0.pointerY < $1.pointerY }) {
            cap = max(0, point.pointerY)
            running += point.count
            if Double(running) >= target { break }
        }
        return max(cap, foldHeight.map { max(0, $0) } ?? 0)
    }

    private static func depthBands(
        for points: [HeatmapPoint],
        extent: Int?,
        size: Int
    ) -> [ClickDepthBand] {
        guard !points.isEmpty, let extent else { return [] }
        let lastIndex = extent / size

        var totals: [Int: Int] = [:]
        var overflowClicks = 0
        for point in points {
            // A negative y is not a scroll position anyone can act on, but it is
            // still a click; clamping keeps it visible instead of silently gone.
            let index = max(0, point.pointerY) / size
            if index > lastIndex {
                overflowClicks += point.count
            } else {
                totals[index, default: 0] += point.count
            }
        }

        // Contiguous, including bands nobody clicked: gaps punched out of a depth
        // axis read as "the page ends here" rather than "nothing here was clicked".
        var bands = (0...lastIndex).map { index in
            ClickDepthBand(start: index * size, size: size, clicks: totals[index] ?? 0)
        }
        if overflowClicks > 0 {
            bands.append(
                ClickDepthBand(
                    start: (lastIndex + 1) * size,
                    size: size,
                    clicks: overflowClicks,
                    isOverflow: true
                )
            )
        }
        return bands
    }

    private static func columnBands(
        for points: [HeatmapPoint],
        columnCount: Int
    ) -> [ClickColumnBand] {
        guard !points.isEmpty, columnCount > 0 else { return [] }

        var totals = [Int](repeating: 0, count: columnCount)
        for point in points {
            // `pointer_relative_x` is inclusive of 1.0, so the obvious
            // `x * columnCount` index puts the right-hand edge in a column that
            // does not exist.
            let raw = Int(point.pointerRelativeX * Double(columnCount))
            totals[min(columnCount - 1, max(0, raw))] += point.count
        }

        let width = 1.0 / Double(columnCount)
        return totals.enumerated().map { index, clicks in
            ClickColumnBand(
                index: index,
                lowerBound: Double(index) * width,
                upperBound: Double(index + 1) * width,
                clicks: clicks
            )
        }
    }
}
