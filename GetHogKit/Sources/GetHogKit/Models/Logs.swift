import Foundation

// PostHog's `LogsQuery`.
//
// The warning that shaped this file is the same one on `Tracing.swift`, and for
// the same reason: the organisation this was built against has **no `viewer`
// access to the `logs` resource**, and PostHog reports that as an HTTP **400**,
// not a 403. So the decoders below have never been run against a real 200. Where
// a column could plausibly arrive in two spellings they read both rather than
// pick one and be silently wrong, and the *denied* state is modelled as a first
// class outcome rather than left to a generic error path.

// MARK: - State
// MARK: - Severity

public enum LogSeverity: String, Sendable, CaseIterable, Hashable {
    case fatal, error, warn, info, debug, trace, unknown

    /// Accepts the spellings the OpenTelemetry ecosystem actually emits rather
    /// than only PostHog's canonical set — a `warning` dropped to `.unknown`
    /// would quietly fall out of a severity filter.
    public init(text: String?) {
        switch text?.lowercased() {
        case "fatal", "critical", "crit": self = .fatal
        case "error", "err": self = .error
        case "warn", "warning": self = .warn
        case "info", "information", "notice": self = .info
        case "debug": self = .debug
        case "trace": self = .trace
        default: self = .unknown
        }
    }

    public var title: String {
        self == .unknown ? "Unknown" : rawValue.uppercased()
    }

    /// Worst first — the reason to open a log list is usually the errors in it.
    public var rank: Int {
        switch self {
        case .fatal: 0
        case .error: 1
        case .warn: 2
        case .info: 3
        case .debug: 4
        case .trace: 5
        case .unknown: 6
        }
    }

    /// True when the line is one someone should act on.
    public var isProblem: Bool { self == .fatal || self == .error }
}

// MARK: - Rows

public struct LogRow: Sendable, Identifiable, Hashable {
    public let id: String
    public let timestamp: Date?
    public let severity: LogSeverity
    public let body: String
    public let serviceName: String?
    public let traceID: String?

    public init(
        id: String,
        timestamp: Date?,
        severity: LogSeverity,
        body: String,
        serviceName: String?,
        traceID: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.body = body
        self.serviceName = serviceName
        self.traceID = traceID
    }

    /// The line as text, for the pasteboard.
    ///
    /// A log line's destination is a bug report or someone else's search box, so
    /// this is written to survive the trip: labelled metadata first, then a blank
    /// line, then the body verbatim. Metadata trailing the body would be scrolled
    /// past and lost under a stack trace, which is the case that matters.
    ///
    /// The trace id is written whole. The list row shows a 12-character prefix to
    /// fit its column, and a prefix pasted into PostHog's search matches nothing
    /// — worse than omitting the field, because it looks like it should work.
    ///
    /// Fields the query did not select are left out rather than printed empty: a
    /// `Service:` with nothing after it reads as a service that has no name.
    public var plainText: String {
        var header: [String] = []
        // `.unknown` is the absence of a severity column, not a severity, so it
        // is omitted on the same grounds as the optional fields below.
        if severity != .unknown { header.append("Severity: \(severity.title)") }
        // ISO-8601 rather than a localised date: whoever receives the paste is
        // not necessarily on the locale, or the continent, that produced it.
        if let timestamp { header.append("Time: \(timestamp.ISO8601Format())") }
        if let serviceName, !serviceName.isEmpty { header.append("Service: \(serviceName)") }
        if let traceID, !traceID.isEmpty { header.append("Trace: \(traceID)") }

        guard !header.isEmpty else { return body }
        return header.joined(separator: "\n") + "\n\n" + body
    }

    public static func rows(from response: QueryResponse) -> [LogRow] {
        response.rows.enumerated().compactMap { index, row in
            // A log line with no message is nothing a reader can use; rendering
            // it would put blank rows in the list.
            guard let body = row.string("body") ?? row.string("message"), !body.isEmpty else {
                return nil
            }
            return LogRow(
                // Falls back to the position so SwiftUI list identity stays
                // stable when the query selects no uuid.
                id: row.string("uuid") ?? row.string("id") ?? "row-\(index)",
                timestamp: row.date("timestamp") ?? row.date("observed_timestamp"),
                severity: LogSeverity(text: row.string("severity_text") ?? row.string("level")),
                body: body,
                serviceName: row.string("service_name") ?? row.string("resource.service.name"),
                traceID: row.string("trace_id")
            )
        }
    }
}
