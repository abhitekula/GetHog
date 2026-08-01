import Foundation

// Usage figures for query endpoints — saved queries a project publishes over
// HTTP. Two shapes, and they are not the same kind of response:
//
//   * `EndpointsUsageOverviewQuery` answers with *objects* keyed by name, the
//     same envelope `WebOverviewQuery` uses, so it decodes directly.
//   * `EndpointsUsageTableQuery` answers with ordinary positional `/query/`
//     rows. The row type below takes its labels from the response's own
//     `columns` array because the query defines its columns at runtime.

/// The dimension a usage table is broken down by.
///
/// Closed server-side: `breakdownBy` is an enum, and anything outside these four
/// is rejected with a 400 that lists them back. The raw values are the exact
/// spellings the API accepts, capitalisation included.
public enum EndpointUsageDimension: String, Sendable, CaseIterable, Identifiable, Hashable {
    case endpoint = "Endpoint"
    case materializationType = "MaterializationType"
    case apiKey = "ApiKey"
    case status = "Status"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .endpoint: "Endpoint"
        case .materializationType: "Materialisation"
        case .apiKey: "API key"
        case .status: "Status"
        }
    }

    public var systemImage: String {
        switch self {
        case .endpoint: "network"
        case .materializationType: "cube"
        case .apiKey: "key"
        case .status: "checkmark.seal"
        }
    }
}

/// What a set of usage figures actually means.
///
/// The distinction this type exists for: **zero requests because no endpoint is
/// defined** and **zero requests because nobody called one** are different
/// statements, and a bare "0" says the second while meaning the first. Getting
/// that backwards would report a healthy project as a dead one.
public enum EndpointUsageReading: Sendable, Equatable {
    /// No query endpoints exist, so every figure is zero by definition and none
    /// of it is a fact about traffic.
    case noEndpointsDefined
    /// Endpoints exist and none was called in this window.
    case noTraffic
    case traffic

    public var summary: String {
        switch self {
        case .noEndpointsDefined:
            "This project has no query endpoints, so there is nothing to have been called."
        case .noTraffic:
            "No endpoint was called in this window."
        case .traffic:
            "Requests served by this project's query endpoints."
        }
    }
}

/// One metric from `EndpointsUsageOverviewQuery`.
public struct EndpointUsageMetric: Sendable, Decodable, Identifiable, Hashable {
    public let key: String
    public let value: Double?
    /// The same metric over the preceding window. Null means no comparison was
    /// supplied, which is not the same as zero — see `hasComparison`.
    public let previous: Double?
    public let changeFromPreviousPct: Double?

    public var id: String { key }

    public init(key: String, value: Double?, previous: Double?, changeFromPreviousPct: Double?) {
        self.key = key
        self.value = value
        self.previous = previous
        self.changeFromPreviousPct = changeFromPreviousPct
    }

    /// False when PostHog reported no comparison at all. Drawing a 0% delta in
    /// that case would assert a flat trend the API never claimed.
    public var hasComparison: Bool { previous != nil && changeFromPreviousPct != nil }

    public var title: String { humanised(key) }

    public var formattedValue: String {
        guard let value else { return "—" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

/// Response envelope for `EndpointsUsageOverviewQuery`.
public struct EndpointUsageOverview: Sendable, Decodable {
    public let metrics: [EndpointUsageMetric]

    enum CodingKeys: String, CodingKey { case results }

    public init(metrics: [EndpointUsageMetric]) {
        self.metrics = metrics
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = (try? c.decodeIfPresent([EndpointUsageMetric].self, forKey: .results)) ?? []
    }

    public static func decode(from data: Data) throws -> EndpointUsageOverview {
        try JSONDecoder().decode(EndpointUsageOverview.self, from: data)
    }

    public func metric(named key: String) -> EndpointUsageMetric? {
        metrics.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Reads the figures in the light of how many endpoints exist.
    ///
    /// The endpoint count has to come from the caller: the usage query answers
    /// happily with zeros whether or not there is anything to measure, so on its
    /// own it cannot tell the two apart.
    public func reading(endpointCount: Int) -> EndpointUsageReading {
        guard endpointCount > 0 else { return .noEndpointsDefined }
        let sawTraffic = metrics.contains { ($0.value ?? 0) != 0 }
        return sawTraffic ? .traffic : .noTraffic
    }
}

/// One row of `EndpointsUsageTableQuery`, labelled from the response itself.
///
/// Deliberately schema-free. This query's columns are response-defined, so
/// hard-coding names would risk printing a confident wrong label over a number.
/// Reading them back from `columns` cannot mislabel anything.
public struct EndpointUsageBreakdownRow: Sendable, Identifiable, Hashable {
    public struct Measure: Sendable, Hashable {
        public let name: String
        public let value: Double
    }

    /// The breakdown value — always the first column for this query family.
    public let label: String
    public let measures: [Measure]

    public var id: String { label }

    public static func rows(from response: QueryResponse) -> [EndpointUsageBreakdownRow] {
        response.rows.compactMap { row in
            guard let first = row.values.first else { return nil }
            let label = first.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Not set"

            let measures = zip(response.columns.dropFirst(), row.values.dropFirst())
                .compactMap { column, value -> Measure? in
                    guard let number = value.doubleValue, number.isFinite else { return nil }
                    return Measure(name: humanised(column), value: number)
                }

            return EndpointUsageBreakdownRow(label: label, measures: measures)
        }
    }
}

/// Turns an API key like `total_requests` into `Total requests`.
///
/// File-private so concurrent work elsewhere cannot collide with the name.
private func humanised(_ key: String) -> String {
    let spaced = key.replacingOccurrences(of: "_", with: " ")
    guard let first = spaced.first else { return spaced }
    return first.uppercased() + spaced.dropFirst()
}
