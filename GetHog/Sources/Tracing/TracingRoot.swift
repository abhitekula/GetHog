import GetHogKit
import SwiftUI

/// The words the tracing screens use for their own subject. Shared structure,
/// per-screen nouns — see `ResourceCopy`.
let tracingCopy = ResourceCopy(
    subject: "Tracing",
    itemNoun: "spans",
    emptyHint: "No spans were recorded in this window. Send OpenTelemetry traces to PostHog to populate it."
)

/// The span explorer.
///
/// Unusual among these screens in that its *blocked* state is the one that has
/// been seen against the real API. The organisation this was built for has no
/// `viewer` access to the `tracing` resource, and PostHog reports that as an
/// HTTP 400 rather than a 403 — so without the named `.accessDenied` case the
/// whole screen would read as "GetHog sent a malformed request". Every state
/// below is therefore explicit and named rather than inferred from whether a
/// list happens to be empty.

// MARK: - Row surface

private extension View {
    /// The reference screens' card row, applied in one place because four lists
    /// on this screen carry it.
    func cardRow() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}

// MARK: - Time range

/// The windows offered for a span search.
///
/// Short by default: tracing volume is far higher than event volume, and a
/// 30-day span query is a large bill against an organisation-wide budget.
enum TracingWindow: String, CaseIterable, Identifiable, Hashable {
    case lastHour = "-1h"
    case sixHours = "-6h"
    case day = "-24h"
    case week = "-7d"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class TracingStore {
    private(set) var state: ResourceAccessState = .loading
    private(set) var traces: [TraceGroup] = []
    private(set) var services: [String] = []
    private(set) var loadedAt: Date?
    private(set) var isLoading = false

    // Filters. Held here rather than in the view so a project switch or a
    // pull-to-refresh reuses whatever the user last chose.
    var window: TracingWindow = .day
    var service: String?
    var spanName = ""
    var errorsOnly = false

    var isEmpty: Bool { traces.isEmpty }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await client.data(
                for: PostHogAPI.traceSpans(
                    projectID: projectID,
                    dateFrom: window.rawValue,
                    serviceNames: service.map { [$0] } ?? [],
                    spanNameContains: spanName,
                    errorsOnly: errorsOnly
                )
            )
            let spans = TraceSpan.rows(from: try QueryResponse.decode(from: data))
            traces = TraceSpan.traces(from: spans)
            state = .resolved(rowCount: traces.count)
            loadedAt = Date()
        } catch {
            state = ResourceAccessState(
                failure: error,
                resource: "tracing",
                defaultScope: Capability.events.requiredScopes.joined(separator: ", ")
            )
            traces = []
        }

        // Deliberately sequential, and deliberately skipped when the span query
        // failed. The service facet exists only to filter a list; spending a
        // second request against an organisation-wide budget to populate a
        // filter for a list that isn't there is pure waste — and in this project
        // the failure is a denial, so the second call would fail identically.
        switch state {
        case .loaded, .empty:
            await loadServices(client: client, projectID: projectID)
        default:
            services = []
        }
    }

    private func loadServices(client: PostHogClient, projectID: Int) async {
        do {
            let data = try await client.data(
                for: PostHogAPI.traceServices(projectID: projectID, dateFrom: window.rawValue)
            )
            services = SpanAttributeBreakdownRow.serviceNames(
                from: try QueryResponse.decode(from: data)
            )
        } catch {
            // A missing facet is a degraded filter, not a broken screen: the
            // span list above it is already on display and stays there.
            services = []
        }
    }
}

// MARK: - Root

