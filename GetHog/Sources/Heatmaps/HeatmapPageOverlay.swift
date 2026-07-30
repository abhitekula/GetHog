import CoreGraphics
import ImageIO
import GetHogKit
import SwiftUI

// The overlay half of the clickmap: real click coordinates drawn on the page
// image PostHog rendered for a saved heatmap.
//
// It exists only where somebody saved the URL as a heatmap in the web console,
// which is why it is a destination reached from the clickmap rather than the
// clickmap itself. See `HeatmapsRoot` for the fallback that is still the common
// case.

// MARK: - Decoding

/// A decoded page render, plus the dimensions of the image it came from.
///
/// `@unchecked Sendable` because `CGImage` is immutable once created and this
/// type never hands out a mutable reference — the decode has to happen off the
/// main actor, and a 12,000 px page is exactly the payload that must not be
/// decoded during a layout pass.
struct PageRender: @unchecked Sendable {
    let image: CGImage

    /// The render's own size, in the CSS pixels the click coordinates are also
    /// measured in. **Not** the decoded image's size: the decode is deliberately
    /// smaller, and using it to place clicks would scale every y by the
    /// downsampling factor.
    let sourceWidth: Int
    let sourceHeight: Int

    var aspectRatio: CGFloat {
        sourceWidth > 0 ? CGFloat(sourceHeight) / CGFloat(sourceWidth) : 1
    }
}

enum PageRenderDecoder {

    /// Ceiling on the decoded bitmap, in pixels.
    ///
    /// A page render has no bounded height — the one saved in project [REMOVED PRIVATE DATA] is
    /// 375 × 12,327, which is 18 MB once decoded to RGBA, and a long docs page
    /// would be several times that. Sizing the bitmap from the image would
    /// therefore make this screen's memory a function of *someone else's page
    /// length*, so it is capped at a constant instead: ~3 MP, about 12 MB.
    ///
    /// The cost is sharpness. At this budget the 375-wide render decodes to
    /// roughly 300 px across and is drawn at ~400 pt, so it is visibly soft.
    /// That is the right trade for what the picture is *for*: locating clicks
    /// against page structure — headers, buttons, sections — not reading body
    /// copy. The numbers behind it stay exact on the clickmap's other lenses.
    static let pixelBudget = 3_000_000

    /// Downsamples the JPEG without ever materialising it at full size.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` is the only API that decodes
    /// straight to the target size; `UIImage(data:)` followed by a resize would
    /// have paid the full 18 MB first, which is the whole thing being avoided.
    static func decode(_ data: Data, pixelBudget: Int = pixelBudget) -> PageRender? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        // Header-only read: this gives the pixel dimensions without decoding a
        // single row, which is what makes the budget computable up front.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }

        // **`kCGImageSourceThumbnailMaxPixelSize` bounds the LONGER edge**, and
        // on a full-page render the longer edge is the height by a factor of
        // thirty. Passing the device width here — the obvious reading of
        // "thumbnail max size" — would scale 375 × 12,327 down to a 12 px-wide
        // thread. So the limit is derived from the aspect ratio: scale the area
        // to fit the budget, then express that scale as a bound on the long edge.
        let scale = min(1, (Double(pixelBudget) / Double(width * height)).squareRoot())
        let maxPixelSize = max(1, Int((Double(max(width, height)) * scale).rounded()))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, on whatever thread this is called from. Left lazy, the
            // decode happens on the first draw — on the main actor, mid-scroll.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return PageRender(image: image, sourceWidth: width, sourceHeight: height)
    }
}

// MARK: - Scope

