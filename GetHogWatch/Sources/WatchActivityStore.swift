import Foundation
import GetHogKit

// MARK: - Activity

/// One activity row, already trimmed to what the watch will draw.
///
/// `Codable` so the feed survives a launch. Nothing in `SharedSnapshot`
/// carries events — it is the widgets' contract and widening it is not this
/// task's to do — so the wrist keeps its own small file beside it.
struct ActivityLine: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let event: String
    let timestamp: Date?
}

/// The Activity page's hard caps, applied in one place so no view can widen
/// them.
///
/// The caps live beside the reducer rather than at the call site because the
/// view renders whatever it is handed: a cap enforced only in `WatchModel`
/// would be one refactor away from a wrist scrolling a thousand rows.
enum WatchActivity {
    /// Rows kept, whatever the response carried — the wrist budget's page size,
    /// not a second number beside it. The query already asks for no more than
    /// this; the cap is what stops a response that ignored the limit, or a
    /// carried file written by a build with a larger one, from reaching a
    /// screen that can scroll neither.
    static var maxLines: Int { QueryBudget.wrist.pageSize }
    /// Characters of event name kept per line — one watch line, no wrapping.
    static let maxEventNameLength = 60

    static func lines(from response: QueryResponse) -> [ActivityLine] {
        response.rows.prefix(maxLines).enumerated().map { index, row in
            let name = row.string("event") ?? "unknown event"
            return ActivityLine(
                // `uuid` is one of the four columns `recentEventLines` selects,
                // so the fallback is for a response that came from somewhere
                // else — a fixture, an older builder — rather than the ordinary
                // case. It still has to be stable across a redraw, hence the
                // index rather than a random component.
                id: row.string("uuid")
                    ?? "\(name)|\(row.string("timestamp") ?? "")|\(index)",
                event: String(name.prefix(maxEventNameLength)),
                timestamp: row.date("timestamp")
            )
        }
    }

    // MARK: - Persistence

    /// Written and read beside the snapshot, and for the same reason the
    /// snapshot is written at all.
    ///
    /// A refresh is throttled to one every quarter of an hour, so a relaunch
    /// inside that window spends no requests — and without this the Activity
    /// page rendered "No events in the last 24 hours" over a feed it had
    /// simply not asked for. That sentence is a claim about the project; the
    /// empty in-memory array was a fact about this process. They are not the
    /// same thing, and only one of them was true. Measured on the demo: the
    /// first launch drew four rows and every relaunch inside the window drew
    /// the empty state.
    ///
    /// Its own capture time rather than the snapshot's, because the two can
    /// come from different wakes: a refresh whose events query alone failed
    /// keeps the feed it had, and stamping that with the fresh snapshot's time
    /// would age it backwards.
    static func fileURL(in store: SharedSnapshotStore) -> URL {
        store.directory.appendingPathComponent("watch-activity.json")
    }

    static func write(_ feed: ActivityFeed, to store: SharedSnapshotStore) throws {
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true
        )
        let data = try JSONEncoder.watchActivity.encode(feed)
        try data.write(to: fileURL(in: store), options: [.atomic])
    }

    /// Non-throwing: a corrupt feed must degrade to "nothing carried over"
    /// rather than stop the app from launching.
    ///
    /// The cap is applied here as well as at the write, and that is not
    /// belt-and-braces: this file outlives the build that wrote it, so a
    /// downgrade — or a build whose budget shrank, which is exactly what
    /// happened when the page size moved from 25 to the wrist budget's ten —
    /// reads a longer feed than it is willing to draw.
    static func read(from store: SharedSnapshotStore) -> ActivityFeed? {
        guard let data = try? Data(contentsOf: fileURL(in: store)),
              let feed = try? JSONDecoder.watchActivity.decode(ActivityFeed.self, from: data)
        else { return nil }
        guard feed.lines.count > maxLines else { return feed }
        return ActivityFeed(lines: Array(feed.lines.prefix(maxLines)), capturedAt: feed.capturedAt)
    }
}

/// The feed with the moment it was read, so the page can age it honestly.
struct ActivityFeed: Codable, Equatable, Sendable {
    let lines: [ActivityLine]
    let capturedAt: Date
}

private extension JSONEncoder {
    /// ISO-8601 explicitly, for the reason `SharedSnapshotStore` spells it out:
    /// this file outlives the build that wrote it, and `.deferredToDate`'s
    /// reference-date doubles would drift silently if the default ever changed.
    static let watchActivity: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let watchActivity: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
