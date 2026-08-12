import GetHogKit
import GetHogUI
import SwiftUI

private extension View {
    /// The reference screens' card row, named once because the trace list and
    /// every section of the detail sheet carry it.
    func cardRow() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
        )
        .listRowSeparator(.hidden)
    }
}

@MainActor
@Observable
final class LLMAnalyticsStore {
    var response: LLMTracesResponse?
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var traces: [LLMTrace] { response?.ranked ?? [] }
    var isEmpty: Bool { traces.isEmpty }

    func load(client: PostHogClient, projectID: Int, range: LLMDateRange, limit: Int = 50) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: LLMTracesResponse = try await client.send(
                Self.tracesEndpoint(projectID: projectID, range: range, limit: limit)
            )
            self.response = response
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Built here rather than in `PostHogAPI` because `TracesQuery` is the only
    /// caller and its response shape is unlike every other query node's.
    static func tracesEndpoint(projectID: Int, range: LLMDateRange, limit: Int) -> Endpoint {
        let payload: [String: Any] = [
            "query": [
                "kind": "TracesQuery",
                "dateRange": ["date_from": range.dateFrom],
                "limit": limit,
            ]
        ]
        return Endpoint(
            path: "/api/projects/\(projectID)/query/",
            method: "POST",
            body: try? JSONSerialization.data(withJSONObject: payload),
            category: .query
        )
    }
}

