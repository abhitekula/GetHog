import GetHogKit
import SwiftUI

@MainActor
@Observable
final class PeopleStore {

    enum Segment: String, CaseIterable, Identifiable {
        case persons, cohorts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .persons: "Persons"
            case .cohorts: "Cohorts"
            }
        }
    }

    var persons: [PersonSummary] = []
    /// Total matches server-side, which is almost never the number of rows on
    /// screen — saying "50" when there are 40,000 would be a lie.
    var personsTotal: Int?
    var personsError: String?
    var isLoadingPersons = false
    var personsLoadedAt: Date?

    var cohorts: [Cohort] = []
    var cohortsError: String?
    var isLoadingCohorts = false
    var cohortsLoadedAt: Date?

    /// Cohorts are fetched the first time that segment is actually shown. The
    /// rate-limit budget is organisation-wide, so a segment the user never
    /// opens must not cost a request on every project switch.
    private var hasLoadedCohorts = false

    /// Stale data is discarded here rather than from a separate `.task`, so the
    /// reset can never land *after* a concurrent load has already populated the
    /// list. Two tasks racing over the same state is a bug waiting for a slow
    /// network to expose it.
    private var loadedProjectID: Int?

    private let pageSize = 50

    func loadPersons(client: PostHogClient, projectID: Int, search: String?) async {
        discardIfProjectChanged(to: projectID)
        isLoadingPersons = true
        defer { isLoadingPersons = false }
        do {
            let page: Page<PersonSummary> = try await client.send(
                PostHogAPI.persons(projectID: projectID, limit: pageSize, search: search)
            )
            persons = page.results
            personsTotal = page.count
            personsLoadedAt = Date()
            personsError = nil
        } catch {
            personsError = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    func loadCohorts(client: PostHogClient, projectID: Int, force: Bool = false) async {
        discardIfProjectChanged(to: projectID)
        guard force || !hasLoadedCohorts else { return }
        isLoadingCohorts = true
        defer { isLoadingCohorts = false }
        do {
            let page: Page<Cohort> = try await client.send(
                PostHogAPI.cohorts(projectID: projectID)
            )
            // Deleted cohorts stay in the API response; they are not a thing the
            // user can act on, so they never reach the list.
            cohorts = page.results.filter { !$0.deleted }
            cohortsLoadedAt = Date()
            cohortsError = nil
            hasLoadedCohorts = true
        } catch {
            cohortsError = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// A different project means different people; nothing carries over.
    private func discardIfProjectChanged(to projectID: Int) {
        guard loadedProjectID != projectID else { return }
        loadedProjectID = projectID
        persons = []
        personsTotal = nil
        personsError = nil
        personsLoadedAt = nil
        cohorts = []
        cohortsError = nil
        cohortsLoadedAt = nil
        hasLoadedCohorts = false
    }
}

struct PeopleRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store = PeopleStore()
    @State private var segment: PeopleStore.Segment = .persons
    @State private var search = ""
    @State private var selection: PersonSummary?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selection {
                PersonDetailView(person: selection)
                    .id(selection.id)
            } else {
                ContentUnavailableView(
                    "Select a person",
                    systemImage: "person.crop.circle",
                    description: Text("Pick a person to see their properties and recent events.")
                )
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            GlassFilterBar {
                adaptivelyStyled(
                    Picker("View", selection: $segment) {
                        ForEach(PeopleStore.Segment.allCases) { segment in
                            Text(segment.title).tag(segment)
                        }
                    }
                )
            }
            .padding(.vertical, Theme.Space.s)

            content
        }
        // The list below paints its own ground; this covers the strip the
        // filter bar sits on, which would otherwise stay system grey and leave
        // the warm glass floating on the wrong surface.
        .background(Theme.pageBackground)
        .navigationTitle("People")
        .toolbar { ProjectSwitcher() }
        .projectSubtitle()
        .searchable(
            text: $search,
            prompt: segment == .persons ? "Search persons" : "Filter cohorts"
        )
        .refreshable { await refresh() }
        // One task covers project switches and typing. Persons search is
        // server-side, so a burst of keystrokes is debounced into one request
        // rather than one request per character.
        .task(id: "\(model.projectID ?? 0)|\(search)") {
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            await loadPersons()
        }
        .task(id: model.projectID) {
            if segment == .cohorts { await loadCohorts() }
        }
        .onChange(of: segment) { _, new in
            if new == .cohorts { Task { await loadCohorts() } }
        }
    }

    /// Segmented controls shrink their labels to slivers at accessibility text
    /// sizes, so past that threshold the same choice becomes a menu.
    @ViewBuilder
    private func adaptivelyStyled(_ picker: some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else {
            switch segment {
            case .persons: personsContent
            case .cohorts: cohortsContent
            }
        }
    }

    // MARK: - Persons

    @ViewBuilder
    private var personsContent: some View {
        if let error = store.personsError, store.persons.isEmpty {
            EmptyStateView(
                title: "Couldn't load persons",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await loadPersons() }
            }
        } else if store.persons.isEmpty && !store.isLoadingPersons {
            EmptyStateView(
                title: search.isEmpty ? "No persons" : "No matches",
                systemImage: "person.slash",
                message: search.isEmpty
                    ? "This project hasn't identified anyone yet."
                    : "No person matched “\(search)”."
            )
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(store.persons, id: \.self) { person in
                        NavigationLink(value: person) { PersonRowView(person: person) }
                            .listRowBackground(
                                Theme.cardBackground
                                    .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                    .padding(.vertical, 1)
                            )
                            .listRowSeparator(.hidden)
                    }
                } footer: {
                    personsFooter
                }
            }
            .listRowSpacing(Theme.Space.xs)
            .pageSurface()
            .skeleton(store.isLoadingPersons && store.persons.isEmpty)
        }
    }

    @ViewBuilder
    private var personsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let total = store.personsTotal, total > store.persons.count {
                Text("Showing \(store.persons.count) of \(total). Narrow the search to find someone specific.")
            }
            FreshnessLabel(date: store.personsLoadedAt)
        }
    }

    // MARK: - Cohorts

    @ViewBuilder
    private var cohortsContent: some View {
        if let error = store.cohortsError, store.cohorts.isEmpty {
            EmptyStateView(
                title: "Couldn't load cohorts",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await loadCohorts(force: true) }
            }
        } else if filteredCohorts.isEmpty && !store.isLoadingCohorts {
            EmptyStateView(
                title: search.isEmpty ? "No cohorts" : "No matches",
                systemImage: "person.3",
                message: search.isEmpty
                    ? "This project doesn't define any cohorts yet."
                    : "No cohort matched “\(search)”."
            )
        } else {
            List {
                Section {
                    ForEach(filteredCohorts) { cohort in
                        CohortRowView(cohort: cohort)
                            .listRowBackground(
                                Theme.cardBackground
                                    .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                    .padding(.vertical, 1)
                            )
                            .listRowSeparator(.hidden)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        // The static/dynamic split is the thing that decides how
                        // to read a count, so it is stated rather than implied by
                        // a pill the reader has to decode.
                        Text("A static cohort is a snapshot: its members were fixed when it was created or last calculated, so its count only moves when someone recalculates it. A dynamic cohort re-evaluates its rules, so people join and leave on their own and the count moves with them.")
                        FreshnessLabel(date: store.cohortsLoadedAt)
                    }
                }
            }
            .listRowSpacing(Theme.Space.xs)
            .pageSurface()
            .skeleton(store.isLoadingCohorts && store.cohorts.isEmpty)
        }
    }

    private var filteredCohorts: [Cohort] {
        // Cohorts arrive in one page, so filtering locally costs nothing and
        // avoids a request per keystroke.
        guard !search.isEmpty else { return store.cohorts }
        return store.cohorts.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.description?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    // MARK: - Loading

    private func loadPersons() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadPersons(
            client: client, projectID: projectID, search: search.isEmpty ? nil : search
        )
    }

    private func loadCohorts(force: Bool = false) async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadCohorts(client: client, projectID: projectID, force: force)
    }

    private func refresh() async {
        switch segment {
        case .persons: await loadPersons()
        case .cohorts: await loadCohorts(force: true)
        }
    }
}

