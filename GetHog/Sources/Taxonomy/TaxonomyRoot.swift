import GetHogKit
import GetHogUI
import SwiftUI

/// Which half of the taxonomy is on screen.
///
/// The two are separate lists rather than one merged one because they are
/// separate objects with separate curation state and separate detail: an event
/// definition has a 30-day volume and a property list, a property definition has
/// a type, a value distribution, and the set of events that carry it.
enum TaxonomyScope: String, CaseIterable, Identifiable {
    case events
    case properties

    var id: String { rawValue }

    var title: String {
        switch self {
        case .events: "Events"
        case .properties: "Properties"
        }
    }

    var searchPrompt: String {
        switch self {
        case .events: "Search events"
        case .properties: "Search properties"
        }
    }
}

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

    /// Event *property* definitions, loaded only when that half of the screen is
    /// asked for.
    ///
    /// Not folded into `load`: property definitions are fetched only when their
    /// screen is requested, avoiding unnecessary network work.
    var properties: [PropertyDefinitionSummary] = []
    /// The project's true property total, which is not `properties.count` —
    /// the request is limited and this is the figure the page envelope reported.
    var propertyTotal: Int?
    var propertiesLoading = false
    var propertiesError: LoadFailure?
    var propertiesLoadedAt: Date?

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

    /// Event property definitions, in the order PostHog returns them.
    ///
    /// `type` is left at its documented `event` default. Person, group, and
    /// session properties are separate resources and must not be mislabeled.
    ///
    /// `exclude_hidden` is likewise left off, and that is the load-bearing
    /// choice: it is declared `"default": false`, so hidden definitions **are**
    /// in this list and each row states its own state. Passing `true` would make
    /// them vanish silently, which reads as "this project has no such property".
    func loadProperties(client: PostHogClient, projectID: Int, limit: Int = 500) async {
        propertiesLoading = true
        defer { propertiesLoading = false }
        do {
            let page: Page<PropertyDefinitionSummary> = try await client.send(
                PostHogAPI.propertyDefinitions(projectID: projectID, limit: limit)
            )
            properties = page.results
            propertyTotal = page.count
            propertiesError = nil
            propertiesLoadedAt = Date()
        } catch {
            propertiesError = LoadFailure(error, loading: "property definitions")
        }
    }

    /// How many the project has that this request did not carry. Zero when the
    /// page said nothing about a total, because "unknown" must not read as "none
    /// missing" — the header omits the phrase entirely in that case.
    var undisplayedPropertyCount: Int? {
        guard let propertyTotal else { return nil }
        return max(0, propertyTotal - properties.count)
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

/// Events ranked by volume, alongside their curation state.
///
/// Two totals appear here on purpose. PostHog's taxonomy query counts events
/// received in the **last 30 days**; the event definitions list counts every
/// event name ever ingested. Reporting either as "the number of events" would
/// misstate one of them, so both are labelled for what they are.
struct TaxonomyRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = TaxonomyStore()
    @State private var search = ""

    /// `@SceneStorage`, not `@State`.
    ///
    /// This screen is one of `AppTab.secondary`, so crossing the size-class
    /// boundary swaps its host and discards every `@State` under it — the same
    /// mechanism `OpenDetails` exists for. A reader who had switched to
    /// Properties and rotated an iPad would have been put back on Events with no
    /// action of their own. Scene storage belongs to the window rather than to
    /// the view, so it survives the rebuild without needing a slot in the box.
    @SceneStorage("taxonomy.scope") private var scope: TaxonomyScope = .events

    /// The open event, held in `OpenDetails` rather than pushed as a value onto
    /// the container's path.
    ///
    /// This screen is one of `AppTab.secondary`, so it is hosted by a sidebar
    /// `Tab` above the size-class boundary and by the search stack below it. A
    /// `NavigationLink(value:)` attaches to whichever host stack is active, and
    /// that stack can be replaced across a size-class transition.
    private var selection: Binding<TaxonomyEvent?> {
        Binding(
            get: { openDetails[.taxonomy] as? TaxonomyEvent },
            set: {
                openDetails[.taxonomy] = $0.map(AnyHashable.init)
                // The two lists share one stack, so opening on one side has to
                // close the other: leaving both slots full would register two
                // `navigationDestination(item:)`s with values at once, and which
                // of them wins is not something to leave to SwiftUI.
                if $0 != nil { openDetails[.taxonomy, level: 1] = nil }
            }
        )
    }

    /// The open property — level 1, beside the event at level 0 rather than
    /// beneath it. Both are pushed from the same root list, one per scope.
    private var propertySelection: Binding<PropertyDefinitionSummary?> {
        Binding(
            get: { openDetails[.taxonomy, level: 1] as? PropertyDefinitionSummary },
            set: {
                openDetails[.taxonomy, level: 1] = $0.map(AnyHashable.init)
                if $0 != nil { openDetails[.taxonomy] = nil }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassFilterBar {
                Picker("View", selection: $scope) {
                    ForEach(TaxonomyScope.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .adaptivePickerStyle()
            }
            .padding(.vertical, Theme.Space.s)

            scopedContent
        }
        // The lists below paint their own ground; this covers the strip the
        // filter bar sits on, which would otherwise stay system grey and leave
        // the warm glass floating on the wrong surface.
        .background(Theme.pageBackground)
        .navigationTitle("Taxonomy")
        .toolbar { ProjectSwitcher() }
        .projectSubtitle()
        .searchable(text: $search, prompt: scope.searchPrompt)
        .screenRefreshable { await refresh() }
        .task(id: model.projectID) { await load() }
        // Fires on the first switch to Properties and on a project change while
        // that half is showing. Switching back and forth does not re-request.
        .task(id: "\(model.projectID ?? 0)|\(scope.rawValue)") {
            guard scope == .properties else { return }
            await loadPropertiesIfNeeded()
        }
        .navigationDestination(item: selection) { event in
            TaxonomyEventDetailView(event: event)
        }
        .navigationDestination(item: propertySelection) { definition in
            TaxonomyPropertyDetailView(definition: definition)
        }
    }

    @ViewBuilder
    private var scopedContent: some View {
        switch scope {
        case .events: content
        case .properties: propertiesContent
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

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` turns it back
    /// into a pushed screen. Both halves are needed — a selection with nothing
    /// displaying it leaves a tap that only highlights the row.
    private var list: some View {
        List(selection: selection) {
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
        .accessibilityIdentifier("gethog.taxonomy-events-list")
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
                            // PostHog's own well-known event names — tokens, and
                            // the ones most likely to be broken here are the long
                            // camel-cased ones. `zxx` is the ISO code for "no
                            // linguistic content".
                            .typesettingLanguage(Locale.Language(identifier: "zxx"))
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

    // MARK: - Properties

    @ViewBuilder
    private var propertiesContent: some View {
        if !model.isAvailable(.events) {
            // Approximate for the same reason the events half is: this list
            // wants `property_definition:read`, which no capability models, and
            // `.events` is the nearest probe the app actually runs.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.propertiesError, store.properties.isEmpty {
            LoadFailureState(title: "Couldn't load properties", failure: error) {
                Task { await loadProperties() }
            }
        } else if store.properties.isEmpty && !store.propertiesLoading {
            // Says what the call returned. Not "this project has no properties":
            // this list is the *definitions* endpoint for event properties, and
            // an empty answer from it is not evidence about the events table.
            EmptyStateView(
                title: "No property definitions",
                systemImage: "tag",
                message: "PostHog registered no event properties for this project. Person, group and session properties are listed separately in PostHog and are not in this list."
            )
        } else {
            propertiesList
        }
    }

    private var propertiesList: some View {
        List(selection: propertySelection) {
            Section {
                if filteredProperties.isEmpty {
                    Text("No properties matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredProperties) { definition in
                        NavigationLink(value: definition) {
                            TaxonomyPropertyDefinitionRowView(definition: definition)
                        }
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                SectionLabel(text: propertiesHeader, systemImage: "tag")
            } footer: {
                Text(propertiesFooter)
            }

            if let error = store.propertiesError, !store.properties.isEmpty {
                Label("Part of this list may be stale. \(error.summary)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            FreshnessLabel(date: store.propertiesLoadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.propertiesLoading && store.properties.isEmpty)
    }

    /// Two figures only when they differ, so a complete list is not captioned
    /// "386 of 386" as though something were missing.
    private var propertiesHeader: String {
        guard let total = store.propertyTotal, total > store.properties.count else {
            return "\(store.properties.count) event propert\(store.properties.count == 1 ? "y" : "ies")"
        }
        return "\(store.properties.count) of \(total)"
    }

    private var propertiesFooter: String {
        var text = "Event properties this project has registered, in PostHog's own order. Hidden properties are included and labelled — they are removed from pickers elsewhere in PostHog, not from the data."
        if let missing = store.undisplayedPropertyCount, missing > 0 {
            text += " \(missing.formatted()) more exist than this one request carried."
        }
        return text
    }

    private var filteredProperties: [PropertyDefinitionSummary] {
        guard !search.isEmpty else { return store.properties }
        return store.properties.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.description ?? "").localizedCaseInsensitiveContains(search)
                || ($0.propertyType ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }

    /// Pull-to-refresh reloads only the half on screen. Refreshing both would
    /// cost three requests to update the one list somebody is looking at.
    private func refresh() async {
        switch scope {
        case .events: await load()
        case .properties: await loadProperties()
        }
    }

    private func loadProperties() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadProperties(client: client, projectID: projectID)
    }

    private func loadPropertiesIfNeeded() async {
        guard store.properties.isEmpty, store.propertiesError == nil else { return }
        await loadProperties()
    }
}

// MARK: - Summary

/// The two totals, side by side and separately labelled.
struct TaxonomySummaryCard: View {
    let activeCount: Int
    let definedCount: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                stats

                Text("These count different things: one is what arrived recently, the other is every event name this project has ever registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Side by side normally, one above the other at accessibility sizes.
    ///
    /// At accessibility sizes, each statistic takes its own line so labels and
    /// window text remain readable.
    @ViewBuilder
    private var stats: some View {
        let active = stat(
            value: String(activeCount),
            label: "Active",
            detail: "last 30 days"
        )
        // Absent rather than zero when the definitions call failed: "0 defined"
        // would be a claim the API never made.
        let defined = stat(
            value: definedCount.map(String.init) ?? "—",
            label: "Defined",
            detail: definedCount == nil ? "not loaded" : "all time"
        )

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                active
                defined
            }
        } else {
            HStack(alignment: .top, spacing: 20) {
                active
                defined
            }
        }
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

/// A property definition in the root list.
///
/// Distinct from `TaxonomyPropertyRowView` in the event detail, which pairs a
/// definition with the values that were sampled on one event. Here there is no
/// event and therefore no sample — the row shows what the definition itself
/// declares, and the values are one tap away rather than guessed at.
struct TaxonomyPropertyDefinitionRowView: View {
    let definition: PropertyDefinitionSummary

    var body: some View {
        DataRow(
            glyph: "tag",
            title: definition.name,
            subtitle: definition.description,
            footnote: typeText,
            accessory: curationAccessory
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Verified and hidden are mutually exclusive in PostHog, so this reads as
    /// one state rather than two flags; ordinary properties get no noisy pill.
    private var curationAccessory: RowAccessory {
        if definition.isHidden { return .pill("Hidden", .secondary) }
        if definition.isVerified { return .pill("Verified", Theme.Status.good) }
        return .none
    }

    /// A property the service has not typed says so; "Unknown" would claim more
    /// than the API supplied.
    private var typeText: String {
        guard let type = definition.propertyType else { return "Not typed by PostHog" }
        return definition.isNumerical ? "\(type) · numerical" : type
    }

    private var spokenSummary: String {
        var parts = [definition.name]
        if definition.isVerified { parts.append("verified") }
        if definition.isHidden { parts.append("hidden") }
        if let description = definition.description { parts.append(description) }
        parts.append(typeText)
        return parts.joined(separator: ", ")
    }
}
