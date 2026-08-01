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
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Environment(OpenDetails.self) private var openDetails

    @State private var store = PeopleStore()
    @State private var segment: PeopleStore.Segment = .persons
    @State private var search = ""

    /// The open person, and deliberately **not** `@State`.
    ///
    /// This screen is one of the 27 reached through the search tab, so it is
    /// hosted by a sidebar `Tab` above the size-class boundary and by the search
    /// stack below it — see `OpenDetails`. Crossing the boundary rebuilds the
    /// screen in the other host, which threw `@State` away: measured at
    /// 834→375→834pt on iPad Pro 11 M5 with a person open, `navigationBars` went
    /// `["sample.user@example.org", "People"]` → `["People"]` → an *unnamed*
    /// detail, against Dashboards — a primary tab, one host at both widths —
    /// holding `["My App Dashboard", "Dashboards"]` across the identical drag.
    private var selection: Binding<PersonSummary?> {
        Binding(
            get: { openDetails[.people] as? PersonSummary },
            // Setting one clears the other. Both selections drive a
            // `navigationDestination(item:)` on the same view, so two non-nil
            // values would ask the stack for two pushes at once; and in the
            // detail column they would ask for two different screens in one
            // slot. The segments are mutually exclusive on screen, so making
            // the selections mutually exclusive costs the user nothing.
            set: {
                openDetails[.people] = $0.map(AnyHashable.init)
                if $0 != nil { openDetails[.people, level: 1] = nil }
            }
        )
    }

    /// The open cohort. Level 1 of the same box, which is what `OpenDetails`
    /// provides for a screen with a second kind of detail — `GroupListView` uses
    /// it the same way. `@State` would be discarded on an iPad width change for
    /// exactly the reason recorded above.
    private var cohortSelection: Binding<Cohort?> {
        Binding(
            get: { openDetails[.people, level: 1] as? Cohort },
            set: {
                openDetails[.people, level: 1] = $0.map(AnyHashable.init)
                if $0 != nil { openDetails[.people] = nil }
            }
        )
    }

    /// Names for the nested-cohort references a definition can contain.
    ///
    /// Built from the list already fetched, so a reference costs no request. A
    /// reference to a cohort that is not in the list — deleted, or past the page
    /// size — simply stays unresolved and renders as its id, which is the honest
    /// outcome rather than a blank.
    private var cohortNames: [Int: String] {
        Dictionary(store.cohorts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    // In compact width the index behind "More" owns the navigation stack (see
    // `RootView`). A `NavigationSplitView` here collapses into a stack of its
    // own inside that one, which draws a second navigation bar above the first —
    // a whole row spent on a back chevron. There is no second column at phone
    // width anyway, so nothing is lost by pushing instead.
    var body: some View {
        if sizeClass == .compact {
            sidebar
                // Bound to `selection`, not registered `for: PersonSummary.self`.
                // A `for:` destination is driven by values the `NavigationLink`
                // appends to the *container's* path, which this screen can
                // neither read nor write — so the person open at 834pt could not
                // be put back on the stack at 375pt, and the person open at
                // 375pt was invisible to the detail column at 834pt. Bound to
                // the selection, one piece of state serves both.
                .navigationDestination(item: selection) { person in
                    PersonDetailView(person: person)
                        .id(person.id)
                }
                // A second destination, not a second `for:` registration, for
                // the same reason the first is bound to its selection.
                .navigationDestination(item: cohortSelection) { cohort in
                    CohortDetailView(cohort: cohort, cohortNames: cohortNames)
                        .id(cohort.id)
                }
        } else {
            NavigationSplitView {
                sidebar
                    // Sized to the row's two identifier lines: a distinct id is
                    // a 36-character UUID set monospaced (~300pt), and the
                    // caption under it — "3 distinct IDs · First seen Jan 3,
                    // 2026" — needs ~215pt beside a glyph, an Identified pill
                    // and the list insets. The 2-segment picker above the list
                    // is cheap by comparison; the rows are what set this.
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 440)
                    // The tab sidebar already puts a toggle in this bar; the
                    // split view added a second, identical one beside it.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                detailPane
            }
        }
    }

    /// The detail column: the chosen person, or a summary of the product when
    /// nobody is chosen yet.
    ///
    /// The no-selection branch mirrors the list's own states rather than summarising thin air: a locked
    /// key and a project that has never identified anyone are both normal
    /// outcomes, and a grid of zeroes would misreport either one.
    @ViewBuilder
    private var detailPane: some View {
        if let cohort = cohortSelection.wrappedValue {
            CohortDetailView(cohort: cohort, cohortNames: cohortNames)
                .id(cohort.id)
        } else if let person = selection.wrappedValue {
            PersonDetailView(person: person)
                .id(person.id)
        } else if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.personsError, store.persons.isEmpty {
            EmptyStateView(
                title: "Couldn't load persons",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await loadPersons() }
            }
        } else if store.persons.isEmpty {
            if store.isLoadingPersons {
                ProgressView().controlSize(.large)
            } else {
                EmptyStateView(
                    title: search.isEmpty ? "No persons" : "No matches",
                    systemImage: "person.slash",
                    message: search.isEmpty
                        ? "This project hasn't identified anyone yet."
                        : "No person matched “\(search)”."
                )
            }
        } else {
            PeopleOverview(
                persons: store.persons,
                total: store.personsTotal,
                cohorts: store.cohorts,
                cohortsLoadedAt: store.cohortsLoadedAt,
                search: search,
                loadedAt: store.personsLoadedAt,
                selection: selection
            )
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
            // Selection-driven at *both* widths, which is the delicate part.
            // Handing the `List` a binding makes it claim the row tap: the
            // `NavigationLink` sets `selection` rather than pushing, so
            // something else has to turn that selection into a visible screen.
            // Compact width used to pass `nil` here for exactly that reason;
            // it now has a display of its own — `navigationDestination(item:)`
            // in `body` — so the binding is what both widths read.
            List(selection: selection) {
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
            // Selection-driven at both widths, exactly as the persons list is.
            // Only one of the two lists is ever on screen, so the two selections
            // never compete for the same `List`.
            List(selection: cohortSelection) {
                Section {
                    ForEach(filteredCohorts) { cohort in
                        NavigationLink(value: cohort) { CohortRowView(cohort: cohort) }
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
            // Two lines, against the shared default of one. Measured: every row
            // read `2 distinct IDs · First seen Jul 2…` — the day of the month,
            // the only part that differs between people, was exactly what the
            // truncation removed, leaving a line that says "July" and nothing
            // else. A footnote that clips its own variable is worse than no
            // footnote, because it looks like information.
            footnoteLineLimit: 2,
            accessory: .pill(
                person.isIdentified ? "Identified" : "Anonymous",
                person.isIdentified ? Theme.accent : .secondary
            )
        )
        // Nothing in this row is prose, and typesetting it as if it were put a
        // hyphen inside an address: sample.user@example.org` wrapped onto a
        // second line reads as a different domain, which on a screen whose whole
        // job is identifying people is a lie rather than a blemish. `zxx` is the
        // code for "no linguistic content", so no hyphenation dictionary applies
        // and the title breaks only where the string already allows it.
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
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

    /// The count, and whether it is current.
    ///
    /// A cohort mid-calculation shows the *previous* evaluation's number, and a
    /// row that presents it as today's is the one thing a reader must not
    /// conclude from it. Said in words rather than by greying the number: state
    /// carried by colour alone is not state this app is allowed to carry.
    private var countText: String {
        guard let count = cohort.count else {
            return cohort.isRecalculating ? "Calculating…" : "Count not calculated"
        }
        let people = "\(Double(count).compactFormatted) people"
        return cohort.isRecalculating ? "\(people) · recalculating" : people
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
