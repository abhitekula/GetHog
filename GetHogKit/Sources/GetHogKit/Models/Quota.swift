import Foundation

// MARK: - Naming

/// Turns a snake_case API key into something a person reads.
///
/// Shared by quota resources and LLM product keys because both are PostHog's own
/// identifiers surfaced directly to a reader, and both break on `.capitalized` —
/// which produces "Llm events" and "Posthog code credits". The acronym table is
/// the only hand-maintained part, and an unrecognised word falls through to plain
/// sentence case rather than being guessed at.
enum ResourceKeyTitle {
    private static let acronyms: [String: String] = [
        "ai": "AI",
        "api": "API",
        "cpu": "CPU",
        "gb": "GB",
        "id": "ID",
        "llm": "LLM",
        "mb": "MB",
        "posthog": "PostHog",
        "sdk": "SDK",
        "sms": "SMS",
        "tb": "TB",
        "url": "URL",
    ]

    static func humanise(_ key: String) -> String {
        let words = key.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard !words.isEmpty else { return key }
        return words.enumerated()
            .map { index, word in
                if let acronym = acronyms[word.lowercased()] { return acronym }
                // Only the first word is capitalised: "Logs MB ingested" reads as
                // a phrase, "Logs MB Ingested" reads as a column header.
                return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
            }
            .joined(separator: " ")
    }
}

// MARK: - Quota

/// How hard a metered resource is pressing against its plan limit.
///
/// `.blocked` and `.unmetered` are the two that matter and neither is a
/// percentage. `.blocked` is not a forecast — PostHog has already stopped
/// accepting the resource — and `.unmetered` is the absence of a limit, which is
/// a different fact from a limit of zero.
public enum QuotaPressure: Sendable, Hashable {
    /// PostHog reported `limited: true`. Already cut off.
    case blocked
    case critical
    case watch
    case clear
    /// No `limit` in the payload at all.
    case unmetered

    /// Bands, not thresholds PostHog publishes.
    ///
    /// PostHog's response says how much of the allowance is gone and whether it
    /// has run out; where "getting close" starts is this app's call, so it is
    /// stated once here rather than scattered through a view. Half is the point
    /// at which a monthly allowance stops being on track.
    public static let criticalFraction = 0.9
    public static let watchFraction = 0.5

    /// Worst first.
    public var rank: Int {
        switch self {
        case .blocked: 0
        case .critical: 1
        case .watch: 2
        case .clear: 3
        // Last, because a resource with no limit cannot be near one. Ranking it
        // by usage against the metered rows would be comparing a number to a
        // ratio.
        case .unmetered: 4
        }
    }
}

/// One metered resource and what is left of its allowance.
public struct QuotaResource: Sendable, Hashable, Identifiable {
    /// PostHog's own key — `signals_credits`, `logs_mb_ingested`.
    public let key: String
    /// `true` once PostHog has stopped accepting this resource.
    public let limited: Bool
    /// Held as a `Double` rather than an `Int` because not every resource is a
    /// count: `logs_mb_ingested` is megabytes and `api_queries_read_bytes` is
    /// bytes, and truncating either would understate consumption.
    public let usage: Double
    /// **`nil` means the payload carried no limit**, which several resources do.
    /// It never means zero, and no reader of this type may substitute one.
    public let limit: Double?

    public var id: String { key }

    public init(key: String, limited: Bool, usage: Double, limit: Double?) {
        self.key = key
        self.limited = limited
        self.usage = usage
        self.limit = limit
    }

    public var title: String { ResourceKeyTitle.humanise(key) }

    /// Share of the allowance consumed, or `nil` when there is no allowance.
    ///
    /// Uncapped: an overage is worth stating as one rather than being flattened
    /// to 100%. Callers drawing a bar clamp it themselves.
    public var fraction: Double? {
        guard let limit else { return nil }
        // A limit of zero is "you may use none of this". Dividing by it gives
        // infinity or NaN, either of which renders as garbage in a meter.
        guard limit > 0 else { return usage > 0 ? 1 : 0 }
        return usage / limit
    }

    public var pressure: QuotaPressure {
        if limited { return .blocked }
        guard let fraction else { return .unmetered }
        if fraction >= QuotaPressure.criticalFraction { return .critical }
        if fraction >= QuotaPressure.watchFraction { return .watch }
        return .clear
    }

