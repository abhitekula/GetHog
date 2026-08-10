import GetHogKit
import GetHogUI
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

/// Every value that changes the meaning of one Tracing response.
struct TracingRequestDescriptor: Hashable, Sendable {
    let authority: ResourceRequestAuthority
    let window: TracingWindow
    let service: String?
    let spanName: String
    let errorsOnly: Bool
}

@MainActor
@Observable
final class TracingStore {
    private(set) var state: ResourceAccessState = .loading
    private(set) var traces: [TraceGroup] = []
    private(set) var services: [String] = []
    private(set) var loadedAt: Date?
    private(set) var isLoading = false
    private var requestGeneration: UInt64 = 0
    private var currentRequest: TracingRequestDescriptor?
    private var serviceFacetAuthority: ResourceRequestAuthority?
    private var inFlight: InFlight?

    private struct InFlight {
        let id: UUID
        let generation: UInt64
        let request: TracingRequestDescriptor
        let currentAuthority: @MainActor () -> ResourceRequestAuthority?
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Void, Never>]
    }

    // Filters. Held here rather than in the view so a project switch or a
    // pull-to-refresh reuses whatever the user last chose.
    var window: TracingWindow = .day {
        didSet {
            if window != oldValue { invalidateFilterAuthority() }
        }
    }
    var service: String? {
        didSet {
            if service != oldValue { invalidateFilterAuthority() }
        }
    }
    var spanName = "" {
        didSet {
            if spanName != oldValue { invalidateFilterAuthority() }
        }
    }
    var errorsOnly = false {
        didSet {
            if errorsOnly != oldValue { invalidateFilterAuthority() }
        }
    }

    var isEmpty: Bool { traces.isEmpty }

    func invalidate() {
        requestGeneration &+= 1
        currentRequest = nil
        cancelInFlight()
        state = .loading
        traces = []
        services = []
        serviceFacetAuthority = nil
        loadedAt = nil
        isLoading = false
    }

    func load(
        client: PostHogClient,
        request: TracingRequestDescriptor,
        currentAuthority: @escaping @MainActor () -> ResourceRequestAuthority?
    ) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                register(
                    waiterID: waiterID,
                    continuation: continuation,
                    client: client,
                    request: request,
                    currentAuthority: currentAuthority
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    private func register(
        waiterID: UUID,
        continuation: CheckedContinuation<Void, Never>,
        client: PostHogClient,
        request: TracingRequestDescriptor,
        currentAuthority: @escaping @MainActor () -> ResourceRequestAuthority?
    ) {
        prepare(for: request)
        if var active = inFlight, active.request == request {
            active.waiters[waiterID] = continuation
            inFlight = active
            return
        }

        let id = UUID()
        let generation = requestGeneration
        inFlight = InFlight(
            id: id,
            generation: generation,
            request: request,
            currentAuthority: currentAuthority,
            task: nil,
            waiters: [waiterID: continuation]
        )
        isLoading = true
        let task = Task { @MainActor [weak self] in
            do {
                let data = try await client.data(
                    for: PostHogAPI.traceSpans(
                        projectID: request.authority.projectID,
                        dateFrom: request.window.rawValue,
                        serviceNames: request.service.map { [$0] } ?? [],
                        spanNameContains: request.spanName,
                        errorsOnly: request.errorsOnly
                    )
                )
                let spans = TraceSpan.rows(from: try QueryResponse.decode(from: data))
                self?.finish(
                    spans: spans,
                    id: id,
                    generation: generation,
                    request: request
                )
            } catch is CancellationError {
                self?.finishCancellation(id: id, generation: generation, request: request)
            } catch {
                self?.finish(
                    error: error,
                    id: id,
                    generation: generation,
                    request: request
                )
            }
        }
        inFlight?.task = task
    }

    private func prepare(for request: TracingRequestDescriptor) {
        guard currentRequest != request else { return }
        requestGeneration &+= 1
        currentRequest = request
        cancelInFlight()
        state = .loading
        traces = []
        loadedAt = nil
        if serviceFacetAuthority != nil, serviceFacetAuthority != request.authority {
            services = []
            serviceFacetAuthority = nil
        }
    }

    private func invalidateFilterAuthority() {
        guard currentRequest != nil || inFlight != nil else { return }
        requestGeneration &+= 1
        currentRequest = nil
        cancelInFlight()
        state = .loading
        traces = []
        loadedAt = nil
        isLoading = false
    }

    private func ownedFlight(
        id: UUID,
        generation: UInt64,
        request: TracingRequestDescriptor
    ) -> InFlight? {
        guard
            let active = inFlight,
            active.id == id,
            active.generation == generation,
            generation == requestGeneration,
            currentRequest == request
        else { return nil }
        return active
    }

    private func finish(
        spans: [TraceSpan],
        id: UUID,
        generation: UInt64,
        request: TracingRequestDescriptor
    ) {
        guard let active = ownedFlight(id: id, generation: generation, request: request) else {
            return
        }
        guard active.currentAuthority() == request.authority else {
            invalidate()
            return
        }
        traces = TraceSpan.traces(from: spans)
        state = .resolved(rowCount: traces.count)
        loadedAt = Date()
        updateServiceFacet(
            from: spans,
            filteredService: request.service,
            authority: request.authority
        )
        completeInFlight(id: id)
    }

    private func finish(
        error: any Error,
        id: UUID,
        generation: UInt64,
        request: TracingRequestDescriptor
    ) {
        guard let active = ownedFlight(id: id, generation: generation, request: request) else {
            return
        }
        guard active.currentAuthority() == request.authority else {
            invalidate()
            return
        }
        state = ResourceAccessState(
            failure: error,
            resource: "tracing",
            defaultScope: Capability.events.requiredScopes.joined(separator: ", ")
        )
        // The facet is left alone. A request that failed says nothing about
        // which services exist, and clearing it would strand a user who had
        // filtered to one service — the filter bar is not drawn in the failed
        // state, so they could not pick their way back out.
        completeInFlight(id: id)
    }

    private func finishCancellation(
        id: UUID,
        generation: UInt64,
        request: TracingRequestDescriptor
    ) {
        guard let active = ownedFlight(id: id, generation: generation, request: request) else {
            return
        }
        guard active.currentAuthority() == request.authority else {
            invalidate()
            return
        }
        completeInFlight(id: id)
    }

    private func cancelWaiter(id: UUID) {
        guard var active = inFlight, let waiter = active.waiters.removeValue(forKey: id) else {
            return
        }
        if active.waiters.isEmpty {
            inFlight = nil
            active.task?.cancel()
            isLoading = false
        } else {
            inFlight = active
        }
        waiter.resume()
    }

    private func completeInFlight(id: UUID) {
        guard let active = inFlight, active.id == id else { return }
        inFlight = nil
        isLoading = false
        for waiter in active.waiters.values { waiter.resume() }
    }

    private func cancelInFlight() {
        guard let active = inFlight else { return }
        inFlight = nil
        active.task?.cancel()
        for waiter in active.waiters.values { waiter.resume() }
    }

    /// Rebuilds the service filter from the spans just fetched.
    ///
    /// This used to be a second `/query/` request. It is derived now because the
    /// kind it rode on — `TraceSpansAttributeBreakdownQuery` — answers 400
    /// `"Unsupported query kind"`, and because `service_name` is on every span
    /// that already arrived: a request answered by data in hand is one more
    /// draw on a rate-limit budget shared organisation-wide.
    ///
    /// The catch is that the facet now describes the *page*. Under a service
    /// filter the page is one service by construction, so recomputing from it
    /// would collapse the menu to the user's own choice and trap them there.
    /// Filtered loads may only widen the facet, never replace it.
    private func updateServiceFacet(
        from spans: [TraceSpan],
        filteredService: String?,
        authority: ResourceRequestAuthority
    ) {
        let found = TraceSpan.serviceNames(from: spans)
        services = filteredService == nil ? found : Set(services).union(found).sorted()
        serviceFacetAuthority = authority
    }
}