struct TracingRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = TracingStore()

    var body: some View {
        @Bindable var store = store

        content
            .navigationTitle("Tracing")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $store.spanName, prompt: "Filter by span name")
            .onSubmit(of: .search) { Task { await load() } }
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
            .navigationDestination(for: TraceGroup.self) { trace in
                TraceDetailView(trace: trace, window: store.window)
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Approximate: there is no `.tracing` capability, and `/query/` is
            // what tracing rides on, so the events probe (`query:read`) is the
            // closest honest gate. It cannot detect the resource-level denial
            // below, which is why that is handled separately.
            LockedCapabilityView(
                capability: .events,
                scope: model.lockedScope(for: .events)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else {
            switch store.state {
            case _ where store.state.isBlocked:
                TracingLockedView(state: store.state) {
                    Task { await model.refreshCapabilities(); await load() }
                }

            case .failed(let message):
                EmptyStateView(
                    title: "Couldn't load spans",
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )

            case .empty:
                VStack(spacing: 0) {
                    filterBar
                    EmptyStateView(
                        // Short on purpose: the title gets one line and truncates.
                        title: store.state.headline(tracingCopy),
                        systemImage: "point.3.connected.trianglepath.dotted",
                        message: emptyDescription
                    )
                    .frame(maxHeight: .infinity)
                }
                .background(Theme.pageBackground)

            default:
                VStack(spacing: 0) {
                    filterBar
                    list
                }
                .background(Theme.pageBackground)
            }
        }
    }

    /// Says which filters are narrowing the result, so an empty screen is not
    /// mistaken for an absence of data when it is really an absence of matches.
    /// Reports the absence, and — when nothing is narrowing the window — says
    /// what the screen would hold.
    ///
    /// The unfiltered case used to stop at "No spans in the last 24 hours",
    /// which names an absence and nothing else. Notebooks, Actions and Pipelines
    /// all say what the product is and what would make content appear; this now
    /// does too. With a filter applied the sentence stays as it was — the filter
    /// is already the explanation.
    private var emptyDescription: String {
        var clauses: [String] = ["No spans in the last \(store.window.title.lowercased())"]
        if let service = store.service { clauses.append("from \(service)") }
        if !store.spanName.isEmpty { clauses.append("named like “\(store.spanName)”") }
        if store.errorsOnly { clauses.append("with an error status") }
        let sentence = clauses.joined(separator: " ") + "."
        guard clauses.count == 1 else { return sentence }
        return sentence + " A span is one timed step inside a request — a handler, a query, an outbound call — and they arrive once a service exports OpenTelemetry traces to PostHog."
    }

    /// The glass bar rides a horizontal scroll view because three controls plus
    /// Dynamic Type outgrow the width, and a clipped filter is an unusable one.
    private var filterBar: some View {
        @Bindable var store = store

        return ScrollView(.horizontal) {
            GlassFilterBar {
                Picker("Time range", selection: $store.window) {
                    ForEach(TracingWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: store.window) { Task { await load() } }

                Picker("Service", selection: $store.service) {
                    Text("All services").tag(String?.none)
                    ForEach(store.services, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                .disabled(store.services.isEmpty)
                .onChange(of: store.service) { Task { await load() } }

                Toggle(isOn: $store.errorsOnly) {
                    Label("Errors only", systemImage: "exclamationmark.octagon")
                }
                .toggleStyle(.button)
                .font(.footnote)
                .onChange(of: store.errorsOnly) { Task { await load() } }
            }
            .padding(.vertical, Theme.Space.s)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground)
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.traces) { trace in
                    NavigationLink(value: trace) {
                        TraceRowView(trace: trace)
                    }
                    .cardRow()
                }
            } header: {
                SectionLabel(
                    text: "\(store.traces.count) trace\(store.traces.count == 1 ? "" : "s")",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            } footer: {
                Text("One row per trace, showing its entry span. Tap for the spans inside it.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Locked

/// The locked state, named.
///
/// Distinct from `LockedCapabilityView` because the fix is different: a missing
/// *scope* is repaired by the user editing their own API key, while a denied
/// *resource* needs an organisation admin to grant role access. Sending someone
/// to regenerate a key over a role problem wastes their afternoon, so this view
/// says which of the two it is.
struct TracingLockedView: View {
    let state: ResourceAccessState
    var onRecheck: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(state.headline(tracingCopy), systemImage: "lock")
        } description: {
            VStack(spacing: Theme.Space.s) {
                Text(state.detail(tracingCopy))
                if case .denied(let resource) = state {
                    Text(resource)
                        .font(.footnote.monospaced())
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.xs)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                        .accessibilityLabel("Denied resource: \(resource)")
                }
            }
        } actions: {
            if let onRecheck {
                Button("Re-check access", action: onRecheck)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Rows

struct TraceRowView: View {
    let trace: TraceGroup

    var body: some View {
        DataRow(
            glyph: trace.hasError
                ? "exclamationmark.triangle.fill"
                : "point.3.connected.trianglepath.dotted",
            tint: trace.hasError ? Theme.Status.critical : Theme.accent,
            title: trace.name,
            // The trace id is what you paste into the web console, so it stays
            // monospaced even truncated.
            subtitle: trace.shortID,
            footnote: shape,
            isSubtitleMonospaced: true,
            accessory: trace.hasError
                ? .pill("Error", Theme.Status.critical)
                : .metric(trace.formattedDuration)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var shape: String {
        var parts = [trace.serviceName]
        // A failing trace spends its trailing slot on the error pill, so wall
        // time moves down here rather than dropping off the row entirely.
        if trace.hasError { parts.append(trace.formattedDuration) }
        parts.append("\(trace.spans.count) span\(trace.spans.count == 1 ? "" : "s")")
        if let started = trace.startedAt {
            parts.append(started.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = [trace.name, trace.serviceName, trace.formattedDuration]
        parts.append("\(trace.spans.count) spans")
        if trace.hasError { parts.append("\(trace.errorCount) with an error") }
        if let started = trace.startedAt {
            parts.append(started.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Trace detail

struct TraceDetailView: View {
    let trace: TraceGroup
    var window: TracingWindow = .day

    var body: some View {
        List {
            Section {
                StatStrip {
                    MetricTile(label: "Duration", value: trace.formattedDuration, compact: true)
                    MetricTile(label: "Spans", value: trace.spans.count.formatted(), compact: true)
                    MetricTile(
                        label: "Errors",
                        value: trace.errorCount.formatted(),
                        compact: true
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                Group {
                    LabeledContent("ID") {
                        Text(trace.id).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Service") { Text(trace.serviceName) }
                    if let started = trace.startedAt {
                        LabeledContent("Started") { Text(started, format: .dateTime) }
                    }
                }
                .cardRow()
            } header: {
                SectionLabel(text: "Trace", systemImage: "point.3.connected.trianglepath.dotted")
            }

            if let root = trace.root {
                Section {
                    NavigationLink {
                        TraceSpanTreeView(
                            serviceName: root.serviceName,
                            spanName: root.name,
                            window: window
                        )
                    } label: {
                        DataRow(
                            glyph: "list.bullet.indent",
                            title: "Call tree",
                            subtitle: root.name,
                            isSubtitleMonospaced: true,
                            accessory: .none
                        )
                    }
                    .accessibilityLabel("Call tree for \(root.name)")
                    .cardRow()
                } footer: {
                    Text("Aggregates every trace that entered through this span in the window, not just this one.")
                }
            }

            Section {
                ForEach(trace.spans) { span in
                    NavigationLink {
                        SpanDetailView(span: span)
                    } label: {
                        SpanRowView(span: span, traceDuration: trace.durationNanos)
                    }
                    .cardRow()
                }
            } header: {
                SectionLabel(text: "Spans", systemImage: "rectangle.stack")
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle(trace.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SpanRowView: View {
    let span: TraceSpan
    let traceDuration: Int

    /// This span's slice of the trace's wall time, drawn as a bar.
    private var share: Double {
        guard traceDuration > 0 else { return 0 }
        return min(Double(span.durationNanos) / Double(traceDuration), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            DataRow(
                glyph: span.isError ? "exclamationmark.triangle.fill" : "circle.dashed",
                tint: span.isError ? Theme.Status.critical : Theme.accent,
                title: span.name,
                subtitle: span.serviceName,
                footnote: qualifiers,
                isSubtitleMonospaced: true,
                accessory: span.isError
                    ? .pill(span.status.title, Theme.Status.critical)
                    : .metric(span.formattedDuration)
            )

            // The bar is what makes a slow span findable without reading a
            // single duration, so it survives the move to `DataRow`.
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(span.isError ? Theme.Status.critical : Theme.accent)
                    .frame(width: max(proxy.size.width * share, 2))
            }
            .frame(height: 4)
            .background(Color.secondary.opacity(0.15), in: .rect(cornerRadius: 2))
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var qualifiers: String {
        var parts: [String] = []
        // An erroring span spends its trailing slot on the status pill, so its
        // duration is stated here instead.
        if span.isError { parts.append(span.formattedDuration) }
        if span.isRoot { parts.append("Root") }
        if !span.matchedFilter {
            // Present only because it shares a trace with a match. Saying so
            // keeps the filter's result honest.
            parts.append("Context")
        }
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = [span.name, span.serviceName, span.formattedDuration, span.status.title]
        if span.isRoot { parts.append("root span") }
        if !span.matchedFilter { parts.append("context only, did not match the filter") }
        return parts.joined(separator: ", ")
    }
}

struct SpanDetailView: View {
    let span: TraceSpan

    private var sortedAttributes: [(key: String, value: String)] {
        span.attributes
            .compactMap { key, value in
                value.stringValue.map { (key: key, value: $0) }
            }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            Section {
                Group {
                    LabeledContent("Name") { Text(span.name) }
                    LabeledContent("Service") { Text(span.serviceName) }
                    LabeledContent("Status") {
                        // The status reads as a word here too: severity never
                        // rests on the row's tint alone.
                        StatusPill(
                            text: span.status.title,
                            tint: span.isError ? Theme.Status.critical : Theme.Status.good
                        )
                    }
                    LabeledContent("Duration") { Text(span.formattedDuration) }
                    if let kind = span.kind {
                        LabeledContent("Kind") { Text(kind) }
                    }
                    if let timestamp = span.timestamp {
                        LabeledContent("Started") { Text(timestamp, format: .dateTime) }
                    }
                    LabeledContent("Span ID") {
                        Text(span.spanID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let parent = span.parentSpanID {
                        LabeledContent("Parent") {
                            Text(parent).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .cardRow()
            } header: {
                SectionLabel(text: "Span", systemImage: "circle.dashed")
            }

            Section {
                if sortedAttributes.isEmpty {
                    Text("This span carries no attributes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .cardRow()
                } else {
                    ForEach(sortedAttributes, id: \.key) { attribute in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attribute.key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(attribute.value)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(attribute.key): \(attribute.value)")
                        .cardRow()
                    }
                }
            } header: {
                SectionLabel(text: "Attributes", systemImage: "tag")
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle(span.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Call tree

/// The aggregated call tree under one service + span.
///
/// Both are required by the API — the query is rejected without either — which
/// is why this screen is only reachable from a trace whose root supplies them,
/// rather than from a pair of free-text fields the user could leave half filled.
struct TraceSpanTreeView: View {
    @Environment(AppModel.self) private var model

    let serviceName: String
    let spanName: String
    var window: TracingWindow = .day

    @State private var state: ResourceAccessState = .loading
    @State private var nodes: [TraceSpanTreeNode] = []
    @State private var loadedAt: Date?

    var body: some View {
        content
            .navigationTitle("Call tree")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case _ where state.isBlocked:
            TracingLockedView(state: state) {
                Task { await model.refreshCapabilities(); await load() }
            }

        case .failed(let message):
            EmptyStateView(
                title: "Couldn't load the call tree",
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )

        case .empty:
            EmptyStateView(
                title: "No call tree",
                systemImage: "list.bullet.indent",
                message: "No trace entered through \(spanName) in \(serviceName) during the last \(window.title.lowercased())."
            )

        default:
            list
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(flattened, id: \.node.id) { entry in
                    TreeEdgeRowView(node: entry.node, depth: entry.depth)
                        .cardRow()
                }
            } header: {
                SectionLabel(text: spanName, systemImage: "list.bullet.indent")
            } footer: {
                Text("Percentiles are across every matching span in the window. A child can exceed its parent's total by running more than once per call.")
            }

            FreshnessLabel(date: loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(state == .loading)
    }

    private var flattened: [(node: TraceSpanTreeNode, depth: Int)] {
        nodes.flatMap { $0.flattened() }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        do {
            let data = try await client.data(
                for: PostHogAPI.traceSpanTree(
                    projectID: projectID,
                    serviceName: serviceName,
                    spanName: spanName,
                    dateFrom: window.rawValue
                )
            )
            let edges = TraceSpanTreeEdge.rows(from: try QueryResponse.decode(from: data))
            nodes = TraceSpanTreeEdge.tree(from: edges)
            state = .resolved(rowCount: edges.count)
            loadedAt = Date()
        } catch {
            state = ResourceAccessState(
                failure: error,
                resource: "tracing",
                defaultScope: Capability.events.requiredScopes.joined(separator: ", ")
            )
            nodes = []
        }
    }
}

struct TreeEdgeRowView: View {
    let node: TraceSpanTreeNode
    let depth: Int

    private var edge: TraceSpanTreeEdge { node.edge }

    var body: some View {
        DataRow(
            // A child edge is drawn as a branch so nesting survives the moment
            // the indentation runs out of width.
            glyph: depth == 0 ? "list.bullet.indent" : "arrow.turn.down.right",
            tint: edge.hasErrors ? Theme.Status.critical : Theme.accent,
            title: edge.name,
            subtitle: timings,
            footnote: secondLine,
            accessory: edge.hasErrors
                ? .pill("\(edge.errorCount) err", Theme.Status.critical)
                : .metric(TraceSpan.formatDuration(nanos: edge.p95Nanos))
        )
        // Indentation is the only thing conveying nesting, so it is stated in
        // the accessibility label too rather than left to the visual offset.
        .padding(.leading, CGFloat(depth) * 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var timings: String {
        var parts = [
            "\(Double(edge.count).compactFormatted) calls",
            "p50 \(TraceSpan.formatDuration(nanos: edge.p50Nanos))",
        ]
        // The error pill takes the trailing slot on a failing edge, so p95 —
        // the number this tree is read for — moves inline rather than away.
        if edge.hasErrors {
            parts.append("p95 \(TraceSpan.formatDuration(nanos: edge.p95Nanos))")
        }
        return parts.joined(separator: " · ")
    }

    private var secondLine: String {
        var parts = ["Total \(TraceSpan.formatDuration(nanos: edge.totalDurationNanos))"]
        if let share = node.shareOfParent {
            parts.append("\(share.formatted(.percent.precision(.fractionLength(0...1)))) of parent")
        }
        if let calls = edge.callsPerParentInvocation {
            parts.append("\(calls.formatted(.number.precision(.fractionLength(0...1))))× per call")
        }
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = [
            "Depth \(depth), \(edge.name)",
            "\(edge.count.formatted()) calls",
            "p95 \(TraceSpan.formatDuration(nanos: edge.p95Nanos))",
            "total \(TraceSpan.formatDuration(nanos: edge.totalDurationNanos))",
        ]
        if edge.hasErrors { parts.append("\(edge.errorCount) errors") }
        if let calls = edge.callsPerParentInvocation {
            parts.append("\(calls.formatted(.number.precision(.fractionLength(0...1)))) calls per parent invocation")
        }
        return parts.joined(separator: ", ")
    }
}