// MARK: - Rows

struct PersonRowView: View {
    let person: PersonSummary

    var body: some View {
        DataRow(
            // Whether PostHog knows who this is changes how the row should be
            // read, so it is the distinction the glyph carries.
            glyph: person.isIdentified ? "person.fill" : "person.fill.questionmark",
            tint: person.isIdentified ? Theme.accent : .secondary,
            title: person.displayName,
            // The distinct ID is the identifier everything else joins on, so it
            // takes the monospaced line — unless it is already the title, which
            // is what `displayName` falls back to for anonymous people.
            subtitle: distinctID,
            footnote: footnote,
            isSubtitleMonospaced: true,
            accessory: .pill(
                person.isIdentified ? "Identified" : "Anonymous",
                person.isIdentified ? Theme.accent : .secondary
            )
        )
    }

    private var distinctID: String? {
        guard let first = person.distinctIDs.first, first != person.displayName else { return nil }
        return first
    }

    private var footnote: String? {
        var parts = [distinctIDSummary]
        if let created = person.createdAt {
            parts.append("First seen \(created.formatted(.dateTime.year().month().day()))")
        }
        return parts.joined(separator: " · ")
    }

    private var distinctIDSummary: String {
        let count = person.distinctIDs.count
        return count == 1 ? "1 distinct ID" : "\(count) distinct IDs"
    }
}

struct CohortRowView: View {
    let cohort: Cohort

    var body: some View {
        DataRow(
            glyph: "person.3.fill",
            // A dynamic cohort re-evaluates itself, so it takes the app accent;
            // a static snapshot recedes. The pill says which in words — the
            // footer below the list explains why the difference matters.
            tint: cohort.isStatic ? .secondary : Theme.accent,
            title: cohort.name,
            subtitle: cohort.description,
            footnote: countText,
            accessory: .pill(
                cohort.isStatic ? "Static" : "Dynamic",
                cohort.isStatic ? .secondary : Theme.accent
            )
        )
    }

    private var countText: String {
        guard let count = cohort.count else { return "Count not calculated" }
        return "\(Double(count).compactFormatted) people"
    }
}

/// Initials bubble. Purely decorative — the name it sits beside carries the
/// meaning, so VoiceOver skips it.
struct PersonAvatar: View {
    let initials: String
    var size: CGFloat = 34
    var font: Font = .caption.weight(.semibold)

    /// Scales with Dynamic Type, otherwise large text overflows a fixed circle.
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1

    var body: some View {
        Text(initials)
            .font(font)
            .foregroundStyle(Theme.accent)
            .frame(width: size * scale, height: size * scale)
            .background(Theme.accent.opacity(0.15), in: .circle)
            .accessibilityHidden(true)
    }
}