// MARK: - Root

struct TracingRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    /// Read because the filter bar changes shape rather than scrolling at
    /// accessibility sizes; see `filterBar`.
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var store = TracingStore()

    /// The open trace, held in `OpenDetails` rather than pushed as a value onto
    /// the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it, and a value on
    /// the host's stack goes when the host does.
    private var selection: Binding<TraceGroup?> {
        Binding(
            get: { openDetails[.tracing] as? TraceGroup },
            set: { openDetails[.tracing] = $0.map(AnyHashable.init) }
        )
    }

    private var requestAuthority: ResourceRequestAuthority? {
        guard
            let client = model.client,
            let projectID = model.projectID,
            let authSessionID = model.authSessionID
        else { return nil }
        return ResourceRequestAuthority(
            projectID: projectID,
            region: client.region,
            authSessionID: authSessionID
        )
    }

    var body: some View {
        @Bindable var store = store

        content
            .navigationTitle("Tracing")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $store.spanName, prompt: "Filter by span name")
            .onSubmit(of: .search) { Task { await load() } }
            .screenRefreshable { await load() }
            .onChange(of: requestAuthority, initial: true) { _, _ in store.invalidate() }
            .task(id: requestAuthority) { await load() }
            .navigationDestination(item: selection) { trace in
                TraceDetailView(trace: trace)
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

            case .failed(let message) where !store.traces.isEmpty:
                VStack(spacing: 0) {
                    filterBar
                    SectionEmptyState(
                        text: "Couldn't refresh spans. \(message)",
                        systemImage: "exclamationmark.triangle",
                        actionTitle: "Try again"
                    ) { Task { await load() } }
                    .padding(.horizontal, Theme.Space.l)
                    list
                }
                .background(Theme.pageBackground)

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

    /// Three controls that do not fit a phone's width, and two different answers
    /// to that depending on the type size.
    ///
    /// **The horizontal scroll view moved inside the glass, and that is the
    /// fix.** It used to wrap the whole `GlassFilterBar`, which put the glass
    /// rectangle in the scroll *content*: wider than the viewport, so the bar was
    /// drawn with its rounded leading corner in place and then sliced flat at the
    /// last pixel column of the screen, with "All services" and "Errors only"
    /// sheared through. Measured on iPhone 17 Pro in light, dark and AX5.
    /// `GlassFilterBar`'s own trailing 16pt inset was off-screen too, so nothing
    /// signalled that the row scrolls at all — it simply looked broken. With the
    /// scroll view as the bar's *content*, the glass is a viewport-width chrome
    /// surface that keeps both rounded ends and the controls scroll within it.
    ///
    /// **And only below the accessibility threshold.** `GlassFilterBar` stacks
    /// its controls into a column at accessibility sizes, which is the right
    /// answer there — a row divides one phone width between three labels and each
    /// gets a column narrower than its own word. A scroll view handed to it as a
    /// single child would defeat that, because one child is nothing to stack:
    /// measured at AX5, the bar came back as one row with the "Errors only"
    /// toggle clipped at the glass edge. So past the threshold the controls go to
    /// the bar bare and it does its own reflow; below it, they scroll.
    ///
    /// Logs' bar is unaffected either way: it carries two controls and has never
    /// overflowed, which is why this was Tracing's defect alone.
    private var filterBar: some View {
        GlassFilterBar {
            if typeSize.isAccessibilitySize {
                filterControls
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Space.m) { filterControls }
                }
                .scrollIndicators(.hidden)
                // Nothing to scroll when the controls fit, which is the common
                // case with two of them — without this the bar rubber-bands
                // under a finger that was trying to scroll the list.
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .background(Theme.pageBackground)
    }

    @ViewBuilder
    private var filterControls: some View {
        @Bindable var store = store

        Picker("Time range", selection: $store.window) {
            ForEach(TracingWindow.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .onChange(of: store.window) { Task { await load() } }

        // Absent rather than disabled when nothing has been seen yet.
        //
        // A disabled `.menu` picker draws its value in the system's disabled ink,
        // which measured **2.47:1** in dark and **1.72:1** in light against a
        // 4.5:1 floor — and the value it was drawing, "All services", is the
        // *only* option a picker with no facet has. WCAG exempts inactive
        // controls from the contrast floor, so nothing here was strictly a
        // violation; what it was, was an unreadable control that could not be
        // operated and had nothing to offer. The facet may only widen (see
        // `updateServiceFacet`), so a service can never be selected and then
        // stranded behind a picker that has since disappeared.
        if !store.services.isEmpty {
            Picker("Service", selection: $store.service) {
                Text("All services").tag(String?.none)
                ForEach(store.services, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            .onChange(of: store.service) { Task { await load() } }
        }

        Toggle(isOn: $store.errorsOnly) {
            Label("Errors only", systemImage: "exclamationmark.octagon")
        }
        .toggleStyle(.button)
        .font(.footnote)
        // Measured 84.3×14.3pt, the same control and the same shortfall as the
        // Logs filter bar's; see `LogsRoot.filterBar`.
        .minimumHitTarget()
        .onChange(of: store.errorsOnly) { Task { await load() } }
    }

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` displays it.
    private var list: some View {
        List(selection: selection) {
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
        guard let client = model.client, let authority = requestAuthority else {
            store.invalidate()
            return
        }
        await store.load(
            client: client,
            request: TracingRequestDescriptor(
                authority: authority,
                window: store.window,
                service: store.service,
                spanName: store.spanName,
                errorsOnly: store.errorsOnly
            ),
            currentAuthority: { requestAuthority }
        )
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
                .font(.title2.weight(.semibold))
        } description: {
            VStack(spacing: Theme.Space.s) {
                Text(state.detail(tracingCopy))
                if case .denied(let resource) = state {
                    Text(resource)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.xs)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                        .accessibilityLabel("Denied resource: \(resource)")
                }
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Ink.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: Theme.Measure.prose)
        } actions: {
            if let onRecheck {
                Button("Re-check access", action: onRecheck)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    // White on `Theme.accent` measures 2.08:1 in dark. This was
                    // `Theme.pageBackground`, one of four sites that had each
                    // arrived at that answer separately; see
                    // `Theme.inkOnAccent`, which is the one answer and keeps
                    // light at white's 6.00:1 rather than the ground's 5.23:1.
                    .foregroundStyle(Theme.inkOnAccent)
            }
        }
        // This is a whole-screen/detail replacement, not an inline row. The
        // spatial host supplies glass rather than an opaque fallback, so the
        // state itself has to claim and paint the complete canvas.
        .appGround()
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
                        TraceSpanTreeView(trace: trace)
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
                    Text("The spans below, nested by parent. Built from this trace — no second request, and nothing in it that isn't already on this screen.")
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
        // Every label/value pair below stops at a readable measure instead of
        // spanning the window. See `Theme.Measure.pair`.
        .measuredPairs()
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
            //
            // Clipped to the track rather than left to its own corner radius.
            // The 2pt floor below exists because a millisecond span in a
            // multi-second trace is the normal case, and at that width SwiftUI
            // clamps the fill's 2pt radius to half its *own* 2pt width — 1pt —
            // against a track whose cap is a full 2pt. Rendered at 8× against
            // the clipped version: 1.12pt of fill outside the track's leading
            // cap. Same class as `Card`'s spine, smaller.
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(span.isError ? Theme.Status.critical : Theme.accent)
                    .frame(width: max(proxy.size.width * share, 2))
            }
            .frame(height: 4)
            .background(Color.secondary.opacity(0.15), in: .rect(cornerRadius: 2))
            .clipShape(.rect(cornerRadius: 2))
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
        // Every label/value pair below stops at a readable measure instead of
        // spanning the window. See `Theme.Measure.pair`.
        .measuredPairs()
        .navigationTitle(span.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Call tree

/// One trace's spans, nested by parent.
///
/// Takes no request and cannot fail. It used to send `TraceSpansTreeQuery`,
/// which the API answers with 400 `"Unsupported query kind"` — so this screen
/// could not have loaded for anybody. Every edge it needs is `parentSpanID` on
/// spans the caller already fetched, so the tree is built here instead.
///
/// It is also a narrower claim than the old screen made. That one aggregated
/// every trace that entered through the same span in the window; this is the
/// one trace the user opened, which is what they tapped through a trace row to
/// see.
struct TraceSpanTreeView: View {
    let trace: TraceGroup

    // Built once, in `init` rather than in `body`: `body` re-runs on every
    // render and the nesting only changes when the trace does.
    private let rows: [(node: TraceSpanNode, depth: Int)]
    private let orphanCount: Int

    init(trace: TraceGroup) {
        self.trace = trace
        let tree = trace.tree
        self.rows = tree.flatMap { $0.flattened() }
        self.orphanCount = tree.filter(\.isOrphan).count
    }

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.node.id) { entry in
                    SpanTreeRowView(
                        node: entry.node,
                        depth: entry.depth,
                        traceDuration: trace.durationNanos
                    )
                    .cardRow()
                }
            } header: {
                SectionLabel(text: trace.name, systemImage: "list.bullet.indent")
            } footer: {
                Text(footnote)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle("Call tree")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Says so when a span's parent is missing, because the indentation alone
    /// would read as "this span started the trace" — which is a different and
    /// wrong statement. A truncated trace is the normal cause: the span query
    /// is capped, and the cap can land anywhere in a trace.
    private var footnote: String {
        let base = "Each span sits under the span that started it, with its share of that span's time."
        guard orphanCount > 0 else { return base }
        return base + " \(orphanCount) span\(orphanCount == 1 ? "" : "s") \(orphanCount == 1 ? "names a parent" : "name parents") that didn't come back with this trace, so \(orphanCount == 1 ? "it is" : "they are") shown at the top level."
    }
}

struct SpanTreeRowView: View {
    let node: TraceSpanNode
    let depth: Int
    let traceDuration: Int

    private var span: TraceSpan { node.span }

    var body: some View {
        DataRow(
            // A child is drawn as a branch so the nesting survives the moment
            // the indentation runs out of width.
            glyph: depth == 0 ? "list.bullet.indent" : "arrow.turn.down.right",
            tint: span.isError ? Theme.Status.critical : Theme.accent,
            title: span.name,
            subtitle: span.serviceName,
            footnote: secondLine,
            isSubtitleMonospaced: true,
            accessory: span.isError
                ? .pill(span.status.title, Theme.Status.critical)
                : .metric(span.formattedDuration)
        )
        // Indentation is the only thing conveying nesting visually, so it is
        // stated in the accessibility label too rather than left to the offset.
        .padding(.leading, CGFloat(depth) * 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var secondLine: String {
        var parts: [String] = []
        // An erroring span spends its trailing slot on the status pill, so its
        // duration is stated here instead.
        if span.isError { parts.append(span.formattedDuration) }
        if let share = node.shareOfParent {
            parts.append("\(share.formatted(.percent.precision(.fractionLength(0...1)))) of parent")
        } else if traceDuration > 0, !span.isRoot {
            // No parent in the result to compare against, so the trace is the
            // only honest denominator.
            parts.append(
                "\((Double(span.durationNanos) / Double(traceDuration)).formatted(.percent.precision(.fractionLength(0...1)))) of trace"
            )
        }
        if node.isOrphan { parts.append("Parent not in result") }
        if !span.matchedFilter { parts.append("Context") }
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = [
            "Depth \(depth), \(span.name)",
            span.serviceName,
            span.formattedDuration,
            span.status.title,
        ]
        if let share = node.shareOfParent {
            parts.append("\(share.formatted(.percent.precision(.fractionLength(0...1)))) of its parent")
        }
        if node.isOrphan { parts.append("its parent span is not in this result") }
        if !node.children.isEmpty {
            parts.append("\(node.children.count) child span\(node.children.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}
