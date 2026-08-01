import Foundation

/// A paginated list response from a PostHog collection endpoint.
public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    public let count: Int?
    public let next: String?
    public let previous: String?
    public let results: [T]

    public static func decode(from data: Data) throws -> Page<T> {
        try JSONDecoder().decode(Page<T>.self, from: data)
    }
}

/// Response from `POST /api/projects/:id/query/`.
///
/// Results are **column-oriented**: `results` is an array of positional arrays,
/// and the meaning of each position comes from the parallel `columns` array.
public struct QueryResponse: Decodable, Sendable {
    public let columns: [String]
    public let types: [[String]]?
    public let rows: [QueryRow]
    /// Whether PostHog is holding rows back.
    ///
    /// A HogQL query with no `LIMIT` of its own can be capped by PostHog. The
    /// envelope's flag and `appliedLimit` are the only completeness signals.
    ///
    /// `false` when absent, which is the safe reading **provided the caller
    /// remembers what absence means**: PostHog omits both fields entirely for a
    /// query that wrote its own `LIMIT`, reached it or not — so `false` here is
    /// routinely "no cap of mine applied" rather than "there was no more". See
    /// `isTruncated`, which carries the measurement and what to do about it. A
    /// Callers that write their own limit compare it with the raw row count.
    public let hasMore: Bool
    /// The cap PostHog actually applied, whether or not this query asked for one.
    public let appliedLimit: Int?

    /// True when **PostHog's own default cap** held rows back.
    ///
    /// **This is not a general truncation check, and reading it as one is a bug
    /// this comment previously invited.** It used to say "true when the answer is
    /// a prefix of the real one" and to instruct callers to read it before
    /// reporting any count or total. That overstates it in the direction that
    /// matters: `false` here does not mean the result is complete.
    ///
    /// PostHog reports only the cap *it*
    /// applied; a `LIMIT` the caller wrote is the caller's business and the
    /// envelope says nothing about it, **even when that limit was reached and
    /// rows were genuinely withheld**. Most builders in this package write an
    /// explicit `LIMIT` precisely to escape the 100-row default, so for most of
    /// this app's queries this property is structurally silent.
    ///
    /// What that means at a call site:
    ///
    /// - **A query with no `LIMIT` of its own** — the SQL console, where the
    ///   reader writes the statement — this is the only evidence there is, and
    ///   it is reliable. Use it.
    /// - **A query that writes its own `LIMIT`** — read `rows.count` against
    ///   that limit, and `||` it with this so a *lower* server cap is still
    ///   caught. Count the rows PostHog returned, never the values that survived
    ///   decoding: a failable row initialiser puts a full page one under its
    ///   ceiling and retires the notice exactly when the data is least
    ///   trustworthy. `SessionTimelineStore` and `SchemaStore` are the worked
    ///   examples.
    /// - **A total, a mean or a share** — neither signal is sufficient. Have the
    ///   query carry its own denominators: `sum(count()) OVER ()` is evaluated
    ///   before `LIMIT`, so the screen knows the real total instead of inferring
    ///   one. Deriving a figure from a truncated set produces a wrong number,
    ///   not merely a partial list.
    public var isTruncated: Bool { hasMore }

    enum CodingKeys: String, CodingKey {
        case columns, types, results, hasMore, limit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        self.columns = columns
        self.types = try? c.decodeIfPresent([[String]].self, forKey: .types)
        let raw = try c.decodeIfPresent([[JSONValue]].self, forKey: .results) ?? []
        self.rows = raw.map { QueryRow(columns: columns, values: $0) }
        self.hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) as? Bool ?? false
        self.appliedLimit = (try? c.decodeIfPresent(Int.self, forKey: .limit)) ?? nil
    }

    public static func decode(from data: Data) throws -> QueryResponse {
        try JSONDecoder().decode(QueryResponse.self, from: data)
    }

    /// The oldest value in `column`.
    ///
    /// PostHog rejects OFFSET pagination for personal API keys (HTTP 400), so
    /// paging has to be keyset. Not sufficient on its own for a feed keyed on
    /// `timestamp`, though: timestamps are not unique — three live events share
    /// one microsecond — and `WHERE timestamp < cursor` silently drops the
    /// remainder of any tie group a page boundary cuts through. Use
    /// `eventCursor()`, which carries the uuid tiebreak, for anything paging the
    /// `events` table.
    public func keysetCursor(column: String) -> Date? {
        rows.compactMap { $0.date(column) }.min()
    }
}

public struct QueryRow: Sendable {
    public let columns: [String]
    public let values: [JSONValue]

    /// Public so a consumer outside this package can build a row.
    ///
    /// The type is public and both its properties are, but the memberwise
    /// initialiser defaulted to internal — so the app's own test target, which
    /// is a different module, could read a `QueryRow` and not construct one.
    /// That is only ever felt by a test wanting a row without a whole recorded
    /// `/query/` response behind it, which is exactly the case worth serving.
    public init(columns: [String], values: [JSONValue]) {
        self.columns = columns
        self.values = values
    }

    public func value(_ column: String) -> JSONValue? {
        guard let idx = columns.firstIndex(of: column), idx < values.count else { return nil }
        let v = values[idx]
        return v.isNull ? nil : v
    }

    public func string(_ column: String) -> String? { value(column)?.stringValue }
    public func double(_ column: String) -> Double? { value(column)?.doubleValue }
    public func int(_ column: String) -> Int? { value(column)?.intValue }
    public func date(_ column: String) -> Date? { string(column).flatMap(PostHogDate.parse) }
}

/// A row from the events feed.
public struct EventRow: Sendable, Identifiable, Hashable {
    public let id: String
    public let event: String
    public let timestamp: Date?
    public let distinctID: String?
    public let currentURL: String?
    public let properties: JSONValue?

    public init?(row: QueryRow) {
        guard let event = row.string("event") else { return nil }
        self.event = event
        self.timestamp = row.date("timestamp")
        self.distinctID = row.string("distinct_id")
        self.currentURL = row.string("$current_url") ?? row.string("properties.$current_url")
        self.properties = row.value("properties")
        // uuid when selected, otherwise a stable composite so SwiftUI lists are stable
        self.id = row.string("uuid")
            ?? "\(event)|\(row.string("timestamp") ?? "")|\(row.string("distinct_id") ?? "")"
    }

    public static func == (a: EventRow, b: EventRow) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
