import Foundation

public struct Insight: Sendable, Decodable, Identifiable {
    public let id: Int
    public let name: String?
    public let derivedName: String?
    public let query: InsightQuery?

    /// The `query` subtree exactly as PostHog sent it.
    ///
    /// `InsightQuery` keeps only what rendering needs — the kind and the display
    /// type. Rebuilding a request from that would drop the series definitions,
    /// property filters and breakdowns, and return a different insight's numbers
    /// under the user's title. Re-running over a new date range therefore edits
    /// this verbatim copy instead.
    public let rawQuery: JSONValue?

    /// Raw, shape-tolerant result payload. All polymorphism lives here so the
    /// rest of the codebase only ever sees `InsightRenderModel`.
    let result: RawResult

    enum CodingKeys: String, CodingKey {
        case id, name, query, result
        case derivedName = "derived_name"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        derivedName = try c.decodeIfPresent(String.self, forKey: .derivedName)
        query = try? c.decodeIfPresent(InsightQuery.self, forKey: .query)
        rawQuery = try? c.decodeIfPresent(JSONValue.self, forKey: .query)
        result = (try? c.decodeIfPresent(RawResult.self, forKey: .result)) ?? .unknown
    }

    public var title: String {
        if let name, !name.isEmpty { return name }
        if let derivedName, !derivedName.isEmpty { return derivedName }
        return "Untitled"
    }

    /// The insight kind as PostHog names it, e.g. `TrendsQuery`.
    public var sourceKind: String { query?.source?.kind ?? "Unknown" }

    /// The runnable node inside the saved query.
    ///
    /// A saved insight is wrapped in an `InsightVizNode`, which `/query/` will
    /// not execute; the `source` beneath it is the query proper.
    public var rawSource: JSONValue? {
        guard case .object(let fields)? = rawQuery else { return nil }
        return fields["source"]
    }

    /// Dispatch is on the declared query kind, never on the result's shape:
    /// lifecycle results carry `data`/`days` exactly like trends, so shape
    /// sniffing would silently draw a wrong chart.
    public var renderModel: InsightRenderModel {
        Self.renderModel(result: result, sourceKind: sourceKind, display: displayType)
    }

    /// The stored display type, e.g. `ActionsBarValue`.
    ///
    /// Exposed because re-running the insight over a new date range has to draw
    /// it the same way; the response alone cannot say whether a trends result
    /// was meant to be a line, a bar or a single bold number.
    public var displayType: String? { query?.source?.trendsFilter?.display }

    /// Shared by the saved result and by a re-run over a different window, so
    /// the two can never diverge in how they interpret the same payload.
    ///
    /// Dispatch is on the declared query kind, never on the result's shape:
    /// lifecycle results carry `data`/`days` exactly like trends, so shape
    /// sniffing would silently draw a wrong chart.
    static func renderModel(
        result: RawResult,
        sourceKind: String,
        display: String?
    ) -> InsightRenderModel {
        switch sourceKind {
        case "TrendsQuery":
            switch display {
            // Aggregated displays have no time axis: the figure is in
            // `aggregated_value` and `data` is empty.
            case "ActionsBarValue", "ActionsPie", "ActionsTable":
                return .barValue(result.seriesDTOs.map(\.asBarValue))
            case "BoldNumber":
                guard let first = result.seriesDTOs.first else { return .unsupported(kind: sourceKind) }
                return .bigNumber(BigNumber(label: first.label ?? "", value: first.headlineValue))
            default:
                return .timeSeries(
                    result.seriesDTOs.map(\.asSeries),
                    style: TimeSeriesStyle(display: display)
                )
            }

        case "FunnelsQuery":
            let groups = result.funnelGroups
            return groups.isEmpty ? .unsupported(kind: sourceKind) : .funnel(groups)

        case "LifecycleQuery":
            let series = result.seriesDTOs.map(\.asLifecycleSeries)
            return series.isEmpty ? .unsupported(kind: sourceKind) : .lifecycle(series)

        case "RetentionQuery":
            let cohorts = result.retentionCohorts
            return cohorts.isEmpty ? .unsupported(kind: sourceKind) : .retention(RetentionGrid(cohorts: cohorts))

        case "StickinessQuery":
            let series = result.seriesDTOs.map(\.asStickinessSeries)
            return series.isEmpty ? .unsupported(kind: sourceKind) : .stickiness(series)

        case "PathsQuery":
            let edges = result.pathEdges
            return edges.isEmpty ? .unsupported(kind: sourceKind) : .paths(PathsGraph(edges: edges))

        default:
            return .unsupported(kind: sourceKind)
        }
    }
}

