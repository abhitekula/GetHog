import Foundation

/// Relative window for a traces query.
///
/// Lives in the kit rather than the view so the strings the API actually
/// accepts are pinned by a test, not by whatever a picker happens to send.
public enum LLMDateRange: String, Sendable, CaseIterable, Identifiable {
    case day
    case week
    case month

    public var id: String { rawValue }

    public var dateFrom: String {
        switch self {
        case .day: "-24h"
        case .week: "-7d"
        case .month: "-30d"
        }
    }

    public var title: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        }
    }

    /// Spoken form, because "24h" is read as "twenty-four h" by VoiceOver.
    public var accessibleTitle: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }
}

/// Response from `POST /query/` with a `TracesQuery` node.
///
/// This is the one query node that does **not** return column-oriented rows.
/// `columns` advertises snake_case names (`first_distinct_id`, `total_latency`)
/// but `results` is an array of camelCase **objects** whose keys don't even
/// match that list — `createdAt` where `columns` promises `first_timestamp`.
/// Decoding it through the shared `QueryResponse` throws, so it gets its own
/// type and ignores `columns` entirely.
public struct LLMTracesResponse: Sendable, Decodable {
    public let traces: [LLMTrace]
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case results, hasMore
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        traces = (try? c.decodeIfPresent([LLMTrace].self, forKey: .results)) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    public static func decode(from data: Data) throws -> LLMTracesResponse {
        try JSONDecoder().decode(LLMTracesResponse.self, from: data)
    }

    // MARK: - Page totals
    //
    // Totals describe the traces actually fetched, never the project. A header
    // that implied a project-wide spend figure from one page would be a lie.

    public var totalCost: Double { traces.reduce(0) { $0 + ($1.totalCost ?? 0) } }
    public var totalInputTokens: Double { traces.reduce(0) { $0 + ($1.inputTokens ?? 0) } }
    public var totalOutputTokens: Double { traces.reduce(0) { $0 + ($1.outputTokens ?? 0) } }
    public var totalTokens: Double { totalInputTokens + totalOutputTokens }

    /// True when at least one trace reports spend, which decides both the
    /// ranking and whether the cost column is worth showing at all.
    public var hasCostData: Bool { traces.contains { ($0.totalCost ?? 0) > 0 } }

    /// Most expensive first — the reason anyone opens this screen.
    ///
    /// Projects whose SDK doesn't report token usage get null costs across the
    /// board, and a list sorted by a column of zeroes is arbitrary noise, so
    /// those fall back to most-recent-first.
    public var ranked: [LLMTrace] {
        guard hasCostData else {
            return traces.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
        }
        return traces.sorted { ($0.totalCost ?? 0) > ($1.totalCost ?? 0) }
    }
}

/// One LLM trace: a root request and the spans recorded under it.
public struct LLMTrace: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let sessionID: String?
    public let distinctID: String?
    public let traceName: String?
    public let createdAt: Date?
    public let totalLatency: Double?
    public let inputTokens: Double?
    public let outputTokens: Double?
    public let inputCost: Double?
    public let outputCost: Double?
    public let requestCost: Double?
    public let totalCost: Double?
    public let errorCount: Int
    public let events: [LLMTraceEvent]

    enum CodingKeys: String, CodingKey {
        case id, events, traceName, createdAt, errorCount
        case sessionID = "aiSessionId"
        case distinctID = "distinctId"
        case totalLatency, inputTokens, outputTokens
        case inputCost, outputCost, requestCost, totalCost
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The trace id is whatever the SDK sent as `$ai_trace_id`: a UUID from
        // the PostHog SDKs, an opaque string from others.
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            id = String(n)
        } else {
            id = UUID().uuidString
        }
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        distinctID = try c.decodeIfPresent(String.self, forKey: .distinctID)
        traceName = try c.decodeIfPresent(String.self, forKey: .traceName)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        totalLatency = try c.decodeIfPresent(Double.self, forKey: .totalLatency)
        // Token counts arrive as floats (308.0) because they come out of a SUM.
        inputTokens = try c.decodeIfPresent(Double.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Double.self, forKey: .outputTokens)
        inputCost = try c.decodeIfPresent(Double.self, forKey: .inputCost)
        outputCost = try c.decodeIfPresent(Double.self, forKey: .outputCost)
        requestCost = try c.decodeIfPresent(Double.self, forKey: .requestCost)
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost)
        // Also a SUM, so it arrives as 0.0 rather than 0.
        errorCount = Int((try? c.decodeIfPresent(Double.self, forKey: .errorCount)) ?? 0)
        events = (try? c.decodeIfPresent([LLMTraceEvent].self, forKey: .events)) ?? []
    }

    public var totalTokens: Double? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    /// Short form for a dense row. Trace ids are long and only the head is
    /// needed to recognise one against the web console.
    public var shortID: String {
        id.count <= 12 ? id : String(id.prefix(12)) + "…"
    }

    public var displayName: String {
        if let traceName, !traceName.isEmpty { return traceName }
        return shortID
    }
}

/// A child event of a trace — a generation, embedding, span, or feedback mark.
public struct LLMTraceEvent: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let event: String
    public let timestamp: Date?
    public let properties: JSONValue?

    public init(from decoder: any Decoder) throws {
        // HogQL builds this column with `groupArray(tuple(uuid, event,
        // timestamp, properties))`. PostHog's own client sees it as objects,
        // but a raw tuple serialises as a positional array, and the captured
        // project has no traces with events to settle which one ships. Both
        // are accepted so an unlucky project doesn't lose the whole page.
        if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !array.isAtEnd {
                values.append((try? array.decode(JSONValue.self)) ?? .null)
            }
            id = values.first?.stringValue ?? UUID().uuidString
            event = values.count > 1 ? (values[1].stringValue ?? "event") : "event"
            timestamp = values.count > 2 ? values[2].stringValue.flatMap(PostHogDate.parse) : nil
            properties = values.count > 3 ? values[3] : nil
            return
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .uuid))
            ?? UUID().uuidString
        event = try c.decodeIfPresent(String.self, forKey: .event) ?? "event"
        let stamp = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .timestamp)
        timestamp = stamp.flatMap(PostHogDate.parse)
        properties = try? c.decodeIfPresent(JSONValue.self, forKey: .properties)
    }

    enum CodingKeys: String, CodingKey {
        case id, uuid, event, timestamp, createdAt, properties
    }

    /// The model this event ran against, when the SDK recorded one.
    public var model: String? {
        properties?["$ai_model"]?.stringValue
    }

    public var latency: Double? {
        properties?["$ai_latency"]?.doubleValue
    }
}
