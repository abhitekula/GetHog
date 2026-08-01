import Foundation

// A *saved* heatmap is a page URL somebody pinned in the PostHog web console,
// plus a set of full-page renders of it at fixed viewport widths. Those renders
// are the backdrop PostHog's own heatmap paints clicks over, and they are
// fetchable — which is what makes a real overlay possible on a phone.
//
// The catch is coverage, not capability: a render exists only where a person
// explicitly asked for one. Everything here therefore handles absent renders.

/// One rendered width of a saved heatmap.
public struct SavedHeatmapSnapshot: Sendable, Decodable, Hashable {
    public let width: Int

    /// Whether the image for this width actually exists yet.
    ///
    /// Separate from the parent's `status` because the renders complete one
    /// width at a time: a save can be `completed` overall while an individual
    /// width is still empty.
    public let hasContent: Bool

    enum CodingKeys: String, CodingKey {
        case width
        case hasContent = "has_content"
    }

    public init(width: Int, hasContent: Bool) {
        self.width = width
        self.hasContent = hasContent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        hasContent = try c.decodeIfPresent(Bool.self, forKey: .hasContent) ?? false
    }
}

/// A saved heatmap from `/api/projects/:id/heatmap_screenshots/saved/`.
public struct SavedHeatmap: Sendable, Decodable, Hashable, Identifiable {

    /// The UUID. **This is the one the image route wants**
    /// (`/heatmap_screenshots/<id>/content/`).
    public let id: String

    /// The short id. **This is the one the detail route wants**
    /// (`/heatmap_screenshots/saved/<short_id>/`).
    ///
    /// The two identifiers name the same object and are not interchangeable;
    /// the list response above is the only place both are handed over together,
    /// which is why the app reads the list even when it wants only the image.
    public let shortID: String

    public let name: String?

    /// The page that was rendered. Also the key the click coordinates have to be
    /// requested under — an overlay of some other page's clicks is worse than no
    /// overlay, because it looks right.
    public let url: String

    /// `screenshot`, `iframe` or `recording`. Only `screenshot` has an image;
    /// the other two ask the browser to draw the page live, which a native
    /// client cannot do and must not pretend to.
    public let type: String

    /// `processing`, `completed` or `failed`.
    public let status: String

    /// The widths the render was *requested* at.
    public let targetWidths: [Int]

    /// The widths the render was *produced* at. This is the list to trust.
    public let snapshots: [SavedHeatmapSnapshot]

    public let updatedAt: Date?

    /// Why the render failed, when it did. Surfaced rather than swallowed: a
    /// failed render is the difference between "this page has no picture" and
    /// "this page's picture broke", and only one of those is worth retrying.
    public let exception: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, type, status, snapshots, exception
        case shortID = "short_id"
        case targetWidths = "target_widths"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        shortID: String,
        name: String?,
        url: String,
        type: String,
        status: String,
        targetWidths: [Int],
        snapshots: [SavedHeatmapSnapshot],
        updatedAt: Date?,
        exception: String?
    ) {
        self.id = id
        self.shortID = shortID
        self.name = name
        self.url = url
        self.type = type
        self.status = status
        self.targetWidths = targetWidths
        self.snapshots = snapshots
        self.updatedAt = updatedAt
        self.exception = exception
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        targetWidths = try c.decodeIfPresent([Int].self, forKey: .targetWidths) ?? []
        snapshots = try c.decodeIfPresent([SavedHeatmapSnapshot].self, forKey: .snapshots) ?? []
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(PostHogDate.parse)
        exception = try c.decodeIfPresent(String.self, forKey: .exception)
    }

    // MARK: - Usability

    /// The widths that have an image behind them, narrowest first.
    ///
    /// Derived from `snapshots`, never from `target_widths`: the latter records
    /// what was asked for, and asking for a width the API has not drawn returns
    /// nothing at the point where the screen has already committed to showing a
    /// picture.
    public var renderedWidths: [Int] {
        snapshots.filter(\.hasContent).map(\.width).sorted()
    }

    /// True when there is an image this app can actually put clicks on top of.
    public var isRenderable: Bool {
        type == "screenshot" && status == "completed" && !renderedWidths.isEmpty
    }

    public var hasFailed: Bool { status == "failed" }

    /// The rendered width closest to the width the overlay will be drawn at.
    ///
    /// Always resolved against the real layout width rather than pinned to 375:
    /// no shipping device is 375 pt wide any more, and every one of these widths
    /// is a *different rendering of the page*, not a scaled copy of one. Picking
    /// the wrong one overlays clicks on a layout their visitors never saw.
    ///
    /// Ties go to the wider render, which downscales into place; the narrower
    /// one would have to be stretched.
    public func renderWidth(nearest width: Double) -> Int? {
        renderedWidths.min { lhs, rhs in
            let dl = abs(Double(lhs) - width)
            let dr = abs(Double(rhs) - width)
            return dl == dr ? lhs > rhs : dl < dr
        }
    }

    /// The range of recorded viewport widths a given render legitimately speaks
    /// for, as `viewport_width_min`/`viewport_width_max` for `/heatmaps/`.
    ///
    /// Needed because the two halves of the overlay are measured differently.
    /// The image is one fixed layout; `pointer_y` is absolute pixels down
    /// *whatever document the visitor's own viewport produced*. A click 4,000 px
    /// down a 1,920 px-wide desktop layout is not 4,000 px down the 425 px-wide
    /// phone layout — the same content sits far lower once it stacks. Drawing
    /// both on one backdrop misplaces one of them, silently and plausibly.
    ///
    /// The bands split the gap between neighbouring renders, so every recorded
    /// viewport belongs to exactly one render — its nearest — and no click is
    /// either double-counted or dropped. The outermost bands stay open-ended for
    /// the same reason: a 280 px phone is still nearest the narrowest render.
    ///
    /// This narrows the layout mismatch rather than removing it. Within a band
    /// the page can still reflow across a CSS breakpoint, so the alignment is
    /// close, not exact — which is why the screen says so.
    public func viewportBand(for width: Int) -> (min: Int?, max: Int?) {
        let widths = renderedWidths
        guard let index = widths.firstIndex(of: width) else { return (nil, nil) }

        let lower = index > 0 ? (widths[index - 1] + width) / 2 : nil
        let upper = index < widths.count - 1 ? (width + widths[index + 1]) / 2 : nil
        return (lower, upper)
    }
}
