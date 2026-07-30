import GetHogKit
import SwiftUI

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

    @State private var store = LLMAnalyticsStore()
    @State private var range: LLMDateRange = .week
    @State private var selected: LLMTrace?
    @State private var search = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("LLM")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search traces")
                .refreshable { await load() }
                .task(id: LoadKey(projectID: model.projectID, range: range)) { await load() }
        }
        .sheet(item: $selected) { trace in
            LLMTraceDetailSheet(
                trace: trace,
                webURL: model.webURL(path: "llm-analytics/traces/\(trace.id)")
            )
        }
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
            ContentUnavailableView {
                Label("Couldn't load traces", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.isEmpty && !store.isLoading {
            VStack(spacing: 0) {
                rangePicker.padding(16)
                ContentUnavailableView(
                    "No LLM traces",
                    systemImage: "brain",
                    description: Text(
                        "Nothing was recorded in the \(range.accessibleTitle.lowercased()). Traces appear here once an SDK sends $ai_generation events."
                    )
                )
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                rangePicker
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                LLMSummaryHeader(response: store.response, range: range)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section(sectionTitle) {
                ForEach(filtered) { trace in
                    Button {
                        selected = trace
                    } label: {
                        LLMTraceRowView(trace: trace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this trace's detail")
                }

                if filtered.isEmpty {
                    Text("No traces matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if store.response?.hasMore == true {
                Text("Showing the first \(store.traces.count) traces in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .skeleton(store.isLoading && store.isEmpty)
    }

    /// The heading states the sort, because a list ordered by cost and a list
    /// ordered by recency look identical and mean very different things.
    private var sectionTitle: String {
        store.response?.hasCostData == true ? "Traces by cost" : "Traces, most recent first"
    }

    @ViewBuilder
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
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
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
                Text(range.accessibleTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { figures }
                    VStack(alignment: .leading, spacing: 12) { figures }
                }

                if let response, response.hasMore {
                    Text("Totals cover the traces on this page, not the whole period.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Row

struct LLMTraceRowView: View {
    let trace: LLMTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The trace id is an identifier developers copy verbatim, so it
                // is set monospaced and truncated only at the tail.
                Text(trace.shortID)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(costText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            if let name = trace.traceName, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }

            Text(trace.distinctID ?? "Unknown person")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                Text(seenText)
                Text(latencyText)
                Text(tokenText)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
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
        NavigationStack {
            List {
                Section("Trace") {
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
                    LabeledContent("Latency") {
                        Text(
                            trace.totalLatency.map {
                                "\($0.formatted(.number.precision(.fractionLength(0...2))))s"
                            } ?? "Not recorded"
                        )
                    }
                    if trace.errorCount > 0 {
                        LabeledContent("Errors") { Text(trace.errorCount.formatted()) }
                    }
                }

                Section("Cost and tokens") {
                    costRow("Input", cost: trace.inputCost, tokens: trace.inputTokens)
                    costRow("Output", cost: trace.outputCost, tokens: trace.outputTokens)
                    if let request = trace.requestCost, request > 0 {
                        LabeledContent("Request") { Text(llmCurrency(request)) }
                    }
                    LabeledContent("Total") {
                        Text(
                            (trace.totalCost).map { $0 > 0 ? llmCurrency($0) : "Not recorded" }
                                ?? "Not recorded"
                        )
                        .fontWeight(.semibold)
                    }
                }

                Section("Events") {
                    if trace.events.isEmpty {
                        // Stated plainly. An empty timeline with no explanation
                        // reads as a loading bug rather than as real data.
                        Text("This trace has no child events. PostHog recorded the trace totals, but no individual generations or spans were attached to it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(trace.events) { event in
                            LLMTraceEventRow(event: event)
                        }
                    }
                }

                if let webURL {
                    Section {
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    } footer: {
                        Text("Prompts and completions are shown in the PostHog web console.")
                    }
                }
            }
            .navigationTitle(trace.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func costRow(_ title: String, cost: Double?, tokens: Double?) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(cost.map { $0 > 0 ? llmCurrency($0) : "—" } ?? "—")
                    .monospacedDigit()
                Text(tokens.map { "\(Int($0).formatted()) tokens" } ?? "No tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LLMTraceEventRow: View {
    let event: LLMTraceEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.event)
                .font(.subheadline.monospaced())
                .lineLimit(1)

            HStack(spacing: 10) {
                if let model = event.model { Text(model) }
                if let latency = event.latency {
                    Text("\(latency.formatted(.number.precision(.fractionLength(0...2))))s")
                }
                if let timestamp = event.timestamp {
                    Text(timestamp, format: .dateTime.hour().minute().second())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
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