struct LLMAnalyticsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(OpenDetails.self) private var openDetails

    @State private var store = LLMAnalyticsStore()
    @State private var range: LLMDateRange = .week
    @State private var search = ""

    /// The open trace, held outside this screen and presented by `RootView`.
    ///
    /// Measured with a trace open, dragging the window 834 → 375 → 834pt: the
    /// sheet was dismissed by the resize and never returned, and `@State` here
    /// went with the host. A sheet cannot be driven across the boundary from
    /// inside a secondary screen at all — see `RootView.presentedDetail`.
    private var selected: LLMTrace? {
        get { openDetails[.llm] as? LLMTrace }
        nonmutating set { openDetails[.llm] = newValue.map(AnyHashable.init) }
    }

    var body: some View {
        content
            .navigationTitle("LLM")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search traces")
            .screenRefreshable { await load() }
            .task(id: LoadKey(projectID: model.projectID, range: range)) { await load() }
    }

    private struct LoadKey: Hashable {
        let projectID: Int?
        let range: LLMDateRange
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // LLM analytics rides `/query/`, the same endpoint as the events
            // feed, so it is gated by the identical scope.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.isEmpty {
            EmptyStateView(
                title: "Couldn't load traces",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.isEmpty && !store.isLoading {
            VStack(spacing: 0) {
                GlassFilterBar { rangePicker }
                    .padding(.vertical, Theme.Space.s)
                EmptyStateView(
                    title: "No LLM traces",
                    systemImage: "brain",
                    message: "Nothing was recorded in the \(range.accessibleTitle.lowercased()). Traces appear here once an SDK sends $ai_generation events."
                )
                .frame(maxHeight: .infinity)
            }
            .background(Theme.pageBackground)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                GlassFilterBar { rangePicker }
                    // Horizontal insets come from the bar itself, which carries
                    // the page's own margin.
                    .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: 0, bottom: Theme.Space.s, trailing: 0))
                    .listRowBackground(Color.clear)
                LLMSummaryHeader(response: store.response, range: range)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)

            Section {
                ForEach(filtered) { trace in
                    Button {
                        selected = trace
                    } label: {
                        LLMTraceRowView(trace: trace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this trace's detail")
                    .cardRow()
                }

                if filtered.isEmpty {
                    SectionEmptyState(
                        text: "No matching traces. No traces matched “\(search)”.",
                        systemImage: "magnifyingglass",
                    )
                    .listRowBackground(Color.clear)
                }
            } header: {
                SectionLabel(text: sectionTitle, systemImage: "brain")
            }

            if store.response?.hasMore == true {
                Text("Showing the first \(store.traces.count) traces in this window.")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .listRowBackground(Color.clear)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .accessibilityIdentifier("gethog.llm-list")
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    /// The heading states the sort, because a list ordered by cost and a list
    /// ordered by recency look identical and mean very different things.
    private var sectionTitle: String {
        store.response?.hasCostData == true ? "Traces by cost" : "Traces, most recent first"
    }

    private var rangePicker: some View {
        let picker = Picker("Date range", selection: $range) {
            ForEach(LLMDateRange.allCases) { option in
                Text(option.title)
                    .accessibilityLabel(option.accessibleTitle)
                    .tag(option)
            }
        }
        // Segmented labels shrink to slivers at accessibility text sizes, so
        // past that threshold the same choice becomes a menu.
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        }
        // Claims the bar's width and sits at its leading edge. The bar hugs its
        // content, so at accessibility sizes the whole thing shrank to a lone
        // pill centred in the screen with dead space either side — measured at
        // AX5, against neighbours whose filter bars all start at the leading
        // margin. A segmented picker already fills the width, so this costs the
        // ordinary case nothing.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filtered: [LLMTrace] {
        guard !search.isEmpty else { return store.traces }
        return store.traces.filter {
            $0.id.localizedCaseInsensitiveContains(search)
                || ($0.distinctID ?? "").localizedCaseInsensitiveContains(search)
                || ($0.traceName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, range: range)
    }
}

// MARK: - Summary

/// Totals for the traces actually fetched — never a project-wide claim.
struct LLMSummaryHeader: View {
    let response: LLMTracesResponse?
    let range: LLMDateRange

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: range.accessibleTitle, systemImage: "calendar")

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.xl) { figures }
                    VStack(alignment: .leading, spacing: Theme.Space.m) { figures }
                }

                if let response, response.hasMore {
                    Text("Totals cover the traces on this page, not the whole period.")
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var figures: some View {
        figure("Traces", value: (response?.traces.count ?? 0).formatted())
        figure("Cost", value: costText)
        figure("Tokens", value: (response?.totalTokens ?? 0).compactFormatted)
    }

    /// Says "not recorded" rather than "$0.00": a project whose SDK never sent
    /// token usage has unknown spend, not zero spend.
    private var costText: String {
        guard let response, response.hasCostData else { return "Not recorded" }
        return llmCurrency(response.totalCost)
    }

    private func figure(_ title: String, value: String) -> some View {
        MetricTile(label: title, value: value, compact: true)
            .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Row

struct LLMTraceRowView: View {
    let trace: LLMTrace

    var body: some View {
        DataRow(
            glyph: trace.errorCount > 0 ? "exclamationmark.triangle.fill" : "brain",
            tint: trace.errorCount > 0 ? Theme.Status.critical : Theme.accent,
            // Falls back to the trace id when the SDK named nothing, which is
            // the string a developer would paste into the web console anyway.
            title: trace.displayName,
            // A distinct id is an identifier people copy verbatim, so it keeps
            // code type and truncates only at the tail.
            subtitle: trace.distinctID ?? "Unknown person",
            footnote: usageLine,
            isSubtitleMonospaced: true,
            accessory: trace.errorCount > 0
                ? .pill("\(trace.errorCount) error\(trace.errorCount == 1 ? "" : "s")", Theme.Status.critical)
                : .metric(costText)
        )
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var usageLine: String {
        var parts: [String] = []
        // A failing trace spends its trailing slot on the error pill, so spend —
        // what this list is ranked by — is stated inline instead.
        if trace.errorCount > 0 { parts.append(costText) }
        parts.append(contentsOf: [seenText, latencyText, tokenText])
        return parts.joined(separator: " · ")
    }

    private var costText: String {
        guard let cost = trace.totalCost, cost > 0 else { return "—" }
        return llmCurrency(cost)
    }

    private var seenText: String {
        guard let createdAt = trace.createdAt else { return "No timestamp" }
        return createdAt.formatted(.relative(presentation: .named))
    }

    private var latencyText: String {
        guard let latency = trace.totalLatency, latency > 0 else { return "No latency" }
        return "\(latency.formatted(.number.precision(.fractionLength(0...2))))s"
    }

    private var tokenText: String {
        guard let total = trace.totalTokens, total > 0 else { return "No tokens" }
        return "\(total.compactFormatted) tok"
    }

    private var spokenSummary: String {
        var parts = ["Trace \(trace.shortID)"]
        if let name = trace.traceName, !name.isEmpty { parts.append(name) }
        parts.append(trace.distinctID ?? "unknown person")
        parts.append(seenText)
        parts.append(costText == "—" ? "no cost recorded" : "cost \(costText)")
        parts.append(latencyText)
        if let input = trace.inputTokens, let output = trace.outputTokens, input + output > 0 {
            parts.append(
                "\(Int(input).formatted()) input tokens, \(Int(output).formatted()) output tokens"
            )
        }
        if trace.errorCount > 0 { parts.append("\(trace.errorCount) errors") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

struct LLMTraceDetailSheet: View {
    let trace: LLMTrace
    let webURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailSheetContainer {
            List {
                // The sheet opens on what the trace cost and how long it took;
                // the breakdown below answers where that went.
                Section {
                    StatStrip {
                        MetricTile(label: "Cost", value: totalCostText, compact: true)
                        MetricTile(label: "Tokens", value: totalTokensText, compact: true)
                        MetricTile(label: "Latency", value: latencyText, compact: true)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    Group {
                        LabeledContent("ID") {
                            Text(trace.id)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if let name = trace.traceName, !name.isEmpty {
                            LabeledContent("Name") { Text(name) }
                        }
                        LabeledContent("Person") {
                            Text(trace.distinctID ?? "Unknown")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if let session = trace.sessionID, !session.isEmpty {
                            LabeledContent("AI session") {
                                Text(session).font(.caption.monospaced())
                            }
                        }
                        if let createdAt = trace.createdAt {
                            LabeledContent("Last seen") {
                                Text(createdAt, format: .dateTime.year().month().day().hour().minute())
                            }
                        }
                        if trace.errorCount > 0 {
                            LabeledContent("Errors") {
                                // A count that is also a word-and-colour pill,
                                // so a failing trace states its own severity.
                                StatusPill(
                                    text: "\(trace.errorCount) error\(trace.errorCount == 1 ? "" : "s")",
                                    tint: Theme.Status.critical
                                )
                            }
                        }
                    }
                    .cardRow()
                } header: {
                    SectionLabel(text: "Trace", systemImage: "brain")
                }

                Section {
                    Group {
                        costRow("Input", cost: trace.inputCost, tokens: trace.inputTokens)
                        costRow("Output", cost: trace.outputCost, tokens: trace.outputTokens)
                        if let request = trace.requestCost, request > 0 {
                            LabeledContent("Request") { Text(llmCurrency(request)) }
                        }
                        LabeledContent("Total") {
                            Text(totalCostText).fontWeight(.semibold)
                        }
                    }
                    .cardRow()
                } header: {
                    SectionLabel(text: "Cost and tokens", systemImage: "dollarsign.circle")
                }

                Section {
                    if trace.events.isEmpty {
                        // Stated plainly. An empty timeline with no explanation
                        // reads as a loading bug rather than as real data.
                        Text("This trace has no child events. PostHog recorded the trace totals, but no individual generations or spans were attached to it.")
                            .font(.callout)
                            .foregroundStyle(Theme.Ink.secondary)
                            .cardRow()
                    } else {
                        ForEach(trace.events) { event in
                            LLMTraceEventRow(event: event)
                                .cardRow()
                        }
                    }
                } header: {
                    SectionLabel(text: "Events", systemImage: "list.bullet")
                }

                if let webURL {
                    Section {
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                        .cardRow()
                    } footer: {
                        Text("Prompts and completions are shown in the PostHog web console.")
                    }
                }
            }
            .listRowSpacing(Theme.Space.xs)
            .pageSurface()
            .navigationTitle(trace.displayName)
            .navigationBarTitleDisplayMode(.inline)
            // Sheet chrome, and only the sheet has it: on the Mac this detail is
            // pushed, where Done would duplicate the Back button.
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }

    /// All three say "Not recorded" rather than zero: a project whose SDK never
    /// reported usage has an unknown figure, not an absent one.
    private var totalCostText: String {
        trace.totalCost.map { $0 > 0 ? llmCurrency($0) : "Not recorded" } ?? "Not recorded"
    }

    private var totalTokensText: String {
        trace.totalTokens.map { $0 > 0 ? $0.compactFormatted : "Not recorded" } ?? "Not recorded"
    }

    private var latencyText: String {
        trace.totalLatency.map {
            "\($0.formatted(.number.precision(.fractionLength(0...2))))s"
        } ?? "Not recorded"
    }

    private func costRow(_ title: String, cost: Double?, tokens: Double?) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(cost.map { $0 > 0 ? llmCurrency($0) : "—" } ?? "—")
                    .monospacedDigit()
                Text(tokens.map { "\(Int($0).formatted()) tokens" } ?? "No tokens")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LLMTraceEventRow: View {
    let event: LLMTraceEvent

    var body: some View {
        DataRow(
            glyph: glyph,
            title: event.event,
            // Model names are identifiers people match against a price list, so
            // they keep code type.
            subtitle: event.model,
            footnote: timing,
            isSubtitleMonospaced: true,
            accessory: accessory
        )
        .accessibilityElement(children: .combine)
    }

    private var accessory: RowAccessory {
        guard let latency = event.latency else { return .none }
        return .metric("\(latency.formatted(.number.precision(.fractionLength(0...2))))s")
    }

    /// Generations are the events anyone came here for; everything else on a
    /// trace — spans, embeddings, feedback — reads as scaffolding around them.
    private var glyph: String {
        event.event.contains("generation") ? "sparkles" : "circle.dashed"
    }

    private var timing: String? {
        event.timestamp.map { $0.formatted(date: .omitted, time: .standard) }
    }
}

// MARK: - Formatting
//
// File-private so concurrent work on other screens can't collide with the name.

/// PostHog reports LLM spend in USD (`$ai_total_cost_usd`), and a single trace
/// routinely costs a fraction of a cent, so the usual two-digit currency format
/// would render every row as $0.00.
private func llmCurrency(_ value: Double) -> String {
    let digits = (value != 0 && abs(value) < 0.01) ? 2...5 : 2...2
    return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
}
