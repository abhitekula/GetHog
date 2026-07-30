import Foundation

// OpenTelemetry spans, as PostHog's `/query/` tracing kinds return them.
//
// Every shape here is column-oriented: `/query/` answers with positional arrays
// and a parallel `columns` array, so each type reads itself out of a `QueryRow`
// by name rather than by index.
//
// A warning that shaped the whole file: the organisation these were built
// against has **no `viewer` access to the `tracing` resource**, and PostHog
// reports that as an HTTP **400**, not a 403. Nothing below has been seen
// against real spans. The decoders follow the column list PostHog documents for
// each kind, and where a column could plausibly arrive in two spellings they
// read both rather than pick one and be silently wrong.

// MARK: - State

/// What a tracing surface is currently showing, and why.
///
/// Modelled as a type instead of being derived ad hoc inside the view because
/// the *denied* case is the one this project can actually reach. Left to a
/// generic error path, a 400 reads as "GetHog sent a malformed request" —
/// which sends the user looking for a bug instead of asking an admin for access.
public enum TracingState: Sendable, Equatable {
    case loading
    /// PostHog denied a named resource. Fixed by an organisation admin granting
    /// role access, *not* by editing the API key.
    case denied(resource: String)
    /// The personal API key lacks a scope. Fixed by the user editing their key.
    case missingScope(String)
    case failed(String)
    case empty
    case loaded

    /// Classifies a failed request into the state the screen should show.
    public init(failure error: any Error) {
        guard let error = error as? PostHogError else {
            self = .failed(error.localizedDescription)
            return
        }
        switch error {
        case .accessDenied(let resource):
            // The resource name is scraped out of a prose message, so it can go
            // missing if PostHog rewords it. Defaulting to `tracing` keeps the
            // screen locked rather than dropping through to a retryable failure
            // that would never succeed.
            self = .denied(resource: resource ?? "tracing")
        case .forbidden(let scope):
            self = .missingScope(scope ?? Capability.events.requiredScopes.joined(separator: ", "))
        default:
            self = .failed(error.localizedDescription)
        }
    }

    /// Resolves a successful load: no rows is empty, which is not a failure.
    public static func resolved(rowCount: Int) -> TracingState {
        rowCount == 0 ? .empty : .loaded
    }

    /// True when the block is a permission problem rather than an outage, so the
    /// screen offers "re-check" instead of "try again".
    public var isDenied: Bool {
        switch self {
        case .denied, .missingScope: true
        default: false
        }
    }

    public var headline: String {
        switch self {
        case .denied, .missingScope: "Tracing is locked"
        case .failed: "Couldn't load spans"
        case .empty: "No spans"
        case .loading, .loaded: "Tracing"
        }
    }

    /// The sentence the screen shows under the headline. Names the exact thing
    /// that is missing, because "locked" on its own is not actionable.
    public var detail: String {
        switch self {
        case .denied(let resource):
            """
            Your PostHog account doesn't have `viewer` access to the `\(resource)` \
            resource in this project. An organisation admin grants it in role \
            access settings — a new API key will not fix it.
            """
        case .missingScope(let scope):
            "Your PostHog API key is missing the \(scope) scope. Add it to the key, then re-check."
        case .failed(let message):
            message
        case .empty:
            "No spans were recorded in this window. Send OpenTelemetry traces to PostHog to populate it."
        case .loading:
            "Loading spans."
        case .loaded:
            "Spans loaded."
        }
    }
}

// MARK: - Span

/// An OTel span status. PostHog filters accept both the numeric code and the
/// word, and the returned column has not been observed, so both are read.
public enum SpanStatus: Sendable, Hashable {
    case unset
    case ok
    case error
    case unknown

    init(_ value: JSONValue?) {
        guard let value else { self = .unset; return }
        if case .string(let word) = value {
            switch word.lowercased() {
            case "unset", "": self = .unset
            case "ok": self = .ok
            case "error": self = .error
            default: self = .unknown
            }
            return
        }
        switch value.doubleValue {
        case 0: self = .unset
        case 1: self = .ok
        case 2: self = .error
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .unset: "Unset"
        case .ok: "OK"
        case .error: "Error"
        case .unknown: "Unknown"
        }
    }
}