public struct InsightQuery: Sendable, Decodable {
    public let kind: String?
    public let source: QuerySource?
}

public struct QuerySource: Sendable, Decodable {
    public let kind: String
    public let trendsFilter: TrendsFilter?
}

public struct TrendsFilter: Sendable, Decodable {
    public let display: String?
}

// MARK: - Result payload

/// `insight.result` is polymorphic across insight types. Decoding tries each
/// known shape in turn and falls back to `.unknown`, so an unrecognised payload
/// degrades one tile instead of failing the whole dashboard.
enum RawResult: Sendable, Decodable {
    case series([TrendsSeriesDTO])
    case funnelGroups([[FunnelStepDTO]])
    case funnelSteps([FunnelStepDTO])
    case retention([RetentionCohortDTO])
    case paths([PathEdgeDTO])
    case unknown

    init(from decoder: any Decoder) throws {
        // Retention is checked before trends: its cohorts carry `values`, which
        // no other shape has, so this is unambiguous.
        if let cohorts = try? [RetentionCohortDTO](from: decoder),
           cohorts.contains(where: { $0.values != nil }) {
            self = .retention(cohorts); return
        }
        // Paths edges are the only shape carrying both `source` and `target`.
        if let edges = try? [PathEdgeDTO](from: decoder),
           edges.contains(where: { $0.source != nil && $0.target != nil }) {
            self = .paths(edges); return
        }
        if let groups = try? [[FunnelStepDTO]](from: decoder), !groups.isEmpty {
            self = .funnelGroups(groups); return
        }
        if let series = try? [TrendsSeriesDTO](from: decoder), series.contains(where: \.looksLikeTrends) {
            self = .series(series); return
        }
        if let steps = try? [FunnelStepDTO](from: decoder), steps.contains(where: { $0.order != nil }) {
            self = .funnelSteps(steps); return
        }
        if let series = try? [TrendsSeriesDTO](from: decoder) {
            self = .series(series); return
        }
        self = .unknown
    }

    var seriesDTOs: [TrendsSeriesDTO] {
        if case .series(let s) = self { return s }
        return []
    }

    var funnelGroups: [FunnelGroup] {
        switch self {
        case .funnelGroups(let groups):
            return groups.map { steps in
                FunnelGroup(
                    breakdownValue: steps.first?.breakdownValue?.display,
                    steps: steps.map(\.asStep)
                )
            }
        case .funnelSteps(let steps):
            return [FunnelGroup(breakdownValue: nil, steps: steps.map(\.asStep))]
        default:
            return []
        }
    }

    var retentionCohorts: [RetentionCohort] {
        guard case .retention(let dtos) = self else { return [] }
        return dtos.map(\.asCohort)
    }

    var pathEdges: [PathEdge] {
        guard case .paths(let dtos) = self else { return [] }
        return dtos.compactMap(\.asEdge)
    }
}

struct PathEdgeDTO: Sendable, Decodable {
    let source: String?
    let target: String?
    let value: Double?
    let averageConversionTime: Double?

    enum CodingKeys: String, CodingKey {
        case source, target, value
        case averageConversionTime = "average_conversion_time"
    }

    var asEdge: PathEdge? {
        guard let source, let target else { return nil }
        return PathEdge(
            rawSource: source,
            rawTarget: target,
            value: value ?? 0,
            averageConversionTime: averageConversionTime
        )
    }
}

struct RetentionCohortDTO: Sendable, Decodable {
    let label: String?
    let date: String?
    let values: [RetentionValueDTO]?

