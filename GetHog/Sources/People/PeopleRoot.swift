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

    private let pageSize = 50

    func loadPersons(client: PostHogClient, projectID: Int, search: String?) async {
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
    func resetForProjectChange() {
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
            Picker("View", selection: $segment) {
                ForEach(PeopleStore.Segment.allCases) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            content
        }
        .navigationTitle("People")
        .toolbar { ProjectSwitcher() }
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
            store.resetForProjectChange()
            if segment == .cohorts { await loadCohorts() }
        }
        .onChange(of: segment) { _, new in
            if new == .cohorts { Task { await loadCohorts() } }
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
            ContentUnavailableView {
                Label("Couldn't load persons", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await loadPersons() } }
            }
        } else if store.persons.isEmpty && !store.isLoadingPersons {
            ContentUnavailableView(
                search.isEmpty ? "No persons" : "No matches",
                systemImage: "person.slash",
                description: Text(
                    search.isEmpty
                        ? "This project hasn't identified anyone yet."
                        : "No person matched “\(search)”."
                )
            )
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(store.persons, id: \.self) { person in
                        NavigationLink(value: person) { PersonRowView(person: person) }
                    }
                } footer: {
                    personsFooter
                }
            }
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
            ContentUnavailableView {
                Label("Couldn't load cohorts", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await loadCohorts(force: true) } }
            }
        } else if filteredCohorts.isEmpty && !store.isLoadingCohorts {
            ContentUnavailableView(
                search.isEmpty ? "No cohorts" : "No matches",
                systemImage: "person.3",
                description: Text(
                    search.isEmpty
                        ? "This project doesn't define any cohorts yet."
                        : "No cohort matched “\(search)”."
                )
            )
        } else {
            List {
                Section {
                    ForEach(filteredCohorts) { CohortRowView(cohort: $0) }
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
        HStack(spacing: 12) {
            PersonAvatar(initials: person.initials)

            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusPill(
                        text: person.isIdentified ? "Identified" : "Anonymous",
                        tint: person.isIdentified ? Theme.accent : .secondary
                    )
                    Text(distinctIDSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let created = person.createdAt {
                    Text("First seen \(created, format: .dateTime.year().month().day())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var distinctIDSummary: String {
        let count = person.distinctIDs.count
        return count == 1 ? "1 distinct ID" : "\(count) distinct IDs"
    }
}

struct CohortRowView: View {
    let cohort: Cohort

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cohort.name)
                .font(.body)
                .lineLimit(2)

            if let description = cohort.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                StatusPill(
                    text: cohort.isStatic ? "Static" : "Dynamic",
                    tint: cohort.isStatic ? .secondary : Theme.accent
                )
                if let count = cohort.count {
                    Text("\(Double(count).compactFormatted) people")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Count not calculated")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
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
