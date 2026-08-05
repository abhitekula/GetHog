import GetHogKit
import SwiftUI

/// Narrowing the insight in front of you: one property filter, and one breakdown.
///
/// "Signups dropped" is never the question. "Signups dropped — *for whom*, and
/// split by *what*" is, and until this existed the only answer on a phone was to
/// hand-write HogQL in the SQL tab.
///
/// ## What this costs
///
/// The same shape as the date rerun that already ships, and no more:
///
/// * **One `.query` per Apply.** Nothing runs while the sheet is being edited —
///   no live preview, no re-run on every picker change. `Apply` is the only
///   control that spends anything.
/// * **One `.crud` the first time a property list is opened**, and it is kept for
///   the life of the sheet. `/property_definitions/` is project-wide, so the same
///   list serves the filter and the breakdown.
/// * **One `.query` the first time a property's values are opened.** Also kept.
///   Nothing is fetched for a property the reader never taps.
///
/// A reader who opens the sheet, picks `$browser`, picks `Chrome` and applies
/// spends three requests. One who opens it and closes it again spends none.
///
/// ## Where the vocabulary comes from
///
/// Not a text field. A property name typed by hand is a filter that matches
/// nothing, and an empty chart is indistinguishable from a real absence — the
/// failure this codebase treats as worse than an error. Both lists come from the
/// taxonomy this app already reads:
///
/// * **Names** — `/property_definitions/`, the same endpoint the Taxonomy screen
///   uses, scoped to events / persons / sessions.
/// * **Values** — `EventTaxonomyQuery` with the properties *named*, which is the
///   exact form rather than the sampled one: naming them makes the runner
///   aggregate the whole 30-day window, and `sample_values` comes back ordered by
///   frequency. `PostHogAPI.eventTaxonomy(projectID:event:properties:)` documents
///   the measurement.
///
/// Values are offered for event properties only, and the reason is a measured
/// 500: that query **requires** an `event`, and omitting it — asking for a
/// property across every event — is HTTP 500 rather than an empty result. The
/// event comes from the insight's own first series. Person and session properties
/// therefore get a name list and a free-text value, and the sheet says which it is
/// giving you rather than showing an empty menu.
struct InsightNarrowSheet: View {
    let insight: Insight
    @Binding var filters: [InsightPropertyFilter]
    @Binding var breakdown: InsightBreakdownOverride
    /// Runs the query. Called once, on Apply.
    let onApply: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = InsightVocabularyStore()
    @State private var draftFilters: [InsightPropertyFilter] = []
    @State private var draftBreakdown: InsightBreakdownOverride = .saved
    @State private var isAddingFilter = false

