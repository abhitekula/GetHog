import GetHogKit
import GetHogUI
import SwiftUI

/// What the iPad detail pane shows before a person is picked.
///
/// Replaces `ContentUnavailableView("Select a person")`, which held two thirds
/// of an 11-inch canvas — the largest surface in the app spent on a sentence.
///
/// **Cost:** nothing. Everything here is folded out of the page of persons and
/// the cohorts the screen has already fetched; the rate-limit budget is
/// organisation-wide and a summary nobody asked for must not spend a request of
/// it.
///
/// This is the thinnest of the app's overviews on purpose. The persons endpoint
/// returns one page of 50 out of what can be tens of thousands, so almost
/// nothing here can honestly be a project total. Exactly two figures are:
/// the server's own match count, and the cohort list, which arrives whole. The
/// rest is captioned with the population it actually describes rather than being
/// promoted to a project-wide claim it cannot support.
struct PeopleOverview: View {
    let persons: [PersonSummary]
    /// The server's count for the current query — a real total, and the only
    /// figure on this screen that is one.
    let total: Int?
    let cohorts: [Cohort]
    /// Cohorts load lazily, the first time that segment is opened. Nil means
    /// "never asked", which is not the same as "none exist".
    let cohortsLoadedAt: Date?
    let search: String
    let loadedAt: Date?
    @Binding var selection: PersonSummary?

    @Environment(AppModel.self) private var model

    private var isSearching: Bool { !search.isEmpty }

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            header
            identificationSection
            cohortSection
            recentSection
            FreshnessLabel(date: loadedAt)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "People", systemImage: "person.2")

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip {
                MetricTile(
                    // Renamed while a search is running, because the server's
                    // count is then the number of matches — printing it under
                    // "People" would restate a filtered figure as the project's.
                    label: isSearching ? "Matching" : "People",
                    value: (total.map(Double.init) ?? Double(persons.count)).compactFormatted,
                    compact: true
                )
                if cohortsLoadedAt != nil {
                    MetricTile(label: "Cohorts", value: "\(cohorts.count)", compact: true)
                }
            }
            .padding(.horizontal, -Theme.Space.l)

            if isSearching {
                Text("Matching “\(search)”.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Identified versus anonymous, scoped out loud.
    ///
    /// Useful because it answers "is `identify()` actually wired up" at a
    /// glance, and safe only because the section says which population it
    /// counted. The same two numbers under a heading reading "People" would be
    /// a claim about the project that one page of 50 cannot support.
    private var identificationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(
                text: "Of the \(persons.count) loaded",
                systemImage: "person.crop.circle.badge.questionmark"
            )

            Card {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    // The pill carries the word; the tint only reinforces it,
                    // the same way the rows in the list beside this do.
                    countTile("Identified", identified, Theme.accent)
                    countTile("Anonymous", persons.count - identified, .secondary)
                }
            }
        }
    }

    private func countTile(_ title: String, _ count: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            StatusPill(text: title, tint: tint)
            Text("\(count)")
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(title.lowercased()) of \(persons.count) loaded")
    }

    @ViewBuilder
    private var cohortSection: some View {
        if cohortsLoadedAt != nil, !largestCohorts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Largest cohorts", systemImage: "person.3.fill")

                VStack(spacing: Theme.Space.s) {
                    ForEach(largestCohorts) { cohort in
                        Card(padding: Theme.Space.m) {
                            DataRow(
                                glyph: "person.3.fill",
                                tint: cohort.isStatic ? .secondary : Theme.accent,
                                title: cohort.name,
                                subtitle: cohort.description,
                                // A static count is a snapshot and a dynamic one
                                // moves on its own, so the kind is stated beside
                                // the number rather than left to the tint.
                                footnote: cohort.isStatic ? "Static" : "Dynamic",
                                accessory: .metric(
                                    Double(cohort.count ?? 0).compactFormatted
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !newest.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Newest of those loaded", systemImage: "clock.arrow.circlepath")

                VStack(spacing: Theme.Space.s) {
                    ForEach(newest) { person in
                        personRow(person)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func personRow(_ person: PersonSummary) -> some View {
        Button {
            selection = person
        } label: {
            Card(padding: Theme.Space.m) {
                DataRow(
                    glyph: person.isIdentified ? "person.fill" : "person.fill.questionmark",
                    tint: person.isIdentified ? Theme.accent : .secondary,
                    title: person.displayName,
                    subtitle: distinctID(person),
                    footnote: person.createdAt.map {
                        "First seen \($0.formatted(.dateTime.year().month().day()))"
                    },
                    isSubtitleMonospaced: true,
                    accessory: .none
                )
            }
        }
        // `.card` on tvOS for the reason `SessionsOverview` states in full:
        // `.plain` draws no focus state, and focus is how a remote says where
        // it is.
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        .pointerHighlight(cornerRadius: Theme.Radius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(person.displayName), \(person.isIdentified ? "identified" : "anonymous")"
        )
    }

    private func distinctID(_ person: PersonSummary) -> String? {
        guard let first = person.distinctIDs.first, first != person.displayName else { return nil }
        return first
    }

    // MARK: - Data

    private var identified: Int {
        persons.filter(\.isIdentified).count
    }

    private var largestCohorts: [Cohort] {
        Array(
            cohorts
                .filter { ($0.count ?? 0) > 0 }
                .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
                .prefix(5)
        )
    }

    /// Newest by `created_at`, and only among the people actually held.
    ///
    /// Ordered here rather than trusted from the endpoint: the request does not
    /// ask for an order, so the page's own sequence is not something to make a
    /// claim from.
    private var newest: [PersonSummary] {
        Array(
            persons
                .compactMap { person in person.createdAt.map { (person, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(5)
                .map(\.0)
        )
    }
}
