import Foundation

/// PostHog emits ISO-8601 timestamps with microsecond precision
/// (`2026-07-29T22:12:30.588246Z`), sometimes without fractional seconds, and
/// trends `days[]` entries as bare days (`2026-06-29`). All three are accepted.
///
/// Uses `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter` because the
/// format styles are value types and therefore `Sendable` under Swift 6 strict
/// concurrency; the old formatters are not and cannot be shared statically.
public enum PostHogDate {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()
    private static let dayOnly = Date.ISO8601FormatStyle().year().month().day()

    public static func parse(_ string: String) -> Date? {
        if let d = try? Date(string, strategy: withFraction) { return d }
        if let d = try? Date(string, strategy: plain) { return d }
        return try? Date(string, strategy: dayOnly)
    }

    /// Parses a trends `days[]` entry, which may be a bare day or a full timestamp.
    public static func parseDay(_ string: String) -> Date? {
        if let d = try? Date(string, strategy: dayOnly) { return d }
        return parse(string)
    }
}
