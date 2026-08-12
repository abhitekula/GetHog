import Foundation
import GetHogKit
import GetHogUI
import SwiftUI

// MARK: - Console filtering

/// The console pane's filter.
///
/// Errors first and errors default-visible-by-being-nameable: the reason anyone
/// opens a session's console is that something went wrong, and a list where
/// eight errors sit under four hundred `[HMR] connected` lines is a list nobody
/// scrolls to the bottom of.
enum ReplayConsoleFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case errors = "Errors"
    case warnings = "Warnings"
    case logs = "Logs"

    var id: String { rawValue }

    func matches(_ entry: ReplayConsoleEntry) -> Bool {
        switch self {
        case .all: true
        case .errors: entry.level == .error
        case .warnings: entry.level == .warn
        case .logs: entry.level == .log
        }
    }

    /// What to say when this filter is the reason the list is empty.
    var emptyMessage: String {
        switch self {
        case .all: "Nothing was logged."
        case .errors: "No errors were logged."
        case .warnings: "No warnings were logged."
        case .logs: "Nothing was logged at log level."
        }
    }
}

extension ReplayConsoleLevel {
    var label: String {
        switch self {
        case .error: "Error"
        case .warn: "Warning"
        case .log: "Log"
        }
    }

    /// Chart-mark weight, for the dot that leads a row.
    var mark: Color {
        switch self {
        case .error: Theme.Status.critical
        case .warn: Theme.accentWarm
        case .log: Theme.neutralMark
        }
    }

    /// Text weight, for the word itself. `mark` fails AA at body sizes; this is
    /// the partner `Theme.Status` documents for exactly that.
    var ink: Color {
        switch self {
        case .error: Theme.Status.criticalInk
        case .warn: Theme.Status.warningInk
        case .log: Theme.Ink.secondary
        }
    }
}

// MARK: - Network filtering

enum ReplayNetworkFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case failed = "Failed"
    case api = "Fetch & XHR"
    case documents = "Documents"

    var id: String { rawValue }

    func matches(_ entry: ReplayNetworkEntry) -> Bool {
        switch self {
        case .all:
            true
        case .failed:
            entry.isFailure
        case .api:
            // `method` is only ever present on an entry the fetch/XHR wrapper
            // wrote, so it identifies a request the *page's own code* made even
            // when the timing entry did not name an initiator.
            entry.method != nil
                || entry.initiator == "fetch"
                || entry.initiator == "xmlhttprequest"
        case .documents:
            entry.initiator == "navigation"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "No requests were captured."
        case .failed: "No request failed."
        case .api: "The page made no fetch or XHR requests."
        case .documents: "No document load was captured."
        }
    }
}

// MARK: - Hosts

enum ReplayNetworkHosts {
    /// The host most of a session's requests went to — in practice the site
    /// being recorded.
    ///
    /// Exists so a row can say *where* it went only when that is news. Printing
    /// the host on every row spends the width that the path needs; printing it
    /// on none hides the third-party call, which on a page that is slow because
    /// of somebody else's CDN is the one row worth finding.
    static func primary(of entries: [ReplayNetworkEntry]) -> String? {
        var counts: [String: Int] = [:]
        for host in entries.compactMap(\.host) {
            counts[host, default: 0] += 1
        }
        // Ties resolve on the name, not on dictionary order, so the labels do
        // not flip as later chunks arrive.
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }
}

// MARK: - Waterfall geometry

/// Maps a session-relative time onto a fraction of the waterfall's width.
///
/// Split out from the view because it is the part that can be wrong in a way
/// nobody notices: a bar drawn at the wrong x is still a bar.
struct WaterfallScale: Equatable {
    /// Left edge, in seconds from the replay origin. Usually ≤ 0 — the browser
    /// buffers performance entries from before the recorder started, so real
    /// requests genuinely sit to the left of the first frame.
    let start: TimeInterval
    let end: TimeInterval

    /// A bar this thin is still a bar. Without a floor a 20 ms request in a
    /// 20 minute session is 1/60000 of the width and disappears — and the
    /// requests worth finding are often the short, failed ones.
    static let minimumBarFraction = 0.006

