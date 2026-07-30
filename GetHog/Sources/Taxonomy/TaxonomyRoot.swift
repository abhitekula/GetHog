import GetHogKit
import SwiftUI

@MainActor
@Observable
final class TaxonomyStore {
    var events: [TaxonomyEvent] = []
    /// What `/event_definitions/` reports as the project total, which is not the
    /// same question as "how many events had volume", and is kept separate.
    var definedCount: Int?
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var isEmpty: Bool { events.isEmpty }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }

        // Two independent calls. Definitions need `event_definition:read` while
        // the taxonomy query needs `query:read`, so a key with one and not the
        // other must still get the half it is allowed to see.
        var failures: [String] = []
        var volumes: [TaxonomyEventVolume] = []
        var definitions: [EventDefinitionSummary] = []

        do {
            let page: Page<TaxonomyEventVolume> = try await client.send(
                PostHogAPI.teamTaxonomy(projectID: projectID)
            )
            volumes = page.results
        } catch {
            failures.append(Self.message(for: error))
        }

        do {
            let page: Page<EventDefinitionSummary> = try await client.send(
                PostHogAPI.eventDefinitions(projectID: projectID)
            )
            definitions = page.results
            definedCount = page.count
        } catch {
            failures.append(Self.message(for: error))
        }

        events = TaxonomyEvent.merge(volumes: volumes, definitions: definitions)
        error = failures.isEmpty ? nil : failures.joined(separator: " ")
        if failures.count < 2 { loadedAt = Date() }
    }

    var activeCount: Int { events.filter { $0.status == .active }.count }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