/// Which recorded viewports the overlay is drawn from.
enum OverlayScope: String, CaseIterable, Identifiable, Hashable {
    /// Only viewports nearest this render's width.
    case matched
    /// Every viewport, laid over one width's page.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matched: "Matched widths"
        case .all: "All widths"
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class HeatmapOverlayStore {
    var points: [HeatmapPoint] = []
    var fold: HeatmapFold?
    var isTruncated = false
    var render: PageRender?

    var isLoadingPoints = false
    var isLoadingImage = false
    var pointsError: String?
    var imageError: String?
    var loadedAt: Date?

    var isLoading: Bool { isLoadingPoints || isLoadingImage }

    /// Clicks on fixed-position elements, which are counted but never drawn.
    ///
    /// Their `pointer_y` is a position on the visitor's screen, not a position
    /// in the document — a sticky header clicked at the bottom of a long page
    /// still records y ≈ 40. Painting them on a full-page image would put every
    /// one of them near the top of the page, over content nobody clicked.
    var fixedClicks: Int {
        points.filter(\.isTargetFixed).reduce(0) { $0 + $1.count }
    }

    /// The clicks this overlay can honestly place.
    var placeableClicks: Int {
        points.filter { !$0.isTargetFixed }.reduce(0) { $0 + $1.count }
    }

    /// Clicks recorded deeper than the render is tall.
    ///
    /// Real, and not a rounding error: a visitor whose viewport was narrower
    /// than the render got a taller document, so their deepest clicks fall off
    /// the bottom of this image. Counted and reported rather than clamped to the
    /// last pixel, which would invent a hotspot at the page footer.
    func clicksBeyondPage() -> Int {
        guard let render else { return 0 }
        return points
            .filter { !$0.isTargetFixed && $0.pointerY > render.sourceHeight }
            .reduce(0) { $0 + $1.count }
    }

    /// Two requests, and only two: the coordinates for this page, and the image.
    ///
    /// The image is fetched second and only because a saved render was already
    /// known to exist — the caller establishes that from the list the clickmap
    /// screen already loads, so this screen never spends a request discovering
    /// there is nothing to draw.
    func load(
        client: PostHogClient,
        cache: ResponseCache,
        projectID: Int,
        saved: SavedHeatmap,
        width: Int,
        window: AnalyticsWindow,
        scope: OverlayScope
    ) async {
        async let coordinates: Void = loadPoints(
            client: client,
            projectID: projectID,
            saved: saved,
            width: width,
            window: window,
            scope: scope
        )
        async let image: Void = loadImage(
            client: client, cache: cache, projectID: projectID, saved: saved, width: width
        )
        _ = await (coordinates, image)
    }

    private func loadPoints(
        client: PostHogClient,
        projectID: Int,
        saved: SavedHeatmap,
        width: Int,
        window: AnalyticsWindow,
        scope: OverlayScope
    ) async {
        isLoadingPoints = true
        defer { isLoadingPoints = false }

        let band = scope == .matched ? saved.viewportBand(for: width) : (min: nil, max: nil)
        do {
            let response: HeatmapResponse = try await client.send(
                PostHogAPI.heatmap(
                    projectID: projectID,
                    dateFrom: window.rawValue,
                    // The saved render's own URL, never the project-wide
                    // aggregate the clickmap screen uses: clicks from other
                    // pages drawn on this page's image would look correct.
                    urlExact: saved.url,
                    viewportWidthMin: band.min,
                    viewportWidthMax: band.max
                )
            )
            points = response.results
            fold = response.fold
            isTruncated = response.hasMore
            pointsError = nil
            loadedAt = Date()
        } catch {
            pointsError = Self.message(for: error)
        }
    }

    private func loadImage(
        client: PostHogClient,
        cache: ResponseCache,
        projectID: Int,
        saved: SavedHeatmap,
        width: Int
    ) async {
        isLoadingImage = true
        defer { isLoadingImage = false }

        let endpoint = PostHogAPI.heatmapScreenshotContent(
            projectID: projectID, screenshotID: saved.id, width: width
        )
        let key = "\(endpoint.path)?width=\(width)"

        do {
            let data: Data
            if let entry = await cache.entry(for: key),
               entry.isFresh(ttl: ResponseCache.TTL.pageRenders) {
                data = entry.data
            } else {
                // `data(for:)` and not `send(_:)`: the body is JPEG. The generic
                // path would hand a quarter-megabyte of image to `JSONDecoder`
                // and surface the result as a decoding bug in the app.
                data = try await client.data(for: endpoint)
                await cache.store(data, for: key)
                // Renders are the largest thing this cache holds, so the bound
                // is applied where they are written rather than at launch.
                await cache.evict(toFitBytes: 64 * 1_024 * 1_024)
            }

            // Off the main actor. Decoding ~12,000 rows of JPEG on the actor
            // driving the scroll view is a visible stall, not a micro-optimisation.
            let decoded = await Task.detached(priority: .userInitiated) {
                PageRenderDecoder.decode(data)
            }.value

            guard let decoded else {
                imageError = "The page render came back in a format this app could not read."
                return
            }
            render = decoded
            imageError = nil
            loadedAt = Date()
        } catch {
            imageError = Self.message(for: error)
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

// MARK: - Screen

/// Clicks drawn on the page they were recorded on.
///
/// Reached only when a saved render exists, so it has no "nothing to draw"
/// state of its own — that case never gets this far.
struct HeatmapPageOverlay: View {
    let saved: SavedHeatmap
    let window: AnalyticsWindow

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var store = HeatmapOverlayStore()
    @State private var scope: OverlayScope = .matched

    /// The width the page will actually be drawn at, measured rather than
    /// assumed — an iPhone, a rotated iPad and an iPad split view are three
    /// different answers, and each maps to a different saved render.
    @State private var containerWidth: CGFloat = 0

    private var renderWidth: Int? {
        containerWidth > 0 ? saved.renderWidth(nearest: Double(containerWidth)) : nil
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .onAppear { containerWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in containerWidth = new }
        }
        .navigationTitle("Page overlay")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await load() }
        .task(id: LoadKey(width: renderWidth, window: window, scope: scope)) { await load() }
    }

    private struct LoadKey: Hashable {
        let width: Int?
        let window: AnalyticsWindow
        let scope: OverlayScope
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.imageError, store.render == nil {
            EmptyStateView(
                title: "Couldn't load the page render",
                systemImage: "photo.badge.exclamationmark",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header
                    page
                    footnotes
                }
                .padding(.vertical, Theme.Space.l)
            }
            .pageSurface()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            GlassFilterBar {
                // Same threshold as the clickmap's own pickers: a segmented
                // control shreds its labels into slivers at accessibility sizes.
                adaptivelyStyled(
                    Picker("Viewports", selection: $scope) {
                        ForEach(OverlayScope.allCases) { option in
                            Text(option.title).accessibilityLabel(option.spokenTitle).tag(option)
                        }
                    }
                )
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(saved.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)

                if let width = renderWidth {
                    Text(scopeExplanation(width: width))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Space.l)

            if let error = store.pointsError {
                // Two different failures wearing one message would be a lie in
                // one of the two cases: with points already on screen the render
                // is stale, and with none it is empty. The picture underneath
                // looks identically finished either way, which is exactly why
                // the wording has to distinguish them.
                SectionEmptyState(
                    text: store.points.isEmpty
                        ? "Couldn't load the clicks for this page. The render below has nothing drawn on it."
                        : "These clicks are from an earlier load.",
                    systemImage: "exclamationmark.circle",
                    detail: error,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
                .padding(.horizontal, Theme.Space.l)
            } else if !store.isLoadingPoints, store.placeableClicks == 0 {
                SectionEmptyState(
                    text: emptyClicksMessage,
                    systemImage: "hand.tap"
                )
                .padding(.horizontal, Theme.Space.l)
            }
        }
    }

    /// A page with no drawable clicks is a finding, not a blank. Which finding
    /// depends on why: a viewport band that nobody in this window matched is a
    /// different thing from a page whose every click was on a sticky header.
    private var emptyClicksMessage: String {
        if store.fixedClicks > 0 {
            return "Every click recorded here was on a fixed element, so none of them has a place in the page to be drawn at."
        }
        if scope == .matched, let width = renderWidth {
            return "No clicks were recorded on this page in the \(window.spokenTitle.lowercased()) from viewports near \(width) px. Switch to All widths to include every viewport."
        }
        return "No clicks were recorded on this page in the \(window.spokenTitle.lowercased())."
    }

    @ViewBuilder
    private func adaptivelyStyled(_ picker: some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private func scopeExplanation(width: Int) -> String {
        let band = saved.viewportBand(for: width)
        switch scope {
        case .matched:
            let range: String
            switch (band.min, band.max) {
            case let (min?, max?): range = "\(min)–\(max) px wide"
            case let (min?, nil): range = "\(min) px wide and up"
            case let (nil, max?): range = "up to \(max) px wide"
            case (nil, nil): range = "any width"
            }
            // Naming the band rather than just "matched" because the number is
            // the reason the picture can be trusted: these are the visitors
            // whose page laid out closest to the one on screen.
            return "Rendered at \(width) px. Showing clicks from viewports \(range) — the ones nearest this render."
        case .all:
            return "Rendered at \(width) px, showing clicks from every viewport. Depths recorded on other widths came from a differently-sized document, so they sit only roughly where the click happened."
        }
    }

    // MARK: Page

    @ViewBuilder
    private var page: some View {
        if let render = store.render {
            HeatmapPageCanvas(
                render: render,
                points: store.points,
                width: containerWidth
            )
            .overlay(alignment: .top) {
                if store.isLoadingPoints {
                    ProgressView().padding(Theme.Space.m)
                }
            }
        } else {
            // The page render is the screen; a skeleton the height of a 12,000
            // px page would just be a very long grey rectangle, so this states
            // what is happening instead.
            SectionEmptyState(
                text: store.isLoadingImage
                    ? "Loading the page render…"
                    : "No page render loaded.",
                systemImage: "photo"
            )
            .padding(.horizontal, Theme.Space.l)
        }
    }

    // MARK: Footnotes

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "What you're looking at", systemImage: "info.circle")

            Text(placementNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(caveats, id: \.self) { caveat in
                Label(caveat, systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .labelStyle(BulletLabelStyle())
                    .fixedSize(horizontal: false, vertical: true)
            }

            FreshnessLabel(date: store.loadedAt)
        }
        .padding(.horizontal, Theme.Space.l)
    }

    private var placementNote: String {
        "Each dot is one recorded click position; a bigger, stronger dot means more clicks landed there. Position across the page is a fraction of the viewport width, so it is exact. Position down the page is absolute pixels in the visitor's own document, so it is as exact as the page's layout is stable at these widths."
    }

    private var caveats: [String] {
        var parts: [String] = []
        if store.fixedClicks > 0 {
            parts.append(
                "\(store.fixedClicks.formatted()) clicks on sticky headers, floating buttons or pinned footers are not drawn: their recorded position is a place on the screen, not a place in the page."
            )
        }
        let beyond = store.clicksBeyondPage()
        if beyond > 0 {
            parts.append(
                "\(beyond.formatted()) clicks were recorded deeper than this render is tall — those visitors got a longer document — so they fall past the bottom of the image rather than being pushed onto it."
            )
        }
        if store.isTruncated {
            parts.append(
                "PostHog had more click positions than it returned, so the coolest ones are missing from the picture. The Depth and Across charts report the same limit."
            )
        }
        if let render = store.render {
            parts.append(
                "The render is \(render.sourceWidth) × \(render.sourceHeight.formatted()) px and is drawn downsampled to keep it in memory, so fine print is soft on purpose."
            )
        }
        return parts
    }

    private func load() async {
        guard let client = model.client,
              let projectID = model.projectID,
              let width = renderWidth
        else { return }
        await store.load(
            client: client,
            cache: model.cache,
            projectID: projectID,
            saved: saved,
            width: width,
            window: window,
            scope: scope
        )
    }
}

extension OverlayScope {
    var spokenTitle: String {
        switch self {
        case .matched: "Only viewports nearest this render's width"
        case .all: "Every recorded viewport width"
        }
    }
}

/// A leading dot for the caveat list. `Label` with a filled circle at caption
/// size renders the glyph nearly as tall as the line, which reads as a bullet
/// point the size of a word.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            configuration.icon
                .font(.system(size: 4))
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

// MARK: - Geometry

/// Where a recorded click lands on a rendered page.
///
/// A separate type because the two axes arrive in different units and the
/// conversion is the one place this feature can be wrong without looking wrong:
/// `pointer_relative_x` is already a 0…1 fraction of the viewport, while
/// `pointer_y` is absolute pixels and needs the same scale the image was drawn
/// at. Applying the scale to both, or to neither, produces a plausible picture
/// that is simply in the wrong place.
enum OverlayGeometry {

    /// Points per CSS pixel — the factor the page image is drawn at.
    ///
    /// Derived from the *render's* width, never the decoded bitmap's. The
    /// bitmap is deliberately downsampled, so using its width would scale every
    /// depth by the downsampling factor and slide the whole overlay up the page.
    static func scale(displayWidth: CGFloat, sourceWidth: Int) -> CGFloat {
        sourceWidth > 0 ? displayWidth / CGFloat(sourceWidth) : 1
    }

    static func position(
        for point: HeatmapPoint,
        displayWidth: CGFloat,
        scale: CGFloat
    ) -> CGPoint {
        CGPoint(
            // Already a fraction of the width, so it takes the width directly
            // and must *not* be multiplied by the scale as well.
            x: CGFloat(point.pointerRelativeX) * displayWidth,
            y: CGFloat(point.pointerY) * scale
        )
    }

    /// Dot radius for a click count, in points.
    ///
    /// Area tracks the count, so the radius tracks its square root: scaling the
    /// radius linearly makes a position with four times the clicks read as
    /// sixteen times hotter.
    static func radius(count: Int, peak: Int) -> CGFloat {
        let intensity = intensity(count: count, peak: peak)
        return 4 + 14 * intensity
    }

    /// 0…1 heat for a click count, used for both size and opacity so the reading
    /// never rests on colour alone.
    static func intensity(count: Int, peak: Int) -> CGFloat {
        guard peak > 0 else { return 0 }
        return CGFloat((Double(max(count, 0)) / Double(peak)).squareRoot())
    }
}

// MARK: - Canvas

/// The page image with click positions painted over it.
struct HeatmapPageCanvas: View {
    let render: PageRender
    let points: [HeatmapPoint]
    let width: CGFloat

    private var scale: CGFloat {
        OverlayGeometry.scale(displayWidth: width, sourceWidth: render.sourceWidth)
    }

    private var height: CGFloat { CGFloat(render.sourceHeight) * scale }

    /// Only clicks with a real position in the document. Fixed-element clicks
    /// are excluded here rather than dimmed, because there is no honest place to
    /// put them on a full-page image.
    private var placeable: [HeatmapPoint] {
        points.filter { !$0.isTargetFixed && $0.pointerY <= render.sourceHeight }
    }

    private var peak: Int { max(placeable.map(\.count).max() ?? 1, 1) }

    var body: some View {
        Image(decorative: render.image, scale: 1)
            .resizable()
            .frame(width: width, height: height)
            .overlay { canvas }
            .accessibilityElement()
            .accessibilityLabel("Page render with \(placeable.count) click positions drawn on it")
            .accessibilityValue(spokenSummary)
    }

    private var canvas: some View {
        Canvas { context, _ in
            for point in placeable {
                let centre = CGPoint(
                    x: CGFloat(point.pointerRelativeX) * width,
                    y: CGFloat(point.pointerY) * scale
                )
                // Area, not radius, tracks the count — a radius scaled linearly
                // makes a 4× hotter point look 16× hotter.
                let intensity = (Double(point.count) / Double(peak)).squareRoot()
                let radius = 4 + 14 * intensity

                let rect = CGRect(
                    x: centre.x - radius,
                    y: centre.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                // The dots are the data, so a data colour is the right one here;
                // the surrounding chrome stays on the semantic palette. Size and
                // opacity both carry the count, so the reading never rests on
                // colour alone.
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(SeriesPalette.color(at: 0).opacity(0.18 + 0.42 * intensity))
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(SeriesPalette.color(at: 0).opacity(0.5)),
                    lineWidth: 0.75
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var spokenSummary: String {
        let clicks = placeable.reduce(0) { $0 + $1.count }
        var parts = ["\(clicks) clicks across \(placeable.count) positions"]
        if let hottest = placeable.max(by: { $0.count < $1.count }) {
            let depth = Int(Double(hottest.pointerY))
            let across = (hottest.pointerRelativeX * 100).rounded()
            parts.append(
                "hottest position \(hottest.count) clicks, \(depth) pixels down and \(Int(across)) percent across"
            )
        }
        // A canvas cannot be explored point by point, so the listener is sent to
        // the two charts that can be.
        parts.append(
            "The Depth and Across charts on the clickmap present the same data in a form VoiceOver can step through"
        )
        return parts.joinedAsSentences()
    }
}