    /// The state as a word.
    ///
    /// Required, not decorative: a bar's fill and tint are the two encodings a
    /// colour-blind or greyscale reader cannot rely on, so the row states its
    /// condition in text as well.
    public var stateWord: String {
        switch pressure {
        case .blocked: "At limit"
        case .critical: "Critical"
        case .watch: "Watch"
        case .clear: "Clear"
        case .unmetered: "Unmetered"
        }
    }

    /// `3,000 of 4,500`, or `18 used · no limit reported` when there is none.
    ///
    /// The second form exists because the obvious fallback — treating a missing
    /// limit as zero — renders "18 of 0" beside a full bar, which claims an
    /// overage PostHog never reported on the one screen someone opens to find
    /// out whether they have one.
    public func usageDescription(locale: Locale = .autoupdatingCurrent) -> String {
        let used = usage.formatted(.number.locale(locale))
        guard let limit else { return "\(used) used · no limit reported" }
        return "\(used) of \(limit.formatted(.number.locale(locale)))"
    }

    /// Blocked first, then by how much of the allowance is gone, then the
    /// resources that have no allowance to be near.
    ///
    /// The final tie-break on `key` is load-bearing rather than tidy: the
    /// response is a JSON object, `allKeys` arrives in no defined order, and
    /// without it two equally-pressed resources would swap places between loads.
    public static func mostPressingFirst(_ a: QuotaResource, _ b: QuotaResource) -> Bool {
        if a.pressure.rank != b.pressure.rank { return a.pressure.rank < b.pressure.rank }
        let aFraction = a.fraction ?? -1
        let bFraction = b.fraction ?? -1
        if aFraction != bFraction { return aFraction > bFraction }
        if a.usage != b.usage { return a.usage > b.usage }
        return a.key < b.key
    }
}

/// `GET /api/projects/{id}/quota_limits/`.
///
/// Eighteen resources on the project this was built against, seventeen of them
/// at or near zero. That distribution is the design constraint: the question
/// someone asks away from a desk is "are we about to blow the quota", and an
/// alphabetical table of eighteen rows answers it slower than no table at all.
/// So the resources arrive **already ranked** by how close each is to its limit,
/// and the split between `pressing` and `quiet` is made here rather than left to
/// each view to reinvent.
public struct QuotaLimits: Sendable, Decodable, Hashable {
    /// Ranked, worst first.
    public let resources: [QuotaResource]

    /// The rows worth interrupting someone for.
    public var pressing: [QuotaResource] {
        resources.filter { $0.pressure == .blocked || $0.pressure == .critical || $0.pressure == .watch }
    }

    /// Everything else. Kept, never hidden — behind a disclosure is not the same
    /// as dropped — but it must not be what the card leads with.
    public var quiet: [QuotaResource] {
        resources.filter { !($0.pressure == .blocked || $0.pressure == .critical || $0.pressure == .watch) }
    }

    /// The most-pressed resource that actually has a limit.
    ///
    /// Non-nil even on a quiet project, so the card can say "nothing is close,
    /// and here is what is closest" rather than rendering an empty state that
    /// looks like a failed load.
    public var headline: QuotaResource? {
        resources.first { $0.pressure != .unmetered }
    }

    public var blockedCount: Int { resources.filter(\.limited).count }

    public init(resources: [QuotaResource]) {
        self.resources = resources.sorted(by: QuotaResource.mostPressingFirst)
    }

    // MARK: - Decoding

    /// The payload is a bare map of resource key to `{limited, usage, limit}`,
    /// with no envelope and no list of which keys to expect.
    private struct Entry: Decodable {
        let limited: Bool?
        let usage: Double?
        let limit: Double?
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var found: [QuotaResource] = []
        found.reserveCapacity(container.allKeys.count)

        for key in container.allKeys {
            // Skipped rather than thrown on. This map is an open set — PostHog
            // adds metered products to it without notice, and nothing says every
            // key must be one — so a value this client cannot read must cost one
            // row, not the whole card. A key is only taken as a resource if it
            // carries at least one of the three fields a resource has.
            guard let entry = try? container.decode(Entry.self, forKey: key),
                  entry.limited != nil || entry.usage != nil || entry.limit != nil
            else { continue }

            found.append(
                QuotaResource(
                    key: key.stringValue,
                    limited: entry.limited ?? false,
                    usage: entry.usage ?? 0,
                    // Deliberately not defaulted. See `QuotaResource.limit`.
                    limit: entry.limit
                )
            )
        }

