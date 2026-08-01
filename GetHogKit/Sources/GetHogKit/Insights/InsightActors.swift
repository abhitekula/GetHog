import Foundation

/// Drilling from a chart to the people behind it.
///
/// This is the web console's single most-used interaction — click a funnel step,
/// see who dropped out — and everything here follows the public `ActorsQuery`
/// request and response contracts.
///
/// ## The request
///
/// One `POST /api/projects/:id/query/` carrying an `ActorsQuery` whose `source`
/// is one of three nodes. Which node is *not* a detail: the union
/// `ActorsQuery.source` accepts is exactly
///
///     InsightActorsQuery, FunnelsActorsQuery, FunnelCorrelationActorsQuery,
///     StickinessActorsQuery, ExperimentActorsQuery, HogQLQuery
///
/// and the funnel and stickiness parameters live *only* on their own nodes:
/// `funnelStep` on an `InsightActorsQuery` is rejected outright
/// (`extra_forbidden`), and so is `status` on a `FunnelsActorsQuery`. The three
/// this app uses carry:
///
///     InsightActorsQuery     day (str|int), series (int), status (str),
///                            interval (int), breakdown (str|int),
///                            compare ('current'|'previous'), includeRecordings
///     FunnelsActorsQuery     funnelStep (int), funnelStepBreakdown,
///                            funnelTrendsDropOff, funnelTrendsEntrancePeriodStart
///     StickinessActorsQuery  series (int), day (str|int)
///
/// `InsightActorsQuery.source` in turn accepts only `TrendsQuery`,
/// `FunnelsQuery`, `RetentionQuery`, `PathsQuery`, `StickinessQuery`,
/// `LifecycleQuery`, `WebStatsTableQuery` and `WebOverviewQuery` — which is why
/// a SQL insight can never be drilled, whatever its result looks like.
///
/// ## The response
///
/// Column-oriented like every other `/query/` response, but with its own
/// envelope: `columns` is `["person", "id", "person.$delete",
/// "event_distinct_ids"]` (the last is absent on funnel and lifecycle drills),
/// and alongside `results` sit `hasMore`, `limit`, `offset` and
/// `missing_actors_count`. See `ActorsPage`.
///
/// ## Cost
///
/// One `query`-category slot per call, against a budget shared with the user's
/// production integrations. Every drill is therefore a deliberate tap — never a
/// hover, never speculative, never on appear.
public enum InsightActors {

    /// The number of actors one page asks for.
    ///
    /// The API caps a page itself and reports `hasMore`; this is the app's own
    /// figure, chosen so the first screenful arrives in one request.
    public static let pageSize = 100

    /// Builds the `ActorsQuery` node for one drill.
    ///
    /// `source` is the insight's own saved query subtree, verbatim — the same
    /// reasoning as `InsightRerun.source`. Rebuilding it from the decoded
    /// `QuerySource` would drop the series definitions, property filters and
    /// breakdown, and return a *different* population than the chart drew.
    ///
    /// Returns `nil` when `source` is not an object, so a malformed saved query
    /// fails to offer a drill rather than sending a request that cannot mean
    /// what the tap meant.
    public static func query(
        source: JSONValue,
        drill: InsightDrill,
        limit: Int = pageSize,
        offset: Int = 0
    ) -> JSONValue? {
        guard case .object = source else { return nil }

        var inner: [String: JSONValue] = ["source": source]

        switch drill.kind {
        case .trendsPoint(let series, let day):
            inner["kind"] = .string("InsightActorsQuery")
            inner["series"] = .number(Double(series))
            inner["day"] = .string(day)

        case .breakdown(let series, let value):
            inner["kind"] = .string("InsightActorsQuery")
            inner["series"] = .number(Double(series))
            inner["breakdown"] = .string(value)

        case .lifecycleBand(let status, let day):
            inner["kind"] = .string("InsightActorsQuery")
            inner["status"] = .string(status)
            inner["day"] = .string(day)

        case .funnelStep(let step, let outcome):
            inner["kind"] = .string("FunnelsActorsQuery")
            // 1-based and signed by the API contract. A positive step means
            // "reached step n"; a negative step means "reached the preceding
            // step and not this one".
            //
            // `-1` is not merely empty — it is **HTTP 500**. Nobody can drop off
            // before the first step, and PostHog does not defend against being
            // asked. `InsightDrill.funnelDropOff` refuses to build one; this is
            // the second guard, because a 500 here is indistinguishable from
            // PostHog being down.
            let signed = outcome == .droppedOff ? -(step + 1) : (step + 1)
            guard signed != -1 else { return nil }
            inner["funnelStep"] = .number(Double(signed))

        case .stickinessBucket(let series, let intervals):
            inner["kind"] = .string("StickinessActorsQuery")
            inner["series"] = .number(Double(series))
            inner["day"] = .number(Double(intervals))
        }

        return .object([
            "kind": .string("ActorsQuery"),
            "limit": .number(Double(limit)),
            "offset": .number(Double(offset)),
            "source": .object(inner),
        ])
    }
}