    private var narrowing: InsightNarrowing {
        InsightNarrowing(sourceKind: insight.sourceKind)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let reason = narrowing.unavailableReason {
                    EmptyStateView(
                        title: "Nothing to narrow here",
                        systemImage: "line.3.horizontal.decrease.circle",
                        message: reason
                    )
                } else {
                    form
                }
            }
            .navigationTitle("Narrow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filters = draftFilters
                        breakdown = draftBreakdown
                        onApply()
                        dismiss()
                    }
                    // Nothing to spend a request on. Not disabled when the drafts
                    // are *empty* — clearing every filter is a real change and
                    // costs the same one query to undo.
                    .disabled(draftFilters == filters && draftBreakdown == breakdown)
                }
            }
            .sheet(isPresented: $isAddingFilter) {
                InsightFilterPicker(store: store, eventName: primaryEventName) { filter in
                    // Same key twice is a narrowing that matches nothing for
                    // `exact`, so the newer one replaces the older rather than
                    // both being AND-ed into an empty chart.
                    draftFilters.removeAll { $0.scope == filter.scope && $0.key == filter.key }
                    draftFilters.append(filter)
                }
            }
            .onAppear {
                draftFilters = filters
                draftBreakdown = breakdown
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            if narrowing.supportsPropertyFilters {
                filterSection
            }
            if narrowing.supportsBreakdown {
                breakdownSection
            }
            costSection
        }
        .pageSurface()
    }

    private var filterSection: some View {
        Section {
            ForEach(draftFilters) { filter in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filter.displayText)
                            .font(.subheadline)
                        Text(filter.scope.title.lowercased() + " property")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // A labelled button, not a swipe: this sheet's other controls
                    // are all buttons and a hidden gesture on one row of a form is
                    // the affordance nobody finds.
                    //
                    // The 44pt floor is **inside** the label, like every other one
                    // in this pair of features — measured on the alerts sheet, a
                    // `.frame` outside a styled `Button` recentres the label and
                    // leaves the hit region at the label's intrinsic 29.67pt. See
                    // `InsightAlertsView.controls`.
                    Button {
                        draftFilters.removeAll { $0.id == filter.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Status.criticalInk)
                    .accessibilityLabel("Remove filter \(filter.displayText)")
                }
                .accessibilityElement(children: .combine)
            }

            Button {
                isAddingFilter = true
            } label: {
                Label("Add a filter", systemImage: "plus")
                    .frame(minHeight: 44)
            }
        } header: {
            SectionLabel(text: "Narrow to", systemImage: "line.3.horizontal.decrease.circle")
        } footer: {
            Text(filterFooter)
        }
    }

    /// Says which of two very different things the reader is looking at, because
    /// the wire behaviour differs and nothing on screen would otherwise show it.
    ///
    /// **No markdown.** `Text` parses it only from a *literal*, and this is a
    /// computed `String` — so the first version of this sentence shipped as
    /// "Adding one \*\*replaces\*\* them", asterisks and all, and it took a
    /// screenshot to see it (`build/Screenshots/…/insight-narrow-sheet.png`,
    /// 2026-07-31). The emphasis is carried by word order instead.
    private var filterFooter: String {
        draftFilters.isEmpty
            ? "With nothing here the insight keeps whatever filters it was saved with. Adding one replaces them for this run — filters here are not layered on top of the saved ones."
            : "These replace the insight's saved filters for this run. The insight itself is not changed."
    }

    private var breakdownSection: some View {
        Section {
            Picker("Split by", selection: breakdownSelection) {
                Text("As saved").tag(BreakdownChoice.saved)
                Text("No breakdown").tag(BreakdownChoice.none)
                ForEach(store.properties(for: .event), id: \.self) { property in
                    Text(property).tag(BreakdownChoice.property(property))
                }
            }
            .pickerStyle(.menu)
            .task { await loadProperties(scope: .event) }

            if store.isLoading(.event) {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading this project's property names…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let failure = store.failure(.event) {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.Status.criticalInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            SectionLabel(text: "Split by", systemImage: "chart.bar.doc.horizontal")
        } footer: {
            Text(breakdownFooter)
        }
    }

    /// "As saved" is not "no breakdown", and the distinction is why this is a
    /// three-state choice. An insight designed around a `method` breakdown would
    /// quietly lose it if the two collapsed.
    private var breakdownFooter: String {
        switch draftBreakdown {
        case .saved:
            "Leaves the insight's own breakdown alone. PostHog splits a maximum of three ways; GetHog sets one."
        case .none:
            "Runs the insight as a single undivided series, whatever it was saved with."
        case .property(let value):
            "Splits every series by \(value.property). PostHog groups the long tail into an “Other” bucket rather than drawing all of it."
        }
    }

    private var costSection: some View {
        Section {
            Text("Applying runs the insight once — one query against a rate limit your whole organization shares. Nothing runs while you're editing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Breakdown binding

    /// A `Hashable` stand-in for `InsightBreakdownOverride`, because a SwiftUI
    /// `Picker` tag has to be `Hashable` and `.property` carries a struct the tag
    /// comparison would then have to match on in full.
    private enum BreakdownChoice: Hashable {
        case saved
        case none
        case property(String)
    }

    private var breakdownSelection: Binding<BreakdownChoice> {
        Binding(
            get: {
                switch draftBreakdown {
                case .saved: .saved
                case .none: .none
                case .property(let value): .property(value.property)
                }
            },
            set: { choice in
                switch choice {
                case .saved: draftBreakdown = .saved
                case .none: draftBreakdown = .none
                case .property(let name):
                    draftBreakdown = .property(InsightBreakdown(scope: .event, property: name))
                }
            }
        )
    }

    // MARK: - Vocabulary

    /// The event the insight's first series counts, which is the only event a
    /// value lookup may be made against.
    ///
    /// `nil` for an insight whose first series is an action or a warehouse node
    /// rather than a plain event — and the picker then offers a free-text value
    /// and says so, rather than showing an empty menu that reads as "this property
    /// has no values".
    private var primaryEventName: String? {
        guard case .array(let series)? = insight.rawSource?["series"],
              let first = series.first
        else { return nil }
        return first["event"]?.stringValue
    }

    private func loadProperties(scope: PropertyScope) async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadProperties(client: client, projectID: projectID, scope: scope)
    }
}

// MARK: - Filter picker

/// Choosing one property and one value.
///
/// A screen of its own rather than two inline pickers, because the value list is
/// fetched per property and an inline menu that spins on every selection change
/// is a control that punishes browsing.
private struct InsightFilterPicker: View {
    let store: InsightVocabularyStore
    /// The event a value lookup is made against. `nil` disables the value menu in
    /// favour of a text field — see `InsightNarrowSheet.primaryEventName`.
    let eventName: String?
    let onAdd: (InsightPropertyFilter) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scope: InsightPropertyFilter.Scope = .event
    @State private var key: String = ""
    @State private var value: String = ""
    @State private var isNegated = false
    @State private var search = ""

    private var propertyScope: PropertyScope {
        switch scope {
        case .event: .event
        case .person: .person
        case .session: .session
        }
    }

    private var names: [String] {
        let all = store.properties(for: propertyScope)
        guard !search.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    /// Values are only ever offered where a request could really answer for them:
    /// an event property, on an insight whose first series names an event.
    private var canOfferValues: Bool { scope == .event && eventName != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Property lives on", selection: $scope) {
                        ForEach(InsightPropertyFilter.Scope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: scope) { _, _ in
                        // A key from the previous table is almost never a key in
                        // the next one, and a stale name silently attached to a
                        // new scope is worse than an obvious reset.
                        key = ""
                        value = ""
                        Task { await load() }
                    }

                    Picker("Match", selection: $isNegated) {
                        Text("is").tag(false)
                        Text("is not").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    SectionLabel(text: "Property", systemImage: "tag")
                }

                Section {
                    if store.isLoading(propertyScope) {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Reading property names…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let failure = store.failure(propertyScope) {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.Status.criticalInk)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if names.isEmpty {
                        // A finding about the project, and only ever printed when
                        // the request actually answered. A failure takes the
                        // branch above.
                        Text(
                            search.isEmpty
                                ? "PostHog has no \(scope.title.lowercased()) property definitions for this project."
                                : "No \(scope.title.lowercased()) property matches “\(search)”."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(names.prefix(60), id: \.self) { name in
                            Button {
                                key = name
                                value = ""
                                if canOfferValues { Task { await loadValues(for: name) } }
                            } label: {
                                HStack {
                                    Text(name).font(.subheadline.monospaced())
                                    Spacer(minLength: 0)
                                    if key == name {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                        if names.count > 60 {
                            Text("\(names.count - 60) more — narrow the search to reach them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    SectionLabel(text: "Which property", systemImage: "list.bullet")
                }

                if !key.isEmpty {
                    valueSection
                }
            }
            .searchable(text: $search, prompt: "Search properties")
            .pageSurface()
            .navigationTitle("Add a filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(
                            InsightPropertyFilter(
                                scope: scope, key: key, value: value, isNegated: isNegated
                            )
                        )
                        dismiss()
                    }
                    .disabled(key.isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var valueSection: some View {
        Section {
            if canOfferValues {
                if store.isLoadingValues(key) {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Reading the values PostHog has seen…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let failure = store.valueFailure(key) {
                    // Three absences, three sentences. This one is *the lookup
                    // failed* — which must never be shown as "no values", the
                    // conflation this codebase treats as a defect in its own
                    // right. The field stays usable so a reader who knows the
                    // value is not blocked by a failed convenience.
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.Status.criticalInk)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Value", text: $value)
                } else if let values = store.values(for: key), values.isEmpty {
                    // *PostHog answered and had none.* The lookup is scoped to
                    // one event and 30 days, so a property that exists
                    // project-wide can genuinely have no values on this event.
                    Text("PostHog recorded no values for \(key) on \(eventName ?? "this event") in the last 30 days. Type one if you know it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Value", text: $value)
                } else {
                    ForEach(store.values(for: key) ?? [], id: \.self) { candidate in
                        Button {
                            value = candidate
                        } label: {
                            HStack {
                                Text(candidate).font(.subheadline)
                                Spacer(minLength: 0)
                                if value == candidate {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                TextField("Value", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            SectionLabel(text: "Value", systemImage: "text.cursor")
        } footer: {
            Text(valueFooter)
        }
    }

    private var valueFooter: String {
        if canOfferValues {
            return "The values PostHog saw on \(eventName ?? "this event") over the last 30 days, most frequent first."
        }
        if scope == .event {
            // Named rather than left as a bare text field: the reason there is no
            // list is a property of the *insight*, not of the property.
            return "This insight's first series isn't a plain event, so there's no event to read values from. Type the value exactly as it is stored."
        }
        return "PostHog's value lookup for \(scope.title.lowercased()) properties needs an event to read against, which a \(scope.title.lowercased()) property doesn't have. Type the value exactly as it is stored."
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadProperties(client: client, projectID: projectID, scope: propertyScope)
    }

    private func loadValues(for property: String) async {
        guard let client = model.client,
              let projectID = model.projectID,
              let eventName
        else { return }
        await store.loadValues(
            client: client, projectID: projectID, event: eventName, property: property
        )
    }
}

// MARK: - Store

/// Property names and values, fetched once each and kept for the sheet's life.
///
/// The caching is the point, not an optimisation. Without it, every re-render of
/// a picker would re-issue a `/property_definitions/` request, and this app's
/// budget is organization-wide and shared with the user's production
/// integrations. Each scope costs **one** `.crud`; each property whose values are
/// opened costs **one** `.query`; neither is paid twice.
@MainActor
@Observable
final class InsightVocabularyStore {

    private var names: [String: [String]] = [:]
    private var loadingScopes: Set<String> = []
    private var failures: [String: String] = [:]
    /// Present only once a lookup **succeeded**. An entry here is a claim that
    /// PostHog answered, so an empty array means "PostHog has seen none" — a
    /// finding — and a missing entry means nothing has been established.
    private var valuesByProperty: [String: [String]] = [:]
    private var loadingValues: Set<String> = []
    private var valueFailures: [String: String] = [:]

    private func key(_ scope: PropertyScope) -> String {
        switch scope {
        case .event: "event"
        case .person: "person"
        case .session: "session"
        case .group(let index): "group\(index)"
        }
    }

    func properties(for scope: PropertyScope) -> [String] { names[key(scope)] ?? [] }
    func isLoading(_ scope: PropertyScope) -> Bool { loadingScopes.contains(key(scope)) }
    func failure(_ scope: PropertyScope) -> String? { failures[key(scope)] }

    /// `nil` until a lookup has answered. Distinct from `[]`, which is PostHog
    /// saying it has seen none — the two are different sentences on screen.
    func values(for property: String) -> [String]? { valuesByProperty[property] }
    func isLoadingValues(_ property: String) -> Bool { loadingValues.contains(property) }
    func valueFailure(_ property: String) -> String? { valueFailures[property] }

    func loadProperties(client: PostHogClient, projectID: Int, scope: PropertyScope) async {
        let cacheKey = key(scope)
        guard names[cacheKey] == nil, !loadingScopes.contains(cacheKey) else { return }
        loadingScopes.insert(cacheKey)
        defer { loadingScopes.remove(cacheKey) }

        do {
            let page: Page<PropertyDefinitionSummary> = try await client.send(
                PostHogAPI.propertyDefinitions(projectID: projectID, scope: scope)
            )
            // Hidden definitions are hidden because somebody on the team decided
            // they were noise; offering them here would undo that decision on a
            // screen with less room than the one it was made on.
            names[cacheKey] = page.results
                .filter { !$0.isHidden }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            failures[cacheKey] = nil
        } catch {
            // Kept as the server's own sentence. `/property_definitions/` is one
            // of the endpoints that can answer a scope wall, and inventing a cause
            // for it is the failure this codebase names most often.
            failures[cacheKey] = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// The values PostHog has seen for one property on one event.
    ///
    /// Uses the **named-properties** form of `EventTaxonomyQuery`, which is exact
    /// over the whole 30-day window rather than a sample of the most recent
    /// hundred events — see `PostHogAPI.eventTaxonomy(projectID:event:properties:)`
    /// for the measurement that established the difference. The response rows are
    /// positional and carry no `property` key, which is why the zip is done by
    /// index through the kit's own helper rather than by name here.
    func loadValues(client: PostHogClient, projectID: Int, event: String, property: String) async {
        guard valuesByProperty[property] == nil, !loadingValues.contains(property) else { return }
        loadingValues.insert(property)
        defer { loadingValues.remove(property) }

        do {
            let page: Page<TaxonomyPropertySample> = try await client.send(
                PostHogAPI.eventTaxonomy(
                    projectID: projectID, event: event, properties: [property]
                )
            )
            // Zipped by index, never by name. The named form drops the `property`
            // key from every row — the rows are positional and parallel to the
            // request array — so matching on `sample.property` would find nothing
            // and report a property with values as having none.
            let samples = TaxonomyPropertySample.zip([property], with: page.results)
            valuesByProperty[property] = samples.first?.sampleValues ?? []
            valueFailures[property] = nil
        } catch {
            // Deliberately leaves `valuesByProperty` **unset**. An empty array
            // here would reach the picker's empty branch, which says PostHog
            // recorded no values for this property — a finding, asserted from a
            // request that measured nothing. The failure is stated instead.
            valueFailures[property] = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}
