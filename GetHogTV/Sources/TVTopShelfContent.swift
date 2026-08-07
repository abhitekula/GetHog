import Foundation
import GetHogKit
import GetHogUI
import TVServices

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
        let items = snapshot.metrics.prefix(itemCap).enumerated().map { offset, metric in
            Item(
                id: "metric.\(offset).\(metric.id)",
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

    /// `nil` is the documented signal for Top Shelf's static-image fallback,
    /// so both never-synced and no-pinned-metric states stay honest.
    func sectioned() -> TVTopShelfSectionedContent? {
        guard !sections.isEmpty else { return nil }

        let collections = sections.map { section in
            let items = section.items.map { item in
                let shelfItem = TVTopShelfSectionedItem(identifier: item.id)
                shelfItem.title = item.caption
                // No expiration date: stale values stay visible with their age
                // rather than disappearing into an unexplained empty shelf.
                // Image and selection-action behavior are intentionally left
                // for the required simulator sighted pass.
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
