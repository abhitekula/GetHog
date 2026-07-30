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
//
// There is exactly **one** decoder, because `TraceSpansQuery` is the only
// tracing kind the API still answers: the tree and attribute-breakdown kinds
// return 400 `"Unsupported query kind"` (measured 2026-07-30 against project
// [REMOVED PRIVATE DATA]). Everything those kinds used to be asked for is derived here from the
// spans instead — the call tree from `parentSpanID`/`spanID`, the service facet
// from `serviceName`, both of which arrive on every span.

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

    /// The services present in a span list, for the explorer's filter.
    ///
    /// Derived rather than asked for: the query kind that answered this
    /// server-side is gone (400 `"Unsupported query kind"`, measured
    /// 2026-07-30), and `service_name` is on every span anyway.
    ///
    /// This names the services **in this result**, not every service in the
    /// project — a page is capped by `limit`, and a page fetched *with* a
    /// service filter contains exactly one service by construction. A caller
    /// must therefore not let the facet shrink under a filter it already
    /// applied; `TracingStore` handles that.
    public static func serviceNames(from spans: [TraceSpan]) -> [String] {
        // A span can carry an empty `service_name`. It is not a service anyone
        // can filter by, and it would render as a blank menu row.
        Set(spans.map(\.serviceName).filter { !$0.isEmpty }).sorted()
    }

    /// Nests a span list into drawable nodes, using `parentSpanID` as the edge
    /// set.
    ///
    /// Replaces `TraceSpansTreeQuery`, which the API no longer has. Three things
    /// the input does in practice that a naive walk does not survive:
    ///
    /// * **Orphans.** A span whose `parentSpanID` names a span that is not in
    ///   the list. Routine — `limit` truncates a trace wherever it lands — so
    ///   the orphan is promoted to the top of the forest and flagged, never
    ///   dropped.
    /// * **Cycles.** `parent_span_id` is producer-supplied and nothing
    ///   validates it, so a loop is possible; ancestors are tracked and no span
    ///   is ever nested beneath itself.
    /// * **Spans reachable from no root at all.** A cycle with no entry point
    ///   would leave its members unvisited. They are promoted last, so the
    ///   number of nodes drawn always equals the number of spans handed in.
    public static func tree(from spans: [TraceSpan]) -> [TraceSpanNode] {
        let present = Set(spans.map(\.spanID))
        var childrenByParent: [String: [TraceSpan]] = [:]
        for span in spans {
            guard let parent = span.parentSpanID,
                  parent != span.spanID,
                  present.contains(parent)
            else { continue }
            childrenByParent[parent, default: []].append(span)
        }

        // Keyed on `id` (the span's own identity) rather than `spanID`, so two
        // spans that report the same `span_id` are still drawn once each.
        var placed: Set<String> = []

        func build(_ span: TraceSpan, parentDuration: Int?, ancestors: Set<String>) -> TraceSpanNode {
            placed.insert(span.id)
            var ancestors = ancestors
            ancestors.insert(span.spanID)

            var children: [TraceSpanNode] = []
            for child in (childrenByParent[span.spanID] ?? []).sorted(by: precedes) {
                guard !ancestors.contains(child.spanID), !placed.contains(child.id) else { continue }
                children.append(
                    build(child, parentDuration: span.durationNanos, ancestors: ancestors)
                )
            }

            return TraceSpanNode(
                span: span,
                children: children,
                shareOfParent: parentDuration.flatMap { total in
                    total > 0 ? Double(span.durationNanos) / Double(total) : nil
                },
                isOrphan: parentDuration == nil && span.parentSpanID != nil
            )
        }

        let ordered = spans.sorted(by: precedes)
        var roots: [TraceSpanNode] = []
        for span in ordered where !placed.contains(span.id) {
            let isForestRoot = span.parentSpanID.map {
                $0 == span.spanID || !present.contains($0)
            } ?? true
            guard isForestRoot else { continue }
            roots.append(build(span, parentDuration: nil, ancestors: []))
        }
        // Whatever is left belongs to a cycle with no way in. Drawing it flat
        // beats losing it.
        for span in ordered where !placed.contains(span.id) {
            roots.append(build(span, parentDuration: nil, ancestors: []))
        }
        return roots
    }

    /// Entry span first, then by start time — a trace reads top-down from where
    /// it began. `spanID` only breaks ties, so the order cannot wobble between
    /// two renders of the same data.
    private static func precedes(_ a: TraceSpan, _ b: TraceSpan) -> Bool {
        (a.isRoot ? 0 : 1, a.timestamp ?? .distantPast, a.spanID)
            < (b.isRoot ? 0 : 1, b.timestamp ?? .distantPast, b.spanID)
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

    /// The same spans, nested by `parentSpanID`. Costs no request: the spans
    /// arrived with the trace.
    public var tree: [TraceSpanNode] { TraceSpan.tree(from: spans) }
}

// MARK: - Call tree

/// One span with its children resolved.
///
/// Built on the phone from `parentSpanID`/`spanID`. Its server-side equivalent,
/// `TraceSpansTreeQuery`, answers 400 `"Unsupported query kind"` — and was an
/// *aggregate* over every trace that entered through a span, where this is the
/// structure of one concrete trace, which is what a trace detail screen is
/// actually asking about.
public struct TraceSpanNode: Sendable, Identifiable, Hashable {
    public let span: TraceSpan
    public let children: [TraceSpanNode]

    /// This span's wall time as a fraction of its parent's. Nil at the top of
    /// the forest, which has no parent to divide by.
    ///
    /// **Not clamped to 1.** Clock skew between two services, and work that
    /// outlives the span that kicked it off, both push a child past its parent;
    /// clamping would hide exactly the anomaly worth opening a trace for.
    public let shareOfParent: Double?

    /// True when this node sits at the top of the forest but is not a trace
    /// entry span — its parent was not in the result, normally because `limit`
    /// truncated the trace. Surfaced so a screen can say the span above it is
    /// missing rather than imply the trace began here.
    public let isOrphan: Bool

    public var id: String { span.id }

    /// Flattens the tree for a `List`, carrying each node's depth for indenting.
    public func flattened(depth: Int = 0) -> [(node: TraceSpanNode, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}
