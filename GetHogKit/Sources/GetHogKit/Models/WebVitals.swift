import Foundation

/// A Core Web Vital, with Google's published thresholds.
///
/// The thresholds differ per metric — reusing LCP's on CLS would mark almost
/// every page "good" — so they travel with the metric rather than being passed
/// in at the call site.
public enum WebVitalMetric: String, Sendable, CaseIterable, Identifiable {
    case lcp = "LCP"
    case inp = "INP"
    case cls = "CLS"
    case fcp = "FCP"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lcp: "Largest Contentful Paint"
        case .inp: "Interaction to Next Paint"
        case .cls: "Cumulative Layout Shift"
        case .fcp: "First Contentful Paint"
        }
    }

    /// `[goodBelow, poorAbove]`.
    public var thresholds: [Double] {
        switch self {
        case .lcp: [2500, 4000]
        case .inp: [200, 500]
        case .cls: [0.1, 0.25]
        case .fcp: [1800, 3000]
        }
    }

    /// CLS is a unitless ratio; the rest are milliseconds.
    public var isDuration: Bool { self != .cls }

    public func format(_ value: Double) -> String {
        guard isDuration else {
            return value.formatted(.number.precision(.fractionLength(0...3)))
        }
        return value < 1000
            ? "\(Int(value.rounded()))ms"
            : (value / 1000).formatted(.number.precision(.fractionLength(0...2))) + "s"
    }
}

public enum WebVitalBand: String, Sendable, CaseIterable {
    case poor
    case needsImprovement
    case good

    public var title: String {
        switch self {
        case .poor: "Poor"
        case .needsImprovement: "Needs improvement"
        case .good: "Good"
        }
    }

    /// Worst first — poor pages are the ones worth acting on.
    /// Worst-first ordering. Public because the app ranks pages by band and
    /// would otherwise have to hardcode a parallel order that could drift.
    public var rank: Int {
        switch self {
        case .poor: 0
        case .needsImprovement: 1
        case .good: 2
        }
    }
}

public struct WebVitalEntry: Sendable, Hashable, Identifiable {
    public let path: String
    public let value: Double
    public let band: WebVitalBand?

    public var id: String { "\(band?.rawValue ?? "?")|\(path)" }

    public init(path: String, value: Double, band: WebVitalBand?) {
        self.path = path
        self.value = value
        self.band = band
    }
}

public struct WebVitalsBreakdown: Sendable, Decodable {
    public let good: [WebVitalEntry]
    public let needsImprovement: [WebVitalEntry]
    public let poor: [WebVitalEntry]

    enum Root: String, CodingKey { case results }
    enum Bucket: String, CodingKey {
        case good
        case needsImprovement = "needs_improvements"
        case poor
    }

    struct RawEntry: Decodable {
        let path: String?
        let value: Double?
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        var results = try root.nestedUnkeyedContainer(forKey: .results)

        guard !results.isAtEnd else {
            good = []; needsImprovement = []; poor = []
            return
        }
        let bucket = try results.nestedContainer(keyedBy: Bucket.self)

        func entries(_ key: Bucket, _ band: WebVitalBand) -> [WebVitalEntry] {
            let raw = (try? bucket.decodeIfPresent([RawEntry].self, forKey: key)) ?? []
            return raw.compactMap { item in
                guard let path = item.path else { return nil }
                return WebVitalEntry(path: path, value: item.value ?? 0, band: band)
            }
        }

        good = entries(.good, .good)
        needsImprovement = entries(.needsImprovement, .needsImprovement)
        poor = entries(.poor, .poor)
    }

    public static func decode(from data: Data) throws -> WebVitalsBreakdown {
        try JSONDecoder().decode(WebVitalsBreakdown.self, from: data)
    }

    /// All entries, worst band first.
    public var allEntries: [WebVitalEntry] {
        (poor + needsImprovement + good)
            .sorted { ($0.band?.rank ?? 3, -$0.value) < ($1.band?.rank ?? 3, -$1.value) }
    }

    public var isEmpty: Bool { allEntries.isEmpty }
}