// MARK: - What a tap meant

/// One fully specified drill: which people, and how many the chart already
/// claims there are.
///
/// `expectedCount` is carried so the screen can be honest *before* the request
/// returns — and so it can say so when the two disagree.
public struct InsightDrill: Sendable, Equatable, Hashable, Identifiable {
    public let kind: InsightDrillKind
    /// What the user tapped, in their own words — "26 Jul · Returning".
    public let title: String
    /// The figure the chart is drawing for this point.
    public let expectedCount: Double

    public var id: InsightDrillKind { kind }

    public init(kind: InsightDrillKind, title: String, expectedCount: Double) {
        self.kind = kind
        self.title = title
        self.expectedCount = expectedCount
    }
}

public enum InsightDrillKind: Sendable, Equatable, Hashable {
    /// A point on a trends line, by series index and the day label in the result.
    case trendsPoint(series: Int, day: String)

    /// One breakdown value of an aggregated trends display — a bar, pie slice,
    /// table row, or country on a world map.
    case breakdown(series: Int, value: String)

    /// One lifecycle band on one day. A negative chart value represents a
    /// magnitude when constructing its actors query.
    case lifecycleBand(status: String, day: String)

    /// A funnel step, and whether the tap meant the people who got through it or
    /// the people who fell out before it. `step` is the zero-based index the
    /// chart drew; the sign and the 1-based offset are applied when the query is
    /// built.
    case funnelStep(step: Int, outcome: FunnelDrillOutcome)

    /// One stickiness bucket — "the people who were active on exactly n days".
    case stickinessBucket(series: Int, intervals: Int)
}

public enum FunnelDrillOutcome: String, Sendable, Equatable, Hashable, CaseIterable {
    case converted
    case droppedOff

    public var title: String {
        switch self {
        case .converted: "Completed this step"
        case .droppedOff: "Dropped off here"
        }
    }
}

public extension InsightDrill {
    /// The people who reached `step`.
    static func funnelConverted(step: FunnelStep, index: Int) -> InsightDrill {
        InsightDrill(
            kind: .funnelStep(step: index, outcome: .converted),
            title: step.name,
            expectedCount: step.count
        )
    }

    /// The people who reached the previous step and not this one, or `nil` for
    /// the first step, where the question has no meaning and the API answers
    /// with HTTP 500.
    static func funnelDropOff(step: FunnelStep, index: Int, previous: FunnelStep?) -> InsightDrill? {
        guard index > 0, let previous else { return nil }
        return InsightDrill(
            kind: .funnelStep(step: index, outcome: .droppedOff),
            title: step.name,
            expectedCount: max(0, previous.count - step.count)
        )
    }
}

// MARK: - Which insights can be drilled at all