    var asCohort: RetentionCohort {
        RetentionCohort(
            label: label ?? "",
            date: date.flatMap(PostHogDate.parse),
            counts: (values ?? []).map { $0.count ?? 0 }
        )
    }
}

struct RetentionValueDTO: Sendable, Decodable {
    let count: Double?
    let label: String?
}

struct TrendsSeriesDTO: Sendable, Decodable {
    let label: String?
    let count: Double?
    let data: [Double]?
    /// Raw `days` entries. Trends sends date strings; stickiness sends interval
    /// numbers, so this is decoded permissively and normalised by `dayLabels`.
    let rawDays: [JSONValue]?
    let aggregatedValue: Double?
    /// Present only on lifecycle results.
    let status: String?

    init(
        label: String?, count: Double?, data: [Double]?, days: [String]?,
        aggregatedValue: Double?, status: String?
    ) {
        self.label = label
        self.count = count
        self.data = data
        self.rawDays = days?.map { .string($0) }
        self.aggregatedValue = aggregatedValue
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case label, count, data, status
        case rawDays = "days"
        case aggregatedValue = "aggregated_value"
    }

    /// `days` as strings regardless of whether PostHog sent strings or numbers.
    /// Typing it as `[String]` alone drops stickiness entirely — the array fails
    /// to decode, `days` becomes nil, and the chart renders empty with no error.
    var dayLabels: [String]? {
        rawDays?.compactMap(\.stringValue)
    }

    var days: [String]? { dayLabels }

    var lifecycleStatus: LifecycleStatus {
        LifecycleStatus(rawValue: (status ?? "").lowercased()) ?? .other
    }

    var asStickinessSeries: StickinessSeries {
        let counts = data ?? []
        // Prefer the interval numbers PostHog sends; fall back to 1-based
        // positions when a payload omits them.
        let intervals = (rawDays ?? []).compactMap(\.intValue)
        let buckets = counts.enumerated().map { index, count in
            StickinessBucket(
                intervals: index < intervals.count ? intervals[index] : index + 1,
                count: count
            )
        }
        return StickinessSeries(label: label ?? "", total: count ?? 0, buckets: buckets)
    }

    var asLifecycleSeries: LifecycleSeries {
        LifecycleSeries(
            status: lifecycleStatus,
            label: label ?? "",
            total: count ?? 0,
            points: asSeries.points
        )
    }

    var looksLikeTrends: Bool { days != nil || aggregatedValue != nil }

    /// `count` is 0 for aggregated displays, where the figure lives in
    /// `aggregated_value` instead.
    var headlineValue: Double { aggregatedValue ?? count ?? 0 }

    var asSeries: Series {
        let values = data ?? []
        let labels = days ?? []
        return Series(
            label: label ?? "",
            total: count ?? 0,
            points: zip(labels, values).map { Point(day: $0, value: $1) }
        )
    }

    var asBarValue: BarValue {
        BarValue(label: label ?? "", value: headlineValue)
    }
}

struct FunnelStepDTO: Sendable, Decodable {
    let name: String?
    let customName: String?
    let count: Double?
    let order: Int?
    let averageConversionTime: Double?
    let breakdownValue: BreakdownValue?

    enum CodingKeys: String, CodingKey {
        case name, count, order
        case customName = "custom_name"
        case averageConversionTime = "average_conversion_time"
        case breakdownValue = "breakdown_value"
    }

    var asStep: FunnelStep {
        FunnelStep(
            name: customName ?? name ?? "",
            count: count ?? 0,
            order: order ?? 0,
            averageConversionTime: averageConversionTime
        )
    }
}

/// PostHog returns a breakdown as either a bare string or an array of strings
/// (multi-breakdown), so both are accepted.
enum BreakdownValue: Sendable, Decodable {
    case single(String)
    case multiple([String])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .single(s); return }
        if let a = try? c.decode([String].self) { self = .multiple(a); return }
        if let n = try? c.decode(Double.self) { self = .single(String(n)); return }
        self = .multiple([])
    }

    var display: String? {
        switch self {
        case .single(let s): return s
        case .multiple(let a): return a.isEmpty ? nil : a.joined(separator: " · ")
        }
    }
}