/// What data this project actually has: events ranked by volume, and what a
/// human has curated on top of them.
///
/// Two totals appear here on purpose. PostHog's taxonomy query counts events
/// received in the **last 30 days**; the event definitions list counts every
/// event name ever ingested. Reporting either as "the number of events" would
/// misstate one of them, so both are labelled for what they are.
struct TaxonomyRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = TaxonomyStore()
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle("Taxonomy")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search events")
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
            .navigationDestination(for: TaxonomyEvent.self) { event in
                TaxonomyEventDetailView(event: event)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Approximate: the volume list runs through `/query/`, which is the
            // scope `.events` probes. The definitions list wants
            // `event_definition:read`, which no capability models.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.isEmpty {
            EmptyStateView(
                title: "Couldn't load the taxonomy",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.isEmpty && !store.isLoading {
            // Says what the two calls returned, and nothing beyond it. The
            // previous copy — "This project hasn't received any events" — was a
            // claim about ingestion that an empty taxonomy response does not
            // support, and the app itself disproved it two tabs away: the Events
            // feed was listing `$autocapture` and `$web_vitals` while Ingestion's
            // header read "7 warnings · 5.4K events".
            EmptyStateView(
                title: "Nothing in the taxonomy",
                systemImage: "list.bullet.rectangle",
                message: "PostHog returned no events for the last 30 days and no registered event names for this project. That is what the taxonomy knows, not whether events are arriving — the Events feed reads the raw stream."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if search.isEmpty {
                Section {
                    TaxonomySummaryCard(
                        activeCount: store.activeCount,
                        definedCount: store.definedCount
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }

            section(
                for: .active,
                header: "Events by volume",
                systemImage: "bolt.fill",
                footer: "Counted over the last 30 days — the window PostHog's taxonomy query uses, which isn't adjustable."
            )

            section(
                for: .quiet,
                header: "Quiet",
                systemImage: "moon.zzz",
                footer: "Not received in the last 30 days."
            )

            neverSentSection

            if !search.isEmpty && filtered.isEmpty {
                Text("No events matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = store.error, !store.isEmpty {
                Label("Part of this screen is missing. \(error)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    @ViewBuilder
    private func section(
        for status: TaxonomyEvent.Status,
        header: String,
        systemImage: String,
        footer: String
    ) -> some View {
        let events = filtered.filter { $0.status == status }
        if !events.isEmpty {
            Section {
                ForEach(events) { event in
                    NavigationLink(value: event) {
                        TaxonomyEventRowView(event: event)
                    }
                    .listRowBackground(
                        Theme.cardBackground
                            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                            .padding(.vertical, 1)
                    )
                    .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(text: header, systemImage: systemImage)
            } footer: {
                Text(footer)
            }
        }
    }

    /// Padding rows, folded away by default.
    ///
    /// PostHog appends its own well-known event names at count 0 to the last page
    /// of the taxonomy response, whether or not the project has ever sent them.
    /// Dropping them would leave the row count unexplained; listing them inline
    /// would bury the project's real events under names it has never used.
    @ViewBuilder
    private var neverSentSection: some View {
        let events = filtered.filter { $0.status == .neverSent }
        if !events.isEmpty {
            Section {
                DisclosureGroup("\(events.count) recognised names") {
                    ForEach(events) { event in
                        Text(event.name)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionLabel(text: "Never sent", systemImage: "questionmark.circle")
            } footer: {
                Text("PostHog pads its taxonomy answer with event names it recognises. These have no definition in this project, so nothing has ever sent them.")
            }
        }
    }

    private var filtered: [TaxonomyEvent] {
        guard !search.isEmpty else { return store.events }
        return store.events.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.description ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Summary

/// The two totals, side by side and separately labelled.
struct TaxonomySummaryCard: View {
    let activeCount: Int
    let definedCount: Int?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    stat(
                        value: String(activeCount),
                        label: "Active",
                        detail: "last 30 days"
                    )
                    // Absent rather than zero when the definitions call failed:
                    // "0 defined" would be a claim the API never made.
                    stat(
                        value: definedCount.map(String.init) ?? "—",
                        label: "Defined",
                        detail: definedCount == nil ? "not loaded" : "all time"
                    )
                }

                Text("These count different things: one is what arrived recently, the other is every event name this project has ever registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private func stat(value: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MetricTile(label: label, value: value, compact: true)
            // The window each figure was measured over is the whole point of
            // showing two of them, so it rides under the tile rather than being
            // folded into the label.
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spokenSummary: String {
        let defined = definedCount.map { "\($0) events defined all time" }
            ?? "the defined event count did not load"
        return "\(activeCount) events active in the last 30 days, \(defined)."
    }
}

// MARK: - Rows

struct TaxonomyEventRowView: View {
    let event: TaxonomyEvent

    var body: some View {
        // The event name leads the row rather than sitting in a monospaced
        // second line: it is what the row is *about*, and the glyph beside it
        // now carries the "this is an event" signal the monospacing used to.
        DataRow(
            glyph: "bolt",
            title: event.name,
            subtitle: event.description,
            footnote: volumeText,
            accessory: curationAccessory
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Verified and hidden are mutually exclusive in PostHog, so this reads as
    /// one state rather than two flags — and an ordinary event gets no pill at
    /// all, because "not verified" on every row is noise.
    private var curationAccessory: RowAccessory {
        if event.isHidden { return .pill("Hidden", .secondary) }
        if event.isVerified { return .pill("Verified", Theme.Status.good) }
        return .none
    }

    private var volumeText: String {
        if let count = event.recentCount, count > 0 {
            return "\(Double(count).compactFormatted) in the last 30 days"
        }
        guard let lastSeen = event.lastSeenAt else { return "Not seen in the last 30 days" }
        return "Last seen \(lastSeen.formatted(.relative(presentation: .named)))"
    }

    private var spokenSummary: String {
        var parts = [event.name]
        if event.isVerified { parts.append("verified") }
        if event.isHidden { parts.append("hidden") }
        if let description = event.description { parts.append(description) }
        if let count = event.recentCount, count > 0 {
            parts.append("\(count.formatted()) events in the last 30 days")
        } else {
            parts.append(volumeText)
        }
        return parts.joined(separator: ", ")
    }
}
