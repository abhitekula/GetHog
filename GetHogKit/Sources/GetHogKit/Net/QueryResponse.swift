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

    enum CodingKeys: String, CodingKey {
        case columns, types, results
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        self.columns = columns
        self.types = try? c.decodeIfPresent([[String]].self, forKey: .types)
        let raw = try c.decodeIfPresent([[JSONValue]].self, forKey: .results) ?? []
        self.rows = raw.map { QueryRow(columns: columns, values: $0) }
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

    init(columns: [String], values: [JSONValue]) {
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