    init(start: TimeInterval, end: TimeInterval) {
        self.start = min(start, end)
        // A zero-width window divides by zero downstream; one second of an
        // empty session is a harmless floor.
        self.end = max(end, self.start + 1)
    }

    /// The window covering every entry plus the whole playable duration.
    init(entries: [ReplayNetworkEntry], origin: Date?, duration: TimeInterval) {
        guard let origin, !entries.isEmpty else {
            self.init(start: 0, end: max(duration, 1))
            return
        }
        let offsets = entries.map { $0.offset(from: origin) }
        let last = zip(offsets, entries).map { $0 + $1.duration }.max() ?? duration
        self.init(start: min(0, offsets.min() ?? 0), end: max(duration, last))
    }

    var span: TimeInterval { end - start }

    /// Position of an instant, 0…1.
    func fraction(at time: TimeInterval) -> Double {
        min(max((time - start) / span, 0), 1)
    }

    /// Left edge and width of a bar, 0…1, clamped into the window.
    func bar(at time: TimeInterval, duration: TimeInterval) -> (x: Double, width: Double) {
        let x = fraction(at: time)
        let right = fraction(at: time + max(duration, 0))
        return (x, max(right - x, Self.minimumBarFraction))
    }
}

// MARK: - Empty states

/// What to print when a pane has nothing in it.
///
/// Four outcomes, not two, because the data supports four. The one that matters
/// is `.unknown`: PostHog states which rrweb plugins loaded in a `type: 5`
/// custom event the recorder emits **once**, at startup, and a recording that
/// continues an already-running recorder never emits it. When it is not in the
/// blobs that were fetched, an empty console means either "switched off" or
/// "nothing logged" and there is no way to tell which — so the wording claims
/// neither.
struct ReplayCaptureNotice: Equatable {
    let icon: String
    let title: String
    let detail: String

    static func console(_ status: ReplayCaptureStatus) -> ReplayCaptureNotice {
        switch status {
        case .captured:
            ReplayCaptureNotice(icon: "text.append", title: "Console", detail: "")
        case .disabled:
            ReplayCaptureNotice(
                icon: "eye.slash",
                title: "Console recording was off",
                detail: """
                    The recorder for this session did not load rrweb's console plugin, \
                    so nothing the page logged was captured.
                    """
            )
        case .enabledButNone:
            ReplayCaptureNotice(
                icon: "checkmark.circle",
                title: "Nothing was logged",
                detail: "Console recording was on for this session. The page logged nothing."
            )
        case .unknown:
            ReplayCaptureNotice(
                icon: "questionmark.circle",
                title: "No console output here",
                detail: """
                    These snapshots don't name the plugins this recorder loaded, so this is \
                    either a session that logged nothing or one that wasn't capturing \
                    console output at all. GetHog can't tell the two apart from this data.
                    """
            )
        }
    }

    static func network(_ status: ReplayCaptureStatus) -> ReplayCaptureNotice {
        switch status {
        case .captured:
            ReplayCaptureNotice(icon: "chart.bar.doc.horizontal", title: "Network", detail: "")
        case .disabled:
            ReplayCaptureNotice(
                icon: "eye.slash",
                title: "Network recording was off",
                detail: """
                    The recorder for this session did not load rrweb's network plugin, \
                    so no request timing was captured.
                    """
            )
        case .enabledButNone:
            ReplayCaptureNotice(
                icon: "checkmark.circle",
                title: "No requests",
                detail: "Network recording was on for this session. The page made no requests."
            )
        case .unknown:
            ReplayCaptureNotice(
                icon: "questionmark.circle",
                title: "No requests here",
                detail: """
                    These snapshots don't name the plugins this recorder loaded, so this is \
                    either a session that fetched nothing or one that wasn't capturing \
                    request timing at all. GetHog can't tell the two apart from this data.
                    """
            )
        }
    }
}

// MARK: - Formatting

enum ReplayByteFormat {
    /// `nil` when the producer did not report a size, which is not zero.
    static func short(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        return Int64(bytes).formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb, .gb]))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms < 1 { return "<1 ms" }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        return "\((seconds).formatted(.number.precision(.fractionLength(seconds < 10 ? 2 : 1)))) s"
    }
}