/// One span from a `TraceSpansQuery`.
public struct TraceSpan: Sendable, Identifiable, Hashable {
    public let id: String
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let name: String
    public let kind: String?
    public let serviceName: String
    public let status: SpanStatus
    public let timestamp: Date?
    public let endTime: Date?
    public let durationNanos: Int
    public let isRoot: Bool
    /// `false` when the span is only in the response because it shares a trace
    /// with something that did match. Drawing it as a hit would overstate the
    /// filter's result, so the distinction is carried all the way to the row.
    public let matchedFilter: Bool
    public let attributes: [String: JSONValue]

    public var isError: Bool { status == .error }

    public var formattedDuration: String { Self.formatDuration(nanos: durationNanos) }

    public init?(row: QueryRow) {
        guard let traceID = row.string("trace_id") else { return nil }
        self.traceID = traceID
        self.spanID = row.string("span_id") ?? ""
        self.parentSpanID = row.string("parent_span_id")
        self.name = row.string("name") ?? "Unnamed span"
        self.kind = row.string("kind")
        self.serviceName = row.string("service_name") ?? "Unknown service"
        self.status = SpanStatus(row.value("status_code"))
        self.timestamp = row.date("timestamp")
        self.endTime = row.date("end_time")
        self.durationNanos = Self.wholeNumber(row.value("duration_nano")) ?? 0
        // ClickHouse hands booleans back as 0/1 as readily as true/false.
        self.isRoot = Self.truthy(row.value("is_root_span")) ?? (row.string("parent_span_id") == nil)
        self.matchedFilter = Self.truthy(row.value("matched_filter")) ?? true
        if case .object(let map)? = row.value("attributes") {
            self.attributes = map
        } else {
            self.attributes = [:]
        }
        // `uuid` is the natural identity; a composite keeps SwiftUI lists stable
        // if the column is ever absent.
        self.id = row.string("uuid") ?? "\(traceID)|\(self.spanID)"
    }

    public static func rows(from response: QueryResponse) -> [TraceSpan] {
        response.rows.compactMap(TraceSpan.init(row:))
    }

    /// Groups a flat span list into traces, newest first.
    public static func traces(from spans: [TraceSpan]) -> [TraceGroup] {
        Dictionary(grouping: spans, by: \.traceID)
            .map { TraceGroup(id: $0.key, spans: $0.value) }
            .sorted {
                ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id)
            }
    }

    /// Renders a nanosecond duration at whatever scale keeps it readable.
    ///
    /// Spans span nine orders of magnitude — a cache read and a batch job land in
    /// the same list — so a fixed unit makes one of them unreadable.
    public static func formatDuration(nanos: Int) -> String {
        let value = Double(nanos)
        switch abs(value) {
        case 1e9...:
            return "\((value / 1e9).formatted(.number.precision(.fractionLength(0...2)))) s"
        case 1e6...:
            return "\((value / 1e6).formatted(.number.precision(.fractionLength(0...1)))) ms"
        case 1e3...:
            return "\((value / 1e3).formatted(.number.precision(.fractionLength(0...1)))) µs"
        default:
            return "\(nanos.formatted()) ns"
        }
    }

    /// Reads a JSON number as an `Int` without tripping `Int(_: Double)`, which
    /// traps on non-finite values and on anything past `Int.max`.
    static func wholeNumber(_ value: JSONValue?) -> Int? {
        guard let d = value?.doubleValue, d.isFinite, abs(d) < 9e18 else { return nil }
        return Int(d)
    }

    private static func truthy(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let b): b
        case .number(let d): d != 0
        case .string(let s): s == "true" || s == "1"
        default: nil
        }
    }
}

/// The spans of one trace, with the root promoted.
public struct TraceGroup: Sendable, Identifiable, Hashable {
    public let id: String
    public let spans: [TraceSpan]

    public init(id: String, spans: [TraceSpan]) {
        self.id = id
        // Root first, then chronological: a trace is read top-down from its
        // entry point.
        self.spans = spans.sorted {
            ($0.isRoot ? 0 : 1, $0.timestamp ?? .distantPast)
                < ($1.isRoot ? 0 : 1, $1.timestamp ?? .distantPast)
        }
    }

