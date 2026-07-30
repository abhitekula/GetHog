import Foundation

// The two remaining accepted web-analytics query kinds. They are kept together
// because they share nothing with the rest of the web models except the surface
// they feed, and each carries a decoding surprise worth reading in one place:
// external clicks labels its columns with dotted paths, and notable changes
// returns objects where every other table query returns positional arrays.

/// A `WebExternalClicksTableQuery` row: an outbound link and how much traffic
/// left through it.
public struct WebExternalClickRow: Sendable, Identifiable, Hashable {
    public let url: String
    public let visitors: Double
    public let clicks: Double

    public var id: String { url }

    public init(url: String, visitors: Double, clicks: Double) {
        self.url = url
        self.visitors = visitors
        self.clicks = clicks
    }

    /// Only web destinations are offered as links. The URL is data PostHog
    /// collected from a page, so a `javascript:` or custom-scheme value is
    /// entirely possible and must not become something the app will open.
    public var destination: URL? {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return parsed
    }

    public var host: String? { destination?.host() }

    public static func rows(from response: QueryResponse) -> [WebExternalClickRow] {
        response.rows.compactMap { row in
            guard let url = cell(row, "url")?.stringValue, !url.isEmpty else { return nil }
            return WebExternalClickRow(
                url: url,
                visitors: leading(row, "visitors"),
                clicks: leading(row, "clicks")
            )
        }
    }

    /// This query names its columns with dotted paths — `context.columns.url` —
    /// so a plain identifier never matches. Matching the trailing component too
    /// keeps the lookup working if PostHog ever drops the prefix.
    private static func cell(_ row: QueryRow, _ name: String) -> JSONValue? {
        if let exact = row.value("context.columns.\(name)") { return exact }
        guard
            let index = row.columns.firstIndex(where: { $0 == name || $0.hasSuffix(".\(name)") }),
            index < row.values.count
        else { return nil }
        let value = row.values[index]
        return value.isNull ? nil : value
    }

    /// Cells arrive as `[current, previous]` pairs, the same as
    /// `WebStatsTableQuery`. Reading one as a scalar yields nothing, which is
    /// indistinguishable from a genuinely empty report.
    private static func leading(_ row: QueryRow, _ name: String) -> Double {
        guard let cell = cell(row, name) else { return 0 }
        if case .array(let pair) = cell { return pair.first?.doubleValue ?? 0 }
        return cell.doubleValue ?? 0
    }
}

/// A `WebNotableChangesQuery` row: one dimension value PostHog considers worth
/// looking at, with the score it ranked it by.
public struct WebNotableChange: Sendable, Identifiable, Hashable {
    public let metric: String
    public let dimensionType: String
    public let dimensionValue: String
    public let currentValue: Double
    public let previousValue: Double?
    public let impactScore: Double

    /// Deliberately not public. Every caller must go through
    /// `comparablePercentChange`, which is the only reading of this field that
    /// is safe to put in front of someone.
    private let reportedPercentChange: Double?

    public var id: String { "\(metric)|\(dimensionType)|\(dimensionValue)" }

    public init(
        metric: String,
        dimensionType: String,
        dimensionValue: String,
        currentValue: Double,
        previousValue: Double?,
        percentChange: Double?,
        impactScore: Double
    ) {
        self.metric = metric
        self.dimensionType = dimensionType
        self.dimensionValue = dimensionValue
        self.currentValue = currentValue
        self.previousValue = previousValue
        self.reportedPercentChange = percentChange
        self.impactScore = impactScore
    }

    /// The API's `percent_change`, surfaced only when a previous period exists to
    /// compare against.
    ///
    /// PostHog returns a constant `percent_change` of 10.0 against a
    /// `previous_value` of 0 on every row, at every date range tried from -7d to
    /// -180d. A single percentage repeated across eight unrelated dimensions,
    /// measured against zero, is a placeholder rather than a measurement, and
    /// printing it would present a sentinel as a finding. Recomputing the change
    /// from `currentValue / previousValue` is not an escape either — that divides
    /// by zero and yields an infinity.
    public var comparablePercentChange: Double? {
        guard let previousValue, previousValue != 0, let reportedPercentChange else { return nil }
        return reportedPercentChange
    }

    public var hasComparablePrevious: Bool { comparablePercentChange != nil }

    /// Bounce and exit rates improve by *falling*, so a single "up is good" rule
    /// would frame a worsening site as a win.
    public var isIncreaseBad: Bool {
        let lowered = metric.lowercased()
        return lowered.contains("bounce") || lowered.contains("exit rate")
    }

    /// Nil when there is nothing to compare — which is every row, today.
    public var isImprovement: Bool? {
        guard let change = comparablePercentChange, change != 0 else { return nil }
        return (change > 0) != isIncreaseBad
    }

    public var displayMetric: String {
        metric.prefix(1).uppercased() + metric.dropFirst()
    }

    /// Never empty: this is drawn as a pill, and an unlabelled pill is worse
    /// than a generic one.
    public var displayDimension: String {
        dimensionType.isEmpty ? "Dimension" : dimensionType
    }

    public var displayValue: String {
        switch dimensionValue {
        // PostHog's sentinel for "arrived with no referrer"; shown raw it reads
        // like a broken variable.
        case "$direct": "Direct"
        case "": "(not set)"
        default: dimensionValue
        }
    }
}

public struct WebNotableChangesResponse: Sendable, Decodable {
    public let changes: [WebNotableChange]

    enum CodingKeys: String, CodingKey { case results }

    private struct Row: Decodable {
        let metric: String?
        let dimensionType: String?
        let dimensionValue: String?
        let currentValue: Double?
        let previousValue: Double?
        let percentChange: Double?
        let impactScore: Double?

        enum CodingKeys: String, CodingKey {
            case metric
            case dimensionType = "dimension_type"
            case dimensionValue = "dimension_value"
            case currentValue = "current_value"
            case previousValue = "previous_value"
            case percentChange = "percent_change"
            case impactScore = "impact_score"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unlike every other table query, `results` holds objects and there is no
        // parallel `columns` array to position them against.
        let rows = (try? container.decodeIfPresent([Row].self, forKey: .results)) ?? []

        changes = rows.compactMap { row -> WebNotableChange? in
            guard let metric = row.metric, let value = row.dimensionValue else { return nil }
            return WebNotableChange(
                metric: metric,
                dimensionType: row.dimensionType ?? "",
                dimensionValue: value,
                currentValue: row.currentValue ?? 0,
                previousValue: row.previousValue,
                percentChange: row.percentChange,
                impactScore: row.impactScore ?? 0
            )
        }
        // Sorted here rather than trusted from the wire: the ranking is the whole
        // point of the screen, and the API makes no ordering promise.
        .sorted { $0.impactScore > $1.impactScore }
    }

    public static func decode(from data: Data) throws -> WebNotableChangesResponse {
        try JSONDecoder().decode(WebNotableChangesResponse.self, from: data)
    }

    public var isEmpty: Bool { changes.isEmpty }
}