/// The axis along which an insight can be drilled, or `nil` for one that cannot.
///
/// This is the gate the UI gets, and it is deliberately answered from the saved
/// query rather than from the result: an affordance that appears and then fails
/// is worse than one that was never offered.
public enum InsightDrillAxis: String, Sendable, Equatable, Hashable {
    /// Pick a series and a day. A trends drill requires both dimensions.
    case trendsPoint
    /// Pick a breakdown value.
    case breakdown
    /// Pick a band and a day.
    case lifecycleBand
    /// Pick a step, and converted or dropped.
    case funnelStep
    /// Pick a bucket.
    case stickinessBucket
}

public enum InsightDrilldown {

    /// Whether this insight offers a drill-down, and along which axis.
    ///
    /// Returns `nil` — meaning *show no affordance at all* — for:
    ///
    /// - **Retention.** `InsightActorsQuery.interval` is accepted and does
    ///   return people, but it does not reconcile. Against a live two-cohort
    ///   grid of 186 / 57, `interval: 0` returned 186 (exact) and `interval: 1`
    ///   returned **62** against a charted 57, on a grid re-requested with
    ///   `refresh: blocking`. PostHog's own `InsightActorsQueryOptions` reports
    ///   `interval: null` for a `RetentionQuery`, i.e. it does not advertise the
    ///   dimension either. Offering "57 people" and listing 62 is precisely the
    ///   dishonesty this app exists to avoid.
    ///
    /// - **Paths.** There is no per-edge parameter at all: `InsightActorsQuery`
    ///   has no paths field, and `InsightActorsQueryOptions` reports every
    ///   dimension null. Filtering the *source* by
    ///   `pathsFilter.pathStartKey`/`pathEndKey` is accepted, but for an edge the
    ///   chart labels 27 it returned 10 people — it selects whole paths through
    ///   those nodes, not the edge's traversals.
    ///
    /// - **`BoldNumber`**, and any aggregated display with no breakdown, because
    ///   there is nothing discrete to point at: the only remaining axis is
    ///   `series`, and a series-only actors query returns nothing.
    ///
    /// - **SQL / HogQL insights**, which `InsightActorsQuery.source` will not
    ///   accept.
    ///
    /// - Anything already rendering as `.unsupported`.
    public static func axis(
        sourceKind: String,
        display: String?,
        hasBreakdown: Bool
    ) -> InsightDrillAxis? {
        switch sourceKind {
        case "TrendsQuery":
            switch display {
            // Aggregated displays have no time axis; their bars *are* the
            // breakdown values, so that is the only thing to point at. Without a
            // breakdown each bar is a series instead, and a series alone drills
            // to nothing.
            case "ActionsBarValue", "ActionsPie", "ActionsTable", "WorldMap":
                return hasBreakdown ? .breakdown : nil
            case "BoldNumber":
                return nil
            case "CalendarHeatmap", "BoxPlot":
                // Routed to `.unsupported`; there is no chart to tap.
                return nil
            default:
                return .trendsPoint
            }

        case "LifecycleQuery":
            return .lifecycleBand

        case "FunnelsQuery":
            return .funnelStep

        case "StickinessQuery":
            return .stickinessBucket

        default:
            // Retention, Paths, HogQL and anything unrecognised.
            return nil
        }
    }

    /// Whether a saved query carries a breakdown, read from the raw subtree.
    ///
    /// PostHog spells this `breakdownFilter.breakdown` on a v2 query and
    /// `breakdown` on older saved ones; both are accepted because both are still
    /// in the wild — this project's own WorldMap insights are the former.
    public static func hasBreakdown(source: JSONValue?) -> Bool {
        guard let source, case .object(let fields) = source else { return false }
        if case .object(let filter)? = fields["breakdownFilter"] {
            if let value = filter["breakdown"], value != .null { return true }
            if case .array(let many)? = filter["breakdowns"], !many.isEmpty { return true }
        }
        if let legacy = fields["breakdown"], legacy != .null { return true }
        return false
    }
}

// MARK: - Response

