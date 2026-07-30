import Foundation

/// Severity of one captured console line.
///
/// Three cases rather than the dozen `console` methods rrweb hooks, because
/// three is what PostHog itself counts — `console_log_count`,
/// `console_warn_count`, `console_error_count` are already on every
/// `SessionRecording`, and a filter that does not line up with the number
/// printed beside it is worse than a coarse one. The exact word rrweb sent is
/// kept on the entry as `rawLevel`, so nothing is lost.
public enum ReplayConsoleLevel: String, Sendable, Hashable, CaseIterable, Codable {
    case log
    case warn
    case error

    /// Maps an rrweb console level onto the three PostHog counts.
    ///
    /// Anything unrecognised is a log rather than dropped: rrweb hooks methods
    /// this app has never seen (`table`, `dirxml`, `countReset`), and a new one
    /// should show up in the list, not vanish from it.
    public init(rrweb level: String) {
        switch level.lowercased() {
        case "error", "assert": self = .error
        case "warn", "warning": self = .warn
        default: self = .log
        }
    }
}

/// One line the recorded page wrote to its console.
public struct ReplayConsoleEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let level: ReplayConsoleLevel
    /// The word rrweb sent — `debug`, `table`, `assert` — before it was bucketed.
    public let rawLevel: String
    /// One display string per console argument, already unwrapped from the JSON
    /// encoding rrweb applies to each of them.
    public let parts: [String]
    /// Where the call came from, innermost frame first. Frequently empty.
    public let trace: [String]
    public let timestamp: Date

    public init(
        id: String,
        level: ReplayConsoleLevel,
        rawLevel: String,
        parts: [String],
        trace: [String],
        timestamp: Date
    ) {
        self.id = id
        self.level = level
        self.rawLevel = rawLevel
        self.parts = parts
        self.trace = trace
        self.timestamp = timestamp
    }

    /// The first argument — what `console.error("x", err)` was actually about.
    public var summary: String { parts.first ?? "" }

    /// Everything after the first argument.
    public var detail: [String] { Array(parts.dropFirst()) }

    /// The whole line as one string, for search and for VoiceOver.
    public var message: String { parts.joined(separator: " ") }

    /// Seconds from the instant the replay is measured from.
    public func offset(from origin: Date) -> TimeInterval {
        timestamp.timeIntervalSince(origin)
    }
}

// MARK: - Parsing

extension ReplayConsoleEntry {

    /// rrweb's console plugin name, as PostHog emits it. Verified against
    /// captured `blob_v2` data rather than taken from the rrweb docs.
    static let pluginName = "rrweb/console@1"

    /// Builds an entry from one `type: 6` plugin event's `data.payload`.
    ///
    /// Returns `nil` for anything that is not the documented shape — the
    /// snapshot API is internal, and a payload change must cost this one line
    /// rather than the whole pane.
    static func make(payload: JSONValue, timestampMS: Double, id: String) -> ReplayConsoleEntry? {
        guard let rawLevel = payload["level"]?.stringValue else { return nil }
        guard case .array(let rawParts)? = payload["payload"] else { return nil }

        var trace: [String] = []
        if case .array(let frames)? = payload["trace"] {
            trace = frames.compactMap(\.stringValue)
        }

        return ReplayConsoleEntry(
            id: id,
            level: ReplayConsoleLevel(rrweb: rawLevel),
            rawLevel: rawLevel,
            parts: rawParts.compactMap(\.stringValue).map(Self.display),
            trace: trace,
            timestamp: Date(timeIntervalSince1970: timestampMS / 1000)
        )
    }

    /// Unwraps one console argument.
    ///
    /// rrweb stringifies every argument before it ships, so a logged *string*
    /// arrives already JSON-encoded: `console.error("boom")` becomes the six
    /// characters `"boom"`, quote marks included, and any newline inside it is
    /// a literal backslash-n. Printing that raw puts the quoting on screen —
    /// measured on real captured data, where the common shape is
    /// `"\"TypeError: Failed to fetch\\n    at M (…)\""`.
    ///
    /// An object or array argument is *already* the JSON text a reader wants,
    /// so it is returned untouched rather than re-serialised through a
    /// dictionary whose key order would be arbitrary.
    static func display(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]
              )
        else { return raw }
        return (decoded as? String) ?? raw
    }
}
