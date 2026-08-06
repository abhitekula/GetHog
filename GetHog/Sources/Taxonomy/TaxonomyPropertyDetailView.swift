import GetHogKit
import GetHogUI
import SwiftUI

/// Thirty days, matching `TeamTaxonomyQuery`'s own fixed window and the Groups
/// screen's. Two screens quoting different windows for the same project is a
/// disagreement a reader has no way to spot.
private let taxonomyWindow: TimeInterval = 30 * 24 * 60 * 60

@MainActor
@Observable
final class PropertyDetailStore {
    var values: [PropertyValueShare] = []
    var carriers: [PropertyCarrierEvent] = []
    /// Actor-side values, for a property that lives on a person or a group and
    /// therefore has no event-table distribution at all.
    var actorSample: TaxonomyPropertySample?

    var valuesError: LoadFailure?
    var carriersError: LoadFailure?

    var isLoading = false
    var loadedAt: Date?
    var hasLoaded = false

    /// Two requests for an event property, one for a person or group property.
    ///
    /// The single-request case is not a saving, it is the honest shape: "which
    /// events carry this" is a question about the events table, and a person
    /// property is not on it.
    func load(
        client: PostHogClient,
        projectID: Int,
        property: String,
        scope: PropertyScope,
        event: String?
    ) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let since = Date().addingTimeInterval(-taxonomyWindow)

        guard scope.hasEventDistribution else {
            await loadActorSample(client: client, projectID: projectID, property: property, scope: scope)
            loadedAt = Date()
            return
        }

        async let valuesTask = Self.fetch {
            try await client.send(
                PostHogAPI.propertyValueDistribution(
                    projectID: projectID,
                    property: property,
                    event: event,
                    since: since
                )
            ) as QueryResponse
        }

        async let carriersTask = Self.fetch {
            try await client.send(
                PostHogAPI.propertyCarrierEvents(
                    projectID: projectID,
                    property: property,
                    since: since
                )
            ) as QueryResponse
        }

        switch await valuesTask {
        case .success(let response):
            values = response.rows.compactMap(PropertyValueShare.init(row:))
            valuesError = nil
        case .failure(let error):
            valuesError = LoadFailure(error, loading: "this property's values")
        }

        switch await carriersTask {
        case .success(let response):
            carriers = response.rows.compactMap(PropertyCarrierEvent.init(row:))
            carriersError = nil
        case .failure(let error):
            carriersError = LoadFailure(error, loading: "the events carrying this property")
        }

        loadedAt = Date()
    }

    /// A person or group property, read from the actor table.
    ///
    /// Values with no counts: `ActorsPropertyTaxonomyQuery` reports a distinct
    /// count and a ranked list and no frequency at all, so nothing here may be
    /// drawn as a share. The view says so rather than reusing the bars.
    private func loadActorSample(
        client: PostHogClient,
        projectID: Int,
        property: String,
        scope: PropertyScope
    ) async {
        var groupTypeIndex: Int?
        if case .group(let index) = scope { groupTypeIndex = index }

        do {
            let page: Page<TaxonomyPropertySample> = try await client.send(
                PostHogAPI.actorsPropertyTaxonomy(
                    projectID: projectID,
                    properties: [property],
                    groupTypeIndex: groupTypeIndex
                )
            )
            // The response drops the `property` key when the request named its
            // properties, so the row has to be paired back to the key by index.
            actorSample = TaxonomyPropertySample.zip([property], with: page.results).first
            valuesError = nil
        } catch {
            valuesError = LoadFailure(error, loading: "this property's values")
        }
    }

    /// `nonisolated` so the two `async let`s overlap rather than queueing behind
    /// the main actor, and a `Result` so a failure in one does not cancel the
    /// other — the distribution and the carrier list are separate answers and
    /// either is worth showing without the other.
    nonisolated private static func fetch<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}

/// One property: what it is declared to be, what it actually contains, and
/// which events carry it.
///
/// A definitions list can say `$browser` exists and is a String. It cannot say
/// that in this project it takes eight values, that 88% of them are Chrome, or
/// that it rides on forty different event names — and those are the three things
/// somebody opens a taxonomy screen to find out.
struct TaxonomyPropertyDetailView: View {
    /// The property key, which is the one thing every route here has.
    let key: String
    /// The registered definition, when there is one.
    ///
    /// `nil` is a real and distinct state, not a missing fetch: the event
    /// taxonomy samples a property straight off the events and will report keys
    /// the project has never registered a definition for. The screen says which
    /// it is looking at rather than drawing a blank type row.
    var definition: PropertyDefinitionSummary?
    var scope: PropertyScope = .event
    /// Set when the property was opened from inside an event, so the value
    /// distribution can be narrowed to that event. `nil` asks project-wide.
    var event: String?

    init(
        key: String,
        definition: PropertyDefinitionSummary? = nil,
        scope: PropertyScope = .event,
        event: String? = nil
    ) {
        self.key = key
        self.definition = definition
        self.scope = scope
        self.event = event
    }