    public var root: TraceSpan? { spans.first { $0.isRoot } ?? spans.first }
    public var name: String { root?.name ?? "Trace" }
    public var serviceName: String { root?.serviceName ?? "Unknown service" }
    public var startedAt: Date? { root?.timestamp }

    /// The trace's own span, taken from the root rather than summed: children
    /// overlap and run in parallel, so adding them would overstate wall time.
    public var durationNanos: Int { root?.durationNanos ?? 0 }
    public var formattedDuration: String { TraceSpan.formatDuration(nanos: durationNanos) }

    public var hasError: Bool { spans.contains { $0.isError } }
    public var errorCount: Int { spans.filter(\.isError).count }

    /// Short form of the trace id, for a row that cannot fit 32 hex characters.
    public var shortID: String { String(id.prefix(8)) }
}

// MARK: - Call tree

/// One `(parent) → (child)` edge from a `TraceSpansTreeQuery`.
///
/// Note this is an *aggregate*, not a single trace's structure: each row is many
/// spans collapsed together, so its numbers are counts and percentiles rather
/// than one span's timings.
public struct TraceSpanTreeEdge: Sendable, Identifiable, Hashable {
    public let parentService: String
    public let parentName: String
    public let serviceName: String
    public let name: String
    public let count: Int
    public let totalDurationNanos: Int
    public let avgDurationNanos: Int
    public let p50Nanos: Int
    public let p95Nanos: Int
    public let p99Nanos: Int
    public let errorCount: Int
    public let avgStartOffsetNanos: Int
    /// How many times this child runs per parent invocation. Null on root edges,
    /// which have no parent to divide by. A child can top the total purely by
    /// fanning out, so per-call cost needs this divisor.
    public let callsPerParentInvocation: Double?

    public var id: String { "\(parentService)|\(parentName)|\(serviceName)|\(name)" }

    /// PostHog marks a trace's entry span with the literal parent name `<ROOT>`.
    public var isRootEdge: Bool { parentName == Self.rootMarker }

    static let rootMarker = "<ROOT>"

    public var hasErrors: Bool { errorCount > 0 }

    public var errorRate: Double? {
        count > 0 ? Double(errorCount) / Double(count) : nil
    }

    public init?(row: QueryRow) {
        guard let name = row.string("name") else { return nil }
        self.name = name
        self.parentService = row.string("parent_service") ?? ""
        self.parentName = row.string("parent_name") ?? Self.rootMarker
        self.serviceName = row.string("service_name") ?? ""
        self.count = TraceSpan.wholeNumber(row.value("count")) ?? 0
        self.totalDurationNanos = TraceSpan.wholeNumber(row.value("total_duration_nano")) ?? 0
        self.avgDurationNanos = TraceSpan.wholeNumber(row.value("avg_duration_nano")) ?? 0
        self.p50Nanos = TraceSpan.wholeNumber(row.value("p50_duration_nano")) ?? 0
        self.p95Nanos = TraceSpan.wholeNumber(row.value("p95_duration_nano")) ?? 0
        self.p99Nanos = TraceSpan.wholeNumber(row.value("p99_duration_nano")) ?? 0
        self.errorCount = TraceSpan.wholeNumber(row.value("error_count")) ?? 0
        self.avgStartOffsetNanos = TraceSpan.wholeNumber(row.value("avg_start_offset_nano")) ?? 0
        self.callsPerParentInvocation = row.double("calls_per_parent_invocation")
    }

    public static func rows(from response: QueryResponse) -> [TraceSpanTreeEdge] {
        response.rows.compactMap(TraceSpanTreeEdge.init(row:))
    }

