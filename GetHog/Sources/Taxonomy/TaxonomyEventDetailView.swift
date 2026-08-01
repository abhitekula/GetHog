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
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = EventTaxonomyStore()
    @State private var search = ""

    /// The open property — level 2 of the Taxonomy screen, under the event at
    /// level 0. Level 1 belongs to a property opened from the root's own
    /// Properties list, which is a sibling of this screen rather than its parent.
    ///
    /// Held in `OpenDetails` for the reason every level here is: this whole
    /// subtree is rebuilt when the size class swaps hosts, and `@State` under it
    /// does not survive that.
    ///
    /// Carries the sampled key rather than a definition, because the two are not
    /// the same set: `EventTaxonomyQuery` reports properties straight off the
    /// events, including ones with no registered definition, and a destination
    /// keyed on a definition could not open those at all.
    private var openProperty: Binding<TaxonomyPropertyTarget?> {
        Binding(
            get: { openDetails[.taxonomy, level: 2] as? TaxonomyPropertyTarget },
            set: { openDetails[.taxonomy, level: 2] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name") {
                    Text(event.name)
                        .font(.caption.monospaced())
                        // An event name, not prose — `$autocapture`,
                        // `checkout_completed`. A `LabeledContent` value sits
                        // in a right-hand column, so at accessibility sizes it is
                        // the narrowest text on the screen and the likeliest to
                        // be broken; `zxx` is the ISO code for "no linguistic
                        // content", so it cannot be broken with a hyphen the name
                        // does not contain.
                        .typesettingLanguage(Locale.Language(identifier: "zxx"))
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
            } header: {
                SectionLabel(text: "Event", systemImage: "bolt")
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
        .pageSurface()
        // Every label/value pair below stops at a readable measure instead of
        // spanning the window. See `Theme.Measure.pair`.
        .measuredPairs()
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search properties")
        .refreshable { await load() }
        .task(id: event.name) { await load() }
        .navigationDestination(item: openProperty) { target in
            TaxonomyPropertyDetailView(
                key: target.key,
                definition: target.definition,
                event: target.event
            )
        }
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
                EmptyStateView(
                    title: "Couldn't load properties",
                    systemImage: "exclamationmark.triangle",
                    message: error,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
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
                EmptyStateView(
                    title: "No properties",
                    systemImage: "tag",
                    message: "No properties were found in the sampled events. PostHog samples the 100 most recent, and omits internal keys such as $ip and $set."
                )
            } else if filtered.isEmpty {
                Text("No properties matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { property in
                    Button {
                        openProperty.wrappedValue = TaxonomyPropertyTarget(
                            key: property.property,
                            definition: store.definitions[property.property],
                            event: event.name
                        )
                    } label: {
                        // **The label carries a gesture of its own, and that is
                        // the shape that broke the dashboard tile.**
                        //
                        // `TaxonomyPropertyRowView` puts `.textSelection(.enabled)`
                        // on the whole row, and selectable text installs
                        // recognisers. Inside `TileCard`'s `Button` the equivalent
                        // — `.chartXSelection` — did not merely swallow the tap
                        // over its own area: one touch left that button unable to
                        // perform its action again, anywhere in its bounds, for
                        // the life of the screen, with nothing rendered, nothing
                        // logged and byte-identical screenshots either side of it.
                        //
                        // So this is **not** left to reasoning. Measured on
                        // iPhone 17, demo build, via
                        // `NestedGestureTapTests.testTaxonomyPropertyRowOpensOnFirstTap`:
                        // a tap at the row's centre — over the selectable text
                        // rather than beside it, on a 370×91.7pt row — pushed
                        // `$insert_id` on the *first* touch. Selection here
                        // neither swallows the tap nor latches the button, so no
                        // `.allowsHitTesting(false)` is warranted and the ability
                        // to copy a property key out of the row is kept.
                        //
                        // The test taps once per launch and asserts from that tap
                        // alone. A probe that taps twice and concludes from the
                        // second reading exonerates a latch, which is how the
                        // tile's cause was missed eight times over.
                        TaxonomyPropertyRowView(
                            sample: property,
                            definition: store.definitions[property.property],
                            isNavigable: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            SectionLabel(
                text: store.isEmpty ? "Properties" : "\(store.properties.count) properties",
                systemImage: "tag"
            )
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

// MARK: - Navigation payload

/// What a property row pushes.
///
/// A pair rather than a definition, because the two lists this screen joins do
/// not cover the same keys: `EventTaxonomyQuery` samples properties off the
/// events themselves and reports keys with no registered definition, so a
/// destination keyed on `PropertyDefinitionSummary` could not open them. The
/// event travels too, so the detail can narrow its distribution to the event the
/// reader was already looking at rather than silently widening to the project.
struct TaxonomyPropertyTarget: Hashable {
    let key: String
    let definition: PropertyDefinitionSummary?
    let event: String?
}

// MARK: - Rows

struct TaxonomyPropertyRowView: View {
    let sample: TaxonomyPropertySample
    let definition: PropertyDefinitionSummary?
    /// Draws the chevron. Off by default so the row can still be used in a
    /// context that does not push — a chevron on a row that does nothing is the
    /// one piece of furniture a reader is entitled to trust.
    var isNavigable = false

    var body: some View {
        DataRow(
            glyph: "tag",
            title: sample.property,
            subtitle: sample.sampleValues.joined(separator: " · "),
            footnote: detailLine,
            // Sample values are raw data as it was sent, so they keep the
            // monospacing that makes two near-identical values comparable.
            isSubtitleMonospaced: true,
            accessory: curationAccessory
        )
        // Kept selectable so a property key or a sample value can be copied
        // straight into a filter.
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Verified and hidden are mutually exclusive in PostHog, so this reads as
    /// one state rather than two flags.
    ///
    /// The pill wins over the chevron when there is one: a curation state is
    /// information and a chevron is furniture, and `RowAccessory` holds one
    /// trailing slot. Losing the chevron on a curated row is the cheaper loss —
    /// the row is still a `Button` and still opens.
    private var curationAccessory: RowAccessory {
        if definition?.isHidden == true { return .pill("Hidden", .secondary) }
        if definition?.isVerified == true { return .pill("Verified", Theme.Status.good) }
        return isNavigable ? .chevron : .none
    }

    private var detailLine: String {
        guard let type = definition?.propertyType else { return sample.sampleSummary }
        return "\(type) · \(sample.sampleSummary)"
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