/// One page of `ActorsQuery` results.
///
/// The envelope is not `QueryResponse`'s: alongside the column-oriented rows it
/// carries `hasMore` and `missing_actors_count`, and both are load-bearing.
public struct ActorsPage: Sendable, Equatable {
    public let actors: [InsightActor]
    /// Whether PostHog has more rows beyond this page.
    public let hasMore: Bool
    public let offset: Int
    /// How many actors PostHog could not resolve to a person at all.
    ///
    /// Not a rounding error: on a live retention drill this was 184 of 186, and
    /// on a plain trends drill 3 of 5. A screen that quietly listed only the
    /// resolvable ones would show 2 people under a heading claiming 186.
    public let missingActorsCount: Int

    public init(actors: [InsightActor], hasMore: Bool, offset: Int, missingActorsCount: Int) {
        self.actors = actors
        self.hasMore = hasMore
        self.offset = offset
        self.missingActorsCount = missingActorsCount
    }

    public static func decode(from data: Data) throws -> ActorsPage {
        try JSONDecoder().decode(ActorsPage.self, from: data)
    }
}

extension ActorsPage: Decodable {
    enum CodingKeys: String, CodingKey {
        case columns, results, hasMore, offset
        case missingActorsCount = "missing_actors_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        let rows = try c.decodeIfPresent([[JSONValue]].self, forKey: .results) ?? []
        let personIndex = columns.firstIndex(of: "person") ?? 0

        actors = rows.compactMap { row in
            guard personIndex < row.count else { return nil }
            return InsightActor(person: row[personIndex])
        }
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        offset = (try? c.decodeIfPresent(Int.self, forKey: .offset)) ?? 0
        missingActorsCount = (try? c.decodeIfPresent(Int.self, forKey: .missingActorsCount)) ?? 0
    }
}

/// One person behind a chart.
///
/// The API response permits **two different person shapes** in the same
/// `results` array, and conflating them is how a list ends up with blank rows:
///
///     resolved    { id, distinct_ids, created_at, last_seen_at,
///                   is_identified, properties }
///     unresolved  { id, distinct_ids, is_unresolved: true }
///
/// The second has no `properties` at all — no name, no email — because the
/// person row no longer exists behind the event.
public struct InsightActor: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let distinctIDs: [String]
    /// PostHog could not resolve this actor to a person record.
    public let isUnresolved: Bool
    public let isIdentified: Bool
    public let createdAt: Date?
    public let name: String?
    public let email: String?
    /// The whole person object as sent, so a detail screen can decode a
    /// `PersonSummary` from it without a second request.
    public let raw: JSONValue

    public init?(person: JSONValue) {
        guard case .object(let fields) = person else { return nil }
        guard let id = fields["id"]?.stringValue else { return nil }
        self.id = id
        self.raw = person
        if case .array(let ids)? = fields["distinct_ids"] {
            distinctIDs = ids.compactMap(\.stringValue)
        } else {
            distinctIDs = []
        }
        isUnresolved = fields["is_unresolved"]?.boolValue ?? false
        isIdentified = fields["is_identified"]?.boolValue ?? false
        createdAt = fields["created_at"]?.stringValue.flatMap(PostHogDate.parse)

        if case .object(let props)? = fields["properties"] {
            name = props["name"]?.stringValue
            email = props["email"]?.stringValue
        } else {
            name = nil
            email = nil
        }
    }

    /// What to put on a row.
    ///
    /// Falls through name → email → first distinct id, and only then to a
    /// placeholder. An unresolved actor still has a distinct id, which is a real
    /// handle a user can search on — more use than "Anonymous".
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        if let first = distinctIDs.first, !first.isEmpty { return first }
        return "Unknown person"
    }

    /// The secondary line, or `nil` when it would only repeat `displayName`.
    public var subtitle: String? {
        if let email, !email.isEmpty, email != displayName { return email }
        if let first = distinctIDs.first, first != displayName { return first }
        return nil
    }

    public var initials: String {
        let letters = displayName.prefix(while: { $0 != "@" })
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

public extension JSONValue {
    var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let d): d != 0
        default: nil
        }
    }
}