        resources = found.sorted(by: QuotaResource.mostPressingFirst)
    }

    public static func decode(from data: Data) throws -> QuotaLimits {
        try JSONDecoder().decode(QuotaLimits.self, from: data)
    }
}

// MARK: - LLM spend

/// Money, formatted once.
///
/// Every cost on the wire is a `Double` with six decimal places
/// (`[REMOVED PRIVATE DATA]`), which is not a price and cannot be compared for equality.
/// Currency style is the only arithmetic performed on one: it rounds to the
/// cent for display and nothing downstream re-derives a total from parts.
enum Money {
    static func usd(_ amount: Double, locale: Locale) -> String {
        amount.formatted(.currency(code: "USD").locale(locale))
    }
}

/// One product's share of the LLM bill.
public struct LLMProductSpend: Sendable, Decodable, Hashable, Identifiable {
    /// **Nullable, and null is a real row.** The live breakdown carries 426
    /// events and $[REMOVED PRIVATE DATA] of genuine spend under `product: null`.
    public let product: String?
    public let costUSD: Double
    public let eventCount: Int

    enum CodingKeys: String, CodingKey {
        case product
        case costUSD = "cost_usd"
        case eventCount = "event_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        product = try c.decodeIfPresent(String.self, forKey: .product)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
    }

    /// Stable even for the null-product row, so a `ForEach` over the breakdown
    /// does not need to special-case it.
    public var id: String { product ?? "__unattributed" }

    public var title: String {
        guard let product else { return "Unattributed" }
        return ResourceKeyTitle.humanise(product)
    }

    public func formattedCost(locale: Locale = .autoupdatingCurrent) -> String {
        Money.usd(costUSD, locale: locale)
    }
}

/// `GET /api/llm_analytics/@me/spend/?product=…`.
///
/// User-scoped, not project-scoped: it answers for `@me` across the whole
/// organisation and takes no project id.
public struct LLMSpend: Sendable, Decodable, Hashable {
    public let totalCostUSD: Double
    public let eventCount: Int
    public let product: String?
    public let dateFrom: Date?
    public let dateTo: Date?
    /// Cost descending.
    public let byProduct: [LLMProductSpend]

    enum CodingKeys: String, CodingKey {
        case summary
        case byProduct = "by_product"
    }

    private struct Summary: Decodable {
        let totalCostUSD: Double?
        let eventCount: Int?
        let product: String?
        let dateFrom: String?
        let dateTo: String?

        enum CodingKeys: String, CodingKey {
            case product
            case totalCostUSD = "total_cost_usd"
            case eventCount = "event_count"
            case dateFrom = "date_from"
            case dateTo = "date_to"
        }
    }

    private struct Breakdown: Decodable {
        let items: [LLMProductSpend]?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let summary = try c.decodeIfPresent(Summary.self, forKey: .summary)

        // The server's own total, taken verbatim. On the observed response the
        // four product rows sum to [REMOVED PRIVATE DATA] against a stated [REMOVED PRIVATE DATA] — a
        // 1e-6 disagreement no rounding rule reconciles — so re-adding the parts
        // would put a number on screen that PostHog's own console does not show.
        totalCostUSD = summary?.totalCostUSD ?? 0
        eventCount = summary?.eventCount ?? 0
        product = summary?.product
        dateFrom = summary?.dateFrom.flatMap(PostHogDate.parse)
        dateTo = summary?.dateTo.flatMap(PostHogDate.parse)

        let breakdown = try c.decodeIfPresent(Breakdown.self, forKey: .byProduct)
        byProduct = (breakdown?.items ?? []).sorted { a, b in
            // Sorting is not guaranteed stable, so ties break on the identifier
            // rather than on whatever order the response happened to arrive in.
            if a.costUSD != b.costUSD { return a.costUSD > b.costUSD }
            return a.id < b.id
        }
    }

    public func formattedTotal(locale: Locale = .autoupdatingCurrent) -> String {
        Money.usd(totalCostUSD, locale: locale)
    }

    public static func decode(from data: Data) throws -> LLMSpend {
        try JSONDecoder().decode(LLMSpend.self, from: data)
    }
}
