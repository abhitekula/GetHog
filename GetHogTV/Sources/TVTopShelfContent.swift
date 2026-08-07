import Foundation
import GetHogKit
import GetHogUI
import TVServices
import UIKit

/// The only destination a Top Shelf item promises today.
///
/// Kept with the shared shelf model so the extension constructs and the app
/// parses exactly the same URL grammar. Adding a destination means adding one
/// case and an explicit host mapping, never letting arbitrary URLs steer the
/// TV shell.
enum TopShelfRoute {

    enum Destination: String, Equatable {
        case dashboards
    }

    static func url(for destination: Destination) -> URL {
        // A compile-time literal over a closed enum. If this ever stops being a
        // valid URL, crashing in development is safer than shipping a dead
        // Top Shelf action that looks selectable.
        URL(string: "gethog://tab/\(destination.rawValue)")!
    }

    static func destination(for url: URL) -> Destination? {
        guard url.scheme?.lowercased() == "gethog",
              url.host()?.lowercased() == "tab",
              url.query == nil,
              url.fragment == nil
        else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 1 else { return nil }
        return Destination(rawValue: String(segments[0]))
    }
}

/// The two image files TVServices may ask for when rendering an HDTV-shaped
/// sectioned item.
struct TopShelfArtwork: Equatable {
    let scale1x: URL
    let scale2x: URL
}

/// Produces one generic, deterministic GetHog card for every shelf item.
///
/// Nothing from the snapshot enters these pixels: no project name, metric
/// title, value, identifier, credential, or live label. The files are written
/// under the same App Group directory as the snapshot because the Top Shelf
/// system process must be able to resolve a local extension-supplied URL after
/// the provider returns.
enum TopShelfArtworkStore {

    static func fileURLs(in appGroupDirectory: URL) -> TopShelfArtwork {
        let directory = appGroupDirectory.appendingPathComponent("TopShelf", isDirectory: true)
        return TopShelfArtwork(
            scale1x: directory.appendingPathComponent("gethog-card-1x.png"),
            scale2x: directory.appendingPathComponent("gethog-card-2x.png")
        )
    }

    static func ensureArtwork(in appGroupDirectory: URL) -> TopShelfArtwork? {
        let artwork = fileURLs(in: appGroupDirectory)
        do {
            try FileManager.default.createDirectory(
                at: artwork.scale1x.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !isUsable(artwork.scale1x) {
                try pngData(scale: 1).write(to: artwork.scale1x, options: .atomic)
            }
            if !isUsable(artwork.scale2x) {
                try pngData(scale: 2).write(to: artwork.scale2x, options: .atomic)
            }
            guard isUsable(artwork.scale1x), isUsable(artwork.scale2x) else { return nil }
            return artwork
        } catch {
            return nil
        }
    }

    private static func isUsable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return false }
        return (values.fileSize ?? 0) > 0
    }

    private static func pngData(scale: CGFloat) -> Data {
        let requested = TVTopShelfSectionedContent.imageSize(for: .hdtv)
        let size = requested.width > 0 && requested.height > 0
            ? requested
            : CGSize(width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale

        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            // The same fixed brand teal as the committed synthetic TV artwork.
            // Literal here because dynamic UI colours would make the file
            // depend on the extension's current appearance and stop being
            // deterministic.
            UIColor(
                red: 6.0 / 255.0,
                green: 94.0 / 255.0,
                blue: 112.0 / 255.0,
                alpha: 1
            ).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let inset = min(size.width, size.height) * 0.13
            let card = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset),
                cornerRadius: size.height * 0.08
            )
            UIColor.white.withAlphaComponent(0.11).setFill()
            card.fill()

            let plot = CGRect(origin: .zero, size: size).insetBy(dx: inset * 1.55, dy: inset * 1.65)
            let samples: [CGFloat] = [0.72, 0.55, 0.62, 0.36, 0.43, 0.17]
            let line = UIBezierPath()
            for (index, sample) in samples.enumerated() {
                let x = plot.minX + CGFloat(index) * plot.width / CGFloat(samples.count - 1)
                let y = plot.minY + sample * plot.height
                if index == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            line.lineWidth = max(4, size.height * 0.035)
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            UIColor.white.setStroke()
            line.stroke()

            let endpoint = line.currentPoint
            let dot = UIBezierPath(
                ovalIn: CGRect(
                    x: endpoint.x - line.lineWidth,
                    y: endpoint.y - line.lineWidth,
                    width: line.lineWidth * 2,
                    height: line.lineWidth * 2
                )
            )
            UIColor.white.setFill()
            dot.fill()
        }
    }
}

