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
    /// **A HogQL query with no `LIMIT` of its own is silently capped at 100.**
    /// Measured: a `system.information_schema.tables` scan of a 141-table
    /// project returned 100 rows, HTTP 200, no error and no warning — the only
    /// evidence anywhere in the payload is this flag and `appliedLimit` below.
    /// Until they were decoded, nothing in this client could tell a complete
    /// answer from the first hundredth of one, and every caller that omitted a
    /// `LIMIT` was free to present a prefix as the whole set.
    ///
    /// `false` when absent, which is the safe reading **provided the caller
    /// remembers what absence means**: PostHog omits both fields entirely for a
    /// query that wrote its own `LIMIT`, reached it or not — so `false` here is
    /// routinely "no cap of mine applied" rather than "there was no more". See
    /// `isTruncated`, which carries the measurement and what to do about it. A
    /// `nil` would have to be handled at every call site to mean anything, and a
    /// caller that ignores it is worse off than one told plainly there is more.
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
    /// Measured on this deployment, and recorded at greater length on
    /// `PostHogAPI.groupEventBreakdown`. The same query, three ways:
    ///
    ///     no LIMIT,  63 rows of 63    hasMore: false, limit: 100
    ///     no LIMIT, 100 rows of 423   hasMore: true,  limit: 100
    ///     LIMIT 200, 200 rows of 423  neither field present
    ///
    /// The third line is the whole point. PostHog reports only the cap *it*
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
    ///   one. `PostHogAPI.groupEventBreakdown` measured this against a property
    ///   with 423 distinct values, where `LIMIT 5` still reported the true 3320.
    ///   Deriving a figure from a truncated set produces a number that is wrong
    ///   rather than merely partial — the failure this project has already hit
    ///   twice, once where `/heatmaps/` returned 500 rows against its own
    ///   `total_count` of 899, and once where a survey mean read 5.00 against a
    ///   true 2.75.
    ///
    /// One observation is **not reconciled** and is recorded rather than
    /// smoothed over: `InsightCSV` documents `SELECT number FROM numbers(50000)`
    /// with no `LIMIT` returning all 50,000 rows on the same deployment and the
    /// same day the 100-row cap was measured. Whether the default applies to
    /// generator functions, or the two measurements differ in some other way, has
    /// not been established here. Nothing in this package depends on the answer —
    /// every rule above is about what the *envelope* says, not about when the cap
    /// fires — but a caller reasoning about "the 100-row default" as universal
    /// should know it has a counter-example.
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
