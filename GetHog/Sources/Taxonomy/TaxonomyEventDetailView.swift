import GetHogKit
import SwiftUI

@MainActor
@Observable
final class EventTaxonomyStore {
    var properties: [TaxonomyPropertySample] = []
    var definitions: [String: PropertyDefinitionSummary] = [:]
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var isEmpty: Bool { properties.isEmpty }

    func load(client: PostHogClient, projectID: Int, event: String) async {
        isLoading = true
        defer { isLoading = false }

        // The property list and its curation state need different scopes, so a
        // failure in the second must not blank the first.
        var failures: [String] = []

        do {
            let page: Page<TaxonomyPropertySample> = try await client.send(
                PostHogAPI.eventTaxonomy(projectID: projectID, event: event, maxPropertyValues: 3)
            )
            // The API already orders by distinct-value count, but relying on an
            // order the response never promises is how lists start reshuffling.
            properties = page.results.sorted {
                if $0.sampleCount != $1.sampleCount { return $0.sampleCount > $1.sampleCount }
                return $0.property.localizedStandardCompare($1.property) == .orderedAscending
            }
        } catch {
            failures.append(Self.message(for: error))
        }

        do {
            let page: Page<PropertyDefinitionSummary> = try await client.send(
                PostHogAPI.propertyDefinitions(projectID: projectID, eventNames: [event])
            )
            definitions = Dictionary(page.results.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            failures.append(Self.message(for: error))
        }

        error = failures.isEmpty ? nil : failures.joined(separator: " ")
        if failures.count < 2 { loadedAt = Date() }
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

/// One event: its curation state, and the properties it actually carries.
struct TaxonomyEventDetailView: View {
    let event: TaxonomyEvent

    @Environment(AppModel.self) private var model
    @State private var store = EventTaxonomyStore()
    @State private var search = ""

    var body: some View {
        List {
            Section("Event") {
                LabeledContent("Name") {
                    Text(event.name)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let description = event.description {
                    Text(description).font(.callout)
                }
                LabeledContent("Last 30 days") {
                    Text(event.recentCount.map { $0.formatted() } ?? "Not received")
                        .monospacedDigit()
                }
                LabeledContent("Last seen") {
                    Text(event.lastSeenAt.map {
                        $0.formatted(.relative(presentation: .named))
                    } ?? "Unknown")
                }
                LabeledContent("State") {
                    Text(stateText)
                }
                if !event.tags.isEmpty {
                    LabeledContent("Tags") { Text(event.tags.joined(separator: ", ")) }
                }
                if !event.isDefined {
                    Label(
                        "This project has no definition for this event, so it has never been sent.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            propertiesSection

            if let url = model.webURL(path: "data-management/events") {
                Section {
                    Link(destination: url) {
                        Label("Open data management in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search properties")
        .refreshable { await load() }
        .task(id: event.name) { await load() }
    }

    /// Curation state as words. Verified and hidden are mutually exclusive in
    /// PostHog, so this reads as one state rather than two flags.
    private var stateText: String {
        if event.isHidden { return "Hidden" }
        if event.isVerified { return "Verified" }
        return event.isDefined ? "Not verified" : "Not defined"
    }

    @ViewBuilder
    private var propertiesSection: some View {
        Section {
            if let error = store.error, store.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load properties", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else if store.isEmpty && store.isLoading {
                // Placeholder rows rather than a spinner, so the section keeps
                // its height and the list does not jump when the data lands.
                ForEach(0..<4, id: \.self) { _ in
                    TaxonomyPropertyRowView(
                        sample: TaxonomyPropertySample(
                            property: "$placeholder_property",
                            sampleCount: 12,
                            sampleValues: ["sample", "sample"]
                        ),
                        definition: nil
                    )
                }
                .skeleton(true)
            } else if store.isEmpty {
                ContentUnavailableView {
                    Label("No properties", systemImage: "tag")
                } description: {
                    Text("No properties were found in the sampled events. PostHog samples the 100 most recent, and omits internal keys such as $ip and $set.")
                }
            } else if filtered.isEmpty {
                Text("No properties matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { property in
                    TaxonomyPropertyRowView(
                        sample: property,
                        definition: store.definitions[property.property]
                    )
                }
            }
        } header: {
            Text(store.isEmpty ? "Properties" : "\(store.properties.count) properties")
        } footer: {
            // Says exactly what the API measured. `sample_count` is the number of
            // distinct values inside a 100-event sample, not a total.
            Text("Sampled from the 100 most recent of these events in the last 30 days. Counts are distinct values within that sample, not totals.")
        }
    }

    private var filtered: [TaxonomyPropertySample] {
        guard !search.isEmpty else { return store.properties }
        return store.properties.filter { $0.property.localizedCaseInsensitiveContains(search) }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, event: event.name)
    }
}

// MARK: - Rows

struct TaxonomyPropertyRowView: View {
    let sample: TaxonomyPropertySample
    let definition: PropertyDefinitionSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sample.property)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)

                Spacer(minLength: 8)

                if definition?.isVerified == true {
                    StatusPill(text: "Verified", tint: Theme.Status.good)
                }
                if definition?.isHidden == true {
                    StatusPill(text: "Hidden", tint: .secondary)
                }
            }

            HStack(spacing: 10) {
                if let type = definition?.propertyType {
                    Text(type)
                }
                Text(sample.sampleSummary)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if !sample.sampleValues.isEmpty {
                Text(sample.sampleValues.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        var parts = [sample.property]
        if let type = definition?.propertyType { parts.append("type \(type)") }
        if definition?.isVerified == true { parts.append("verified") }
        if definition?.isHidden == true { parts.append("hidden") }
        parts.append(sample.sampleSummary)
        if !sample.sampleValues.isEmpty {
            parts.append("examples: \(sample.sampleValues.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }
}