/// Everything the Top Shelf may say, as values a test can hold.
///
/// This source is compiled into both the TV app and the Top Shelf extension:
/// the app test bundle cannot compile an appex, and an appex has no test host.
/// Each process only reads the App Group snapshot. It never calls the PostHog
/// API: that organisation-wide rate-limit budget belongs to the app process
/// that owns credentials and writes the reduced snapshot.
struct TopShelfContent: Equatable {

    struct Item: Equatable {
        /// Unique across the whole answer: TVServices requires this even when
        /// two dashboard tiles happen to carry the same insight identifier.
        let id: String
        let name: String
        let headline: String

        /// Sectioned Top Shelf items get one string, so neither half can live
        /// somewhere the Home screen never renders.
        var caption: String { "\(name) · \(headline)" }
    }

    struct Section: Equatable {
        let title: String
        let items: [Item]
    }

    let sections: [Section]

    /// A shelf is a glance, not a dashboard with every tile duplicated.
    static let itemCap = 6

    static func make(snapshot: SharedSnapshot?, now: Date) -> TopShelfContent {
        guard let snapshot, !snapshot.metrics.isEmpty else { return TopShelfContent(sections: []) }

        // Snapshot order is the wallboard's order too. Re-ranking here would
        // silently break the contract that these two TV surfaces agree about
        // what is pinned.
        var occurrences: [String: Int] = [:]
        let items = snapshot.metrics.prefix(itemCap).map { metric in
            let contentKey = stableContentKey(for: metric)
            let occurrence = occurrences[contentKey, default: 0]
            occurrences[contentKey] = occurrence + 1
            let duplicateSuffix = occurrence == 0 ? "" : ".\(occurrence + 1)"
            return Item(
                id: "metric.\(contentKey)\(duplicateSuffix)",
                name: metric.title,
                headline: metric.value.compactFormatted
            )
        }

        return TopShelfContent(sections: [Section(title: sectionTitle(snapshot, now: now), items: items)])
    }

    static func sectionTitle(_ snapshot: SharedSnapshot, now: Date) -> String {
        let freshness = TopShelfFreshness.caption(forAge: snapshot.staleness(now: now))
        let stale = snapshot.isStale(now: now) ? " — stale" : ""
        return "\(snapshot.projectName) · \(freshness)\(stale)"
    }

    /// Stable across value refreshes and unrelated reorderings. Dashboard,
    /// metric id, and title are the identity fields available in the reduced
    /// snapshot; the current number is content, not identity.
    private static func stableContentKey(for metric: SharedSnapshot.Metric) -> String {
        let dashboard = metric.dashboardID.map(String.init) ?? "unknown"
        let fields = [metric.id, dashboard, metric.title]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")

        // FNV-1a is deliberately fixed rather than Swift's randomised `hash`.
        // This is an identity token, not a security primitive.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let unpadded = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - unpadded.count) + unpadded
    }

    /// `nil` is the documented signal for Top Shelf's static-image fallback,
    /// so both never-synced and no-pinned-metric states stay honest.
    func sectioned(artwork: TopShelfArtwork) -> TVTopShelfSectionedContent? {
        guard !sections.isEmpty else { return nil }

        let collections = sections.map { section in
            let items = section.items.map { item in
                let shelfItem = TVTopShelfSectionedItem(identifier: item.id)
                shelfItem.title = item.caption
                shelfItem.imageShape = .hdtv
                shelfItem.setImageURL(artwork.scale1x, for: .screenScale1x)
                shelfItem.setImageURL(artwork.scale2x, for: .screenScale2x)
                let action = TVTopShelfAction(url: TopShelfRoute.url(for: .dashboards))
                shelfItem.displayAction = action
                shelfItem.playAction = action
                // No expiration date: stale values stay visible with their age
                // rather than disappearing into an unexplained empty shelf.
                return shelfItem
            }
            let collection = TVTopShelfItemCollection<TVTopShelfSectionedItem>(items: items)
            collection.title = section.title
            return collection
        }
        return TVTopShelfSectionedContent(sections: collections)
    }
}

/// The shared widget freshness primitive is the sole owner of these age
/// buckets; Top Shelf only gives its existing caption API a platform name.
typealias TopShelfFreshness = WidgetFreshness