    /// Nests the flat edge list into drawable nodes, heaviest branch first.
    public static func tree(from edges: [TraceSpanTreeEdge]) -> [TraceSpanTreeNode] {
        var childrenByParent: [String: [TraceSpanTreeEdge]] = [:]
        for edge in edges where !edge.isRootEdge {
            childrenByParent["\(edge.parentService)|\(edge.parentName)", default: []].append(edge)
        }

        // The edge list is aggregated, so a name can legitimately appear as its
        // own ancestor (recursion, retries). Without a seen-set the walk below
        // would never terminate.
        func build(_ edge: TraceSpanTreeEdge, parentTotal: Int?, seen: Set<String>) -> TraceSpanTreeNode {
            var seen = seen
            let key = "\(edge.serviceName)|\(edge.name)"
            seen.insert(key)

            let children = (childrenByParent[key] ?? [])
                .filter { !seen.contains("\($0.serviceName)|\($0.name)") }
                .sorted { $0.totalDurationNanos > $1.totalDurationNanos }
                .map { build($0, parentTotal: edge.totalDurationNanos, seen: seen) }

            let share: Double? = parentTotal.flatMap { total in
                total > 0 ? Double(edge.totalDurationNanos) / Double(total) : nil
            }
            return TraceSpanTreeNode(edge: edge, children: children, shareOfParent: share)
        }

        return edges
            .filter(\.isRootEdge)
            .sorted { $0.totalDurationNanos > $1.totalDurationNanos }
            .map { build($0, parentTotal: nil, seen: []) }
    }
}

/// A call-tree edge with its children resolved.
public struct TraceSpanTreeNode: Sendable, Identifiable, Hashable {
    public let edge: TraceSpanTreeEdge
    public let children: [TraceSpanTreeNode]
    /// This edge's total time as a fraction of its parent's. **Not clamped to
    /// 1**: a child that runs several times per parent invocation genuinely
    /// accumulates more time than the parent, and hiding that would hide the
    /// fan-out that caused it.
    public let shareOfParent: Double?

    public var id: String { edge.id }

    /// Flattens the tree for a `List`, carrying each node's depth for indenting.
    public func flattened(depth: Int = 0) -> [(node: TraceSpanTreeNode, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}

// MARK: - Attribute breakdown

/// One row of a `TraceSpansAttributeBreakdownQuery` — the "what is different
/// about the bad spans?" shape.
public struct SpanAttributeBreakdownRow: Sendable, Identifiable, Hashable {
    public let value: String
    public let count: Int
    public let errorCount: Int
    public let p50Nanos: Int
    public let p95Nanos: Int

    public var id: String { value }

    /// PostHog groups spans that don't carry the attribute at all under an empty
    /// value. That is a finding, not a blank, so it is never dropped.
    public var isUnset: Bool { value.isEmpty }

    public var displayValue: String { isUnset ? "Not set" : value }

    public var errorRate: Double? {
        count > 0 ? Double(errorCount) / Double(count) : nil
    }

    public init?(row: QueryRow) {
        guard let value = row.value("value") else {
            // An explicitly empty string arrives as a non-null value; only a
            // genuinely missing column skips the row.
            guard row.columns.contains("value") else { return nil }
            self.value = ""
            self.count = TraceSpan.wholeNumber(row.value("count")) ?? 0
            self.errorCount = TraceSpan.wholeNumber(row.value("error_count")) ?? 0
            self.p50Nanos = TraceSpan.wholeNumber(row.value("p50_duration_nano")) ?? 0
            self.p95Nanos = TraceSpan.wholeNumber(row.value("p95_duration_nano")) ?? 0
            return
        }
        self.value = value.stringValue ?? ""
        self.count = TraceSpan.wholeNumber(row.value("count")) ?? 0
        self.errorCount = TraceSpan.wholeNumber(row.value("error_count")) ?? 0
        self.p50Nanos = TraceSpan.wholeNumber(row.value("p50_duration_nano")) ?? 0
        self.p95Nanos = TraceSpan.wholeNumber(row.value("p95_duration_nano")) ?? 0
    }

    public static func rows(from response: QueryResponse) -> [SpanAttributeBreakdownRow] {
        response.rows.compactMap(SpanAttributeBreakdownRow.init(row:))
    }

    /// Service names, for the explorer's service filter.
    ///
    /// There is no separately verified "list services" query kind, so the facet
    /// rides on the breakdown kind that *is* verified, broken down by the
    /// allowlisted top-level `service_name` column.
    public static func serviceNames(from response: QueryResponse) -> [String] {
        rows(from: response).filter { !$0.isUnset }.map(\.value)
    }
}