    /// The common case: a row in the root's property list, where the definition
    /// is what was tapped and its name is the key.
    init(definition: PropertyDefinitionSummary, scope: PropertyScope = .event, event: String? = nil) {
        self.init(key: definition.name, definition: definition, scope: scope, event: event)
    }

    @Environment(AppModel.self) private var model
    @State private var store = PropertyDetailStore()

    var body: some View {
        List {
            definitionSection

            if scope.hasEventDistribution {
                valuesSection
                carriersSection
            } else {
                actorValuesSection
            }

            if let url = model.webURL(path: "data-management/properties") {
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
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: "\(key)|\(event ?? "")") { await load() }
    }

    // MARK: - Definition

    private var definitionSection: some View {
        Section {
            LabeledContent("Key") {
                Text(key)
                    .font(.caption.monospaced())
                    // A property key, not prose — the same idiom this file
                    // already applies to its value rows further down. `zxx` is
                    // the ISO code for "no linguistic content".
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))
                    .textSelection(.enabled)
            }
            if let description = definition?.description {
                Text(description).font(.callout)
            }
            LabeledContent("Type") {
                // Absent rather than "Unknown". PostHog types a property when it
                // has seen enough of it; a null here is the API declining to
                // say, not a property of type unknown. Measured: 57 of this
                // project's 386 definitions come back untyped.
                Text(definition?.propertyType ?? "Not typed by PostHog")
                    .foregroundStyle(definition?.propertyType == nil ? .secondary : .primary)
            }
            LabeledContent("State") { Text(stateText) }
            if definition == nil {
                // The third state, and the one worth naming. This is not a
                // failed request and not an empty project — the key was seen on
                // events and has no registered definition, so there is nothing
                // to be verified or hidden and no description to show.
                Label(
                    "This project has no registered definition for this key, so it has no description, type or curation state. The counts below are read from the events themselves.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if definition?.isHidden == true {
                // The one curation state that changes what the rest of PostHog
                // does, so it is spelled out rather than left as a pill.
                Label(
                    "Hidden properties are removed from filter and breakdown pickers across PostHog. Data already ingested is unaffected and is what the sections below count.",
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let tags = definition?.tags, !tags.isEmpty {
                LabeledContent("Tags") { Text(tags.joined(separator: ", ")) }
            }
            LabeledContent("Scope") { Text(scopeText) }
        } header: {
            SectionLabel(text: "Definition", systemImage: "tag", productMark: .event)
        }
    }

    /// Verified and hidden are mutually exclusive in PostHog, so this reads as
    /// one state rather than two flags. An unregistered key is a third state and
    /// is not folded into "not verified", which would imply a definition exists.
    private var stateText: String {
        guard let definition else { return "Not defined" }
        if definition.isHidden { return "Hidden" }
        if definition.isVerified { return "Verified" }
        return "Not verified"
    }

    private var scopeText: String {
        switch scope {
        case .event: "Event property"
        case .person: "Person property"
        case .group(let index): "Group property (type index \(index))"
        case .session: "Session property"
        }
    }

    // MARK: - Values

    @ViewBuilder
    private var valuesSection: some View {
        Section {
            if let error = store.valuesError {
                SectionFailure(failure: error) { Task { await load() } }
            } else if !store.hasLoaded {
                ForEach(0..<4, id: \.self) { index in
                    PropertyValueRow(share: Self.placeholderValue(index))
                }
                .skeleton(true)
            } else if store.values.isEmpty {
                // Three different states meet here and only one of them is this
                // one. A failure took the branch above; a property PostHog has
                // not typed still gets counted; this is specifically "the events
                // table holds no value for this key in the window".
                Text("No values were recorded for this property in the last 30 days.\(event.map { " Narrowed to “\($0)”." } ?? "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.values) { share in
                    PropertyValueRow(share: share)
                }

                let hidden = PropertyValueShare.hiddenValueCount(store.values)
                if hidden > 0 {
                    Text("\(hidden.formatted()) more distinct value\(hidden == 1 ? "" : "s") not shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(text: valuesHeader, systemImage: "chart.bar")
        } footer: {
            Text(valuesFooter)
        }
    }

    private var valuesHeader: String {
        guard let first = store.values.first else { return "Values" }
        return "\(first.distinctValues.formatted()) distinct value\(first.distinctValues == 1 ? "" : "s")"
    }

    private var valuesFooter: String {
        let subject = event.map { "on “\($0)”" } ?? "across every event"
        guard let total = store.values.first?.totalOccurrences else {
            return "Counted over the last 30 days, \(subject)."
        }
        // The denominator is named, because a percentage whose base is unstated
        // is the number this screen is most likely to be misread on.
        return "Counted over the last 30 days, \(subject). Percentages are of the \(total.formatted()) events that carried this property, not of all events."
    }

    // MARK: - Actor values

    /// Person and group properties: ranked values, and an explicit refusal to
    /// draw them as a distribution.
    @ViewBuilder
    private var actorValuesSection: some View {
        Section {
            if let error = store.valuesError {
                SectionFailure(failure: error) { Task { await load() } }
            } else if !store.hasLoaded {
                Text("Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .skeleton(true)
            } else if let sample = store.actorSample, !sample.sampleValues.isEmpty {
                ForEach(Array(sample.sampleValues.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.subheadline.monospaced())
                        // Recorded property values — URLs, ids, device strings.
                        // Same idiom as the key above and the rows below.
                        .typesettingLanguage(Locale.Language(identifier: "zxx"))
                        .textSelection(.enabled)
                }
            } else {
                Text("No values are recorded for this property.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionLabel(text: actorValuesHeader, systemImage: "list.bullet")
        } footer: {
            // Says plainly what is missing rather than showing empty bars.
            Text("Person and group properties live on the actor row, not on events, so there is no per-event frequency to divide by. PostHog returns these values ranked and without counts, and this screen shows exactly that.")
        }
    }

    private var actorValuesHeader: String {
        guard let sample = store.actorSample else { return "Values" }
        return "\(sample.sampleCount.formatted()) distinct value\(sample.sampleCount == 1 ? "" : "s")"
    }

    // MARK: - Carriers

    @ViewBuilder
    private var carriersSection: some View {
        Section {
            if let error = store.carriersError {
                SectionFailure(failure: error) { Task { await load() } }
            } else if !store.hasLoaded {
                ForEach(0..<3, id: \.self) { index in
                    PropertyCarrierRow(carrier: Self.placeholderCarrier(index))
                }
                .skeleton(true)
            } else if store.carriers.isEmpty {
                Text("No event carried this property in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.carriers) { carrier in
                    PropertyCarrierRow(carrier: carrier)
                }

                let hidden = PropertyCarrierEvent.hiddenEventCount(store.carriers)
                if hidden > 0 {
                    Text("\(hidden.formatted()) more event name\(hidden == 1 ? "" : "s") not shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(text: carriersHeader, systemImage: "bolt")
        } footer: {
            // The per-event distinct count is the number worth the section: a
            // property definition is project-wide and says nothing about how
            // varied the key is on any one event.
            Text("A property definition is project-wide. This is where it is actually sent, and how many distinct values it takes on each — always project-wide, never narrowed by the event above.")
        }
    }

    private var carriersHeader: String {
        guard let first = store.carriers.first else { return "Events carrying it" }
        return "\(first.distinctEvents.formatted()) event\(first.distinctEvents == 1 ? "" : "s") carry it"
    }

    // MARK: - Plumbing

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(
            client: client,
            projectID: projectID,
            property: key,
            scope: scope,
            event: event
        )
    }

    private static func placeholderValue(_ index: Int) -> PropertyValueShare {
        PropertyValueShare(row: QueryRow(
            columns: ["value", "occurrences", "total_occurrences", "distinct_values"],
            values: [
                .string("placeholder value"),
                .number(Double(200 - index * 40)),
                .number(600),
                .number(8),
            ]
        ))!
    }

    private static func placeholderCarrier(_ index: Int) -> PropertyCarrierEvent {
        PropertyCarrierEvent(row: QueryRow(
            columns: ["event", "occurrences", "distinct_values", "total_occurrences", "distinct_events"],
            values: [
                .string("$placeholder_event"),
                .number(Double(150 - index * 40)),
                .number(4),
                .number(600),
                .number(9),
            ]
        ))!
    }
}

// MARK: - Rows

struct PropertyValueRow: View {
    let share: PropertyValueShare

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            header

            if let fraction = share.share {
                ShareBar(fraction: fraction)
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Space.xs)
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    /// A JSON null is not the string "null", and a reader filtering on this
    /// value needs to know which one they are looking at.
    private var label: String { share.value ?? "(no value)" }

    @ViewBuilder
    private var header: some View {
        let name = Text(label)
            .font(.subheadline.monospaced())
            .foregroundStyle(share.value == nil ? .secondary : .primary)
            .lineLimit(2)
            .truncationMode(.middle)
        let count = Text(Double(share.occurrences).compactFormatted)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                name
                count
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                name
                Spacer(minLength: Theme.Space.s)
                count
            }
        }
    }

    private var footnote: String {
        guard let fraction = share.share else { return "\(share.occurrences.formatted()) events" }
        return "\(ShareFormat.text(fraction)) · \(share.occurrences.formatted()) events"
    }

    private var spokenValue: String {
        guard let fraction = share.share else { return "\(share.occurrences.formatted()) events" }
        return "\(share.occurrences.formatted()) events, \(ShareFormat.spoken(fraction)) of this property"
    }
}

struct PropertyCarrierRow: View {
    let carrier: PropertyCarrierEvent

    var body: some View {
        DataRow(
            glyph: "bolt",
            title: carrier.event,
            subtitle: "\(carrier.distinctValues.formatted()) distinct value\(carrier.distinctValues == 1 ? "" : "s") on this event",
            footnote: footnote,
            accessory: .metric(Double(carrier.occurrences).compactFormatted)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var footnote: String {
        guard let fraction = carrier.share else { return "\(carrier.occurrences.formatted()) events" }
        return "\(ShareFormat.text(fraction)) of this property's events"
    }

    private var spokenSummary: String {
        "\(carrier.event), \(carrier.occurrences.formatted()) events, \(carrier.distinctValues.formatted()) distinct values on this event, \(footnote)"
    }
}
