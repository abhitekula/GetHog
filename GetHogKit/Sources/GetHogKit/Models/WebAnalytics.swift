import Foundation

/// Response from a `WebOverviewQuery`.
public struct WebOverviewResponse: Sendable, Decodable {
    public let metrics: [WebOverviewMetric]

    enum CodingKeys: String, CodingKey { case results }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = (try? c.decodeIfPresent([WebOverviewMetric].self, forKey: .results)) ?? []
    }

    public static func decode(from data: Data) throws -> WebOverviewResponse {
        try JSONDecoder().decode(WebOverviewResponse.self, from: data)
    }

    public func metric(named key: String) -> WebOverviewMetric? {
        metrics.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}

public struct WebOverviewMetric: Sendable, Decodable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Decodable {
        case unit
        case durationSeconds = "duration_s"
        case percentage
        case currency
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public let key: String
    public let kind: Kind
    public let value: Double?
    public let previous: Double?
    public let changeFromPreviousPct: Double?
    /// Some metrics improve by going *down* (bounce rate), so a trend arrow that
    /// always treats "up" as good would be actively misleading.
    public let isIncreaseBad: Bool?

    public var id: String { key }

    public var title: String { key.capitalized }

    public var formattedValue: String {
        guard let value else { return "—" }
        switch kind {
        case .unit:
            return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case .durationSeconds:
            let total = Int(value.rounded())
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            if h > 0 { return "\(h)h \(m)m" }
            if m > 0 { return "\(m)m \(s)s" }
            return "\(s)s"
        case .percentage:
            // Already expressed in percent (41.2 means 41.2%), not a 0...1 fraction.
            return (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
        case .currency:
            return value.formatted(.currency(code: "USD"))
        case .unknown:
            return value.formatted(.number.precision(.fractionLength(0...2)))
        }
    }

    /// True when the change should be drawn as an improvement.
    public var isImprovement: Bool? {
        guard let change = changeFromPreviousPct, change != 0 else { return nil }
        return (change > 0) != (isIncreaseBad ?? false)
    }
}

/// A `WebStatsTableQuery` row.
///
/// Values arrive as `[current, previous]` pairs rather than scalars, so the
/// current figure is the first element.
public struct WebStatsRow: Sendable, Identifiable, Hashable {
    public let breakdownValue: String
    public let visitors: Double
    public let views: Double

    public var id: String { breakdownValue }

    public init(breakdownValue: String, visitors: Double, views: Double) {
        self.breakdownValue = breakdownValue
        self.visitors = visitors
        self.views = views
    }

    /// Builds rows from the generic column-oriented query response.
    ///
    /// **A breakdown value is not always a string.** Depending on the selected
    /// dimension, `WebStatsTableQuery` can return a string, number, array, or
    /// null in the first column:
    ///
    ///     Page or browser                           "sample"           string
    ///     Unset campaign property                   null               null
    ///     Timezone                                  numeric offset     number
    ///     Viewport or location                      ordered parts      array
    ///
    /// `JSONValue.stringValue` is `nil` for `.null` and `.array`. Using it as a
    /// row gate would therefore discard valid compound dimensions and the
    /// meaningful "not set" bucket, distorting both the list and its proportions.
    ///
    /// So nothing is dropped now, and the label is the caller's decision.
    /// `label` defaults to `plainLabel`, which is faithful but generic; the app
    /// passes `WebStatsDimension.label(for:)`, because only the caller knows
    /// that an ordered string pair is a location and a number is an hour offset.
    /// Keeping
    /// that knowledge out of here is the same rule `InsightRenderModel` follows:
    /// the kit decodes shapes, the app names them.
    public static func rows(
        from response: QueryResponse,
        label: (JSONValue) -> String = Self.plainLabel
    ) -> [WebStatsRow] {
        response.rows.map { row in
            WebStatsRow(
                breakdownValue: label(row.values.first ?? .null),
                visitors: leading(row.values, at: 1),
                views: leading(row.values, at: 2)
            )
        }
    }

    /// A faithful, dimension-blind rendering of a breakdown value.
    ///
    /// Used when the caller has no dimension in hand. Arrays are joined with a
    /// comma in the order the API sent them and `null` becomes the empty string,
    /// which `WebStatsRowView` already draws as "(not set)" — so an unnamed
    /// bucket is visible and countable rather than absent.
    public static func plainLabel(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return ""
        case .array(let parts):
            return parts.compactMap(\.stringValue).joined(separator: ", ")
        default:
            return value.stringValue ?? ""
        }
    }

    private static func leading(_ values: [JSONValue], at index: Int) -> Double {
        guard index < values.count else { return 0 }
        if case .array(let pair) = values[index] { return pair.first?.doubleValue ?? 0 }
        return values[index].doubleValue ?? 0
    }
}
