import Foundation

public struct Insight: Sendable, Decodable, Identifiable {
    public let id: Int
    public let name: String?
    public let derivedName: String?
    public let query: InsightQuery?

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
        result = (try? c.decodeIfPresent(RawResult.self, forKey: .result)) ?? .unknown
    }

    public var title: String {
        if let name, !name.isEmpty { return name }
        if let derivedName, !derivedName.isEmpty { return derivedName }
        return "Untitled"
    }

    /// The insight kind as PostHog names it, e.g. `TrendsQuery`.
    public var sourceKind: String { query?.source?.kind ?? "Unknown" }

    /// Dispatch is on the declared query kind, never on the result's shape:
    /// lifecycle results carry `data`/`days` exactly like trends, so shape
    /// sniffing would silently draw a wrong chart.
    public var renderModel: InsightRenderModel {
        switch sourceKind {
        case "TrendsQuery":
            switch query?.source?.trendsFilter?.display {
            case "ActionsBarValue", "ActionsPie", "ActionsTable":
                return .barValue(result.seriesDTOs.map(\.asBarValue))
            case "BoldNumber":
                guard let first = result.seriesDTOs.first else { return .unsupported(kind: sourceKind) }
                return .bigNumber(BigNumber(label: first.label ?? "", value: first.headlineValue))
            default:
                return .timeSeries(result.seriesDTOs.map(\.asSeries))
            }

        case "FunnelsQuery":
            let groups = result.funnelGroups
            return groups.isEmpty ? .unsupported(kind: sourceKind) : .funnel(groups)

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
    case unknown

    init(from decoder: any Decoder) throws {
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
}

struct TrendsSeriesDTO: Sendable, Decodable {
    let label: String?
    let count: Double?
    let data: [Double]?
    let days: [String]?
    let aggregatedValue: Double?

    enum CodingKeys: String, CodingKey {
        case label, count, data, days
        case aggregatedValue = "aggregated_value"
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
