import GetHogKit
import SwiftUI

/// The people in one cohort.
///
/// A separate store from `PeopleStore` so a failure here leaves the cohort's
/// *definition* on screen: the definition arrives with the list of cohorts and
/// costs nothing, and losing it because a member request 500'd would be throwing
/// away the half of the screen that still works.
///
/// **One request per cohort opened, and only when it is opened.** The rate-limit
/// budget is organisation-wide and shared with whatever else the user has
/// integrated, so a cohort list of forty must not cost forty member requests. It
/// costs zero until a row is tapped, then one.
@MainActor
@Observable
final class CohortMembersStore {
    var members: [PersonSummary] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// Deliberately not a total.
    ///
    /// The documented `/persons/?cohort=` response contains
    /// `{results, next, previous}` and no `count`. So "showing N of M" cannot be built from
    /// this response; `M` is the cohort's own `count`, which is a different
    /// number computed at a different time, and the section footer says so
    /// rather than presenting the two as one measurement.
    ///
    /// **This is also the truncation signal, and it is a `next` link rather than
    /// `QueryResponse.hasMore` because this path is REST and not HogQL.** The
    /// silent-cap failure `hasMore` exists for — a HogQL query with no `LIMIT`
    /// of its own returning 100 rows with HTTP 200 and no error — cannot reach a
    /// paginated DRF list endpoint, which states its own `limit` and answers
    /// with a cursor when there is more. Members were routed through `/persons/`
    /// rather than through a HogQL `IN COHORT` query partly for that: the
    /// cohort's size is the one number on this screen a reader is most likely to
    /// act on, and a query that can silently answer with its first hundredth is
    /// the wrong instrument to measure it with.
    var hasMorePages = false

    private let pageSize = 50

    func load(client: PostHogClient, projectID: Int, cohortID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<PersonSummary> = try await client.send(
                PostHogAPI.persons(projectID: projectID, limit: pageSize, cohort: cohortID)
            )
            members = page.results
            hasMorePages = page.next != nil
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// What a cohort *is* and who is in it.
///
/// Before this screen existed, a cohort in GetHog was a name, a count and a
/// static/dynamic pill — which is the label on the box rather than the box.
///
/// **The definition costs no request.** `GET /cohorts/` returns each cohort's
/// whole `filters` tree, so everything in the definition section is already in
/// hand when the row is tapped. The only request this screen makes is for the
/// members.
///
/// **The four states are drawn as four different things**, because a reader
/// deciding whether to trust a count needs to tell them apart:
///
/// * a static cohort has no rules, and saying "no conditions" would be right
///   but would read as missing data — so it says what a static cohort *is*;
/// * a cohort mid-calculation has rules and a count that belongs to the
///   *previous* evaluation, which is the one case where the two things on screen
///   disagree, so the count is captioned rather than left to be read as current;
/// * a definition this build cannot draw — SQL-defined, pre-migration, or
///   carrying a condition type this version has no case for — says which, and
///   never renders as "matches everyone";
/// * a dynamic cohort with a genuinely empty tree *does* match everyone, and
///   that is stated rather than shown as a blank section.
struct CohortDetailView: View {
    @Environment(AppModel.self) private var model

    let cohort: Cohort
    /// Names for nested-cohort references, from the list this screen was opened
    /// from. PostHog sends only an id on those conditions, and "is in cohort
    /// #730101" is not a definition — resolving it from cohorts already fetched
    /// costs no request where `GET /cohorts/:id/` per reference would.
    let cohortNames: [Int: String]

    @State private var store = CohortMembersStore()

    var body: some View {
        List {
            Section { header }
            countsRow
            definitionSection
            membersSection
        }
        .pageSurface()
        .navigationTitle(cohort.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.projectID ?? 0)|\(cohort.id)") { await loadMembers() }
        .refreshable { await loadMembers() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                StatusPill(
                    text: cohort.isStatic ? "Static" : "Dynamic",
                    tint: cohort.isStatic ? .secondary : Theme.accent
                )
                if cohort.isRecalculating {
                    StatusPill(text: "Calculating", tint: Theme.accentWarm)
                }
                if cohort.errorsCalculating > 0 {
                    StatusPill(text: "Calculation failed", tint: Theme.Status.critical)
                }
            }

            if let description = cohort.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = cohort.lastErrorMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.Status.criticalInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// The sentence that says how to read the count above it.
    ///
    /// Stated per cohort rather than once in a list footer, because the
    /// static/dynamic difference is the difference between "this number moved
    /// while you read it" and "this number is from March".
    private var explanation: String {
        if cohort.isRecalculating {
            return cohort.isStatic
                ? "PostHog is recalculating this cohort. The count below is from the previous calculation."
                : "PostHog is re-evaluating these rules now, so the count below is the previous evaluation's."
        }
        return cohort.isStatic
            ? "A static cohort is a snapshot: these members were fixed when it was created or last calculated, and only move when someone recalculates it."
            : "A dynamic cohort re-evaluates its rules, so people join and leave on their own and the count moves with them."
    }

    private var countsRow: some View {
        StatStrip {
            MetricTile(
                label: cohort.isRecalculating ? "Members (previous)" : "Members",
                value: cohort.count.map { Double($0).compactFormatted } ?? "—",
                compact: true
            )
            MetricTile(label: "Rules", value: rulesValue, compact: true)
            MetricTile(label: "Listed here", value: store.members.count.formatted(), compact: true)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// An em dash, not a zero.
    ///
    /// A static cohort has no rules and a SQL-defined one has rules this build
    /// cannot count; "0" would claim both are defined by nothing, which for the
    /// SQL cohort is false and for the static one is beside the point.
    private var rulesValue: String {
        if case .filters(let definition) = cohort.definitionState {
            return definition.conditionCount.formatted()
        }
        return "—"
    }

    // MARK: - Definition

    @ViewBuilder
    private var definitionSection: some View {
        Section {
            switch cohort.definitionState {
            case .staticMembership:
                SectionEmptyState(
                    text: "No rules — membership is a fixed list.",
                    systemImage: "list.bullet.rectangle",
                    detail: "Someone chose these people, or a feature flag or replay scan created the cohort from a result. Nothing re-evaluates."
                )

            case .unrenderable(let reason):
                // The *reason* is the headline, not the fact that there is one.
                // `SectionEmptyState` collapses its `detail` behind a "Details"
                // disclosure, and photographing this state showed the screen
                // saying only "This cohort's definition can't be shown here" —
                // which is the same sentence for a SQL cohort and a
                // pre-migration one, and tells a reader nothing they can act on.
                SectionEmptyState(
                    text: reason,
                    systemImage: "questionmark.square.dashed",
                    detail: "GetHog can list the members below, but not the rules that select them. Open the cohort in PostHog to read those."
                )

            case .matchesEveryone:
                SectionEmptyState(
                    text: "No conditions — this cohort matches everyone.",
                    systemImage: "person.3",
                    detail: "The rules are genuinely empty, which PostHog allows. Every person in the project is a member."
                )

            case .filters(let definition):
                let resolved = definition.resolvingCohortNames(cohortNames)
                CohortGroupView(group: resolved.root, depth: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if resolved.filtersTestAccounts == true {
                    Text("PostHog's internal and test users are excluded on top of these rules.")
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                if !resolved.unrenderableTypes.isEmpty {
                    // The condition is *in* the tree above, drawn as an
                    // unrenderable row. This says it again at the section level
                    // because a definition read as complete when it is not is
                    // the failure with no symptom.
                    Text(
                        "\(resolved.unrenderableTypes.count == 1 ? "One condition uses" : "Some conditions use") a rule type this version of GetHog cannot describe (\(resolved.unrenderableTypes.joined(separator: ", "))). The rules above are therefore incomplete."
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.Status.warningInk)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            SectionLabel(text: "Definition", systemImage: "line.3.horizontal.decrease.circle")
        } footer: {
            if let calculated = cohort.lastCalculation {
                Text(
                    "Last calculated \(calculated.formatted(.relative(presentation: .named)))."
                )
            }
        }
    }

    // MARK: - Members

    @ViewBuilder
    private var membersSection: some View {
        Section {
            if let error = store.error, store.members.isEmpty {
                SectionEmptyState(
                    text: "Couldn't load members.",
                    systemImage: "exclamationmark.triangle",
                    detail: error,
                    actionTitle: "Try again"
                ) {
                    Task { await loadMembers() }
                }
            } else if store.members.isEmpty && !store.isLoading {
                SectionEmptyState(
                    text: cohort.isRecalculating
                        ? "No members yet — this cohort is still calculating."
                        : "Nobody is in this cohort.",
                    systemImage: "person.slash"
                )
            } else {
                ForEach(store.members, id: \.self) { person in
                    PersonRowView(person: person)
                }
                .skeleton(store.isLoading && store.members.isEmpty)
            }
        } header: {
            SectionLabel(text: "Members", systemImage: "person.2")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(membersFootnote)
                FreshnessLabel(date: store.loadedAt)
            }
        }
    }

    /// The members request answers with no total — only
    /// `{results, next, previous}` — and the cohort's `count` is a *separately calculated*
    /// number from a *different* moment. Presenting the two as one fraction
    /// would be arithmetic across two measurements, and on a cohort that is
    /// recalculating the fraction could exceed one.
    private var membersFootnote: String {
        let listed = store.members.count
        let base = listed == 1 ? "The first member." : "The first \(listed) members."
        guard store.hasMorePages else { return base }
        if let count = cohort.count, !cohort.isRecalculating {
            return "\(base) PostHog's last calculation put \(Double(count).compactFormatted) people in this cohort."
        }
        return "\(base) There are more."
    }

    private func loadMembers() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, cohortID: cohort.id)
    }
}

// MARK: - The filter tree

/// One `AND`/`OR` group, and everything under it.
///
/// **Indentation plus an explicit joiner, not indentation alone.** The structure
/// is the meaning here — "internal OR (pro AND signed up after January)" selects
/// a different set from "(internal OR pro) AND signed up after January" — and
/// indentation is invisible to VoiceOver, invisible in a screenshot at a glance,
/// and the first thing that collapses at an accessibility type size, where a
/// nested group's indent is a smaller fraction of a line that now wraps four
/// times. So the combinator is drawn as a word between every pair of siblings,
/// and each group states its own rule in a header. A reader can get the
/// grouping right from the words with the indentation ignored entirely.
///
/// The indent is capped, for the same reason: PostHog permits arbitrary nesting,
/// and an uncapped ladder at AX5 leaves a two-character column for the text.
struct CohortGroupView: View {
    let group: CohortFilterGroup
    let depth: Int

    /// Scales with type, because a fixed 16pt step is invisible beside 50pt text.
    @ScaledMetric(relativeTo: .body) private var step: CGFloat = 14

    private var indent: CGFloat {
        // Three levels of ladder, then flat. Beyond that the joiner words carry
        // the structure on their own, which they were written to be able to do.
        CGFloat(min(depth, 3)) * step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if depth == 0 || group.conditions.count > 1 {
                Text(depth == 0 ? group.combinator.headline : "Matching \(group.combinator == .and ? "all" : "any") of")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Ink.secondary)
                    .textCase(.uppercase)
                    // A structural label is a token, not prose — the same
                    // hyphenation trap `SectionLabel` and `StatusPill` record.
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))
            }

            ForEach(Array(group.conditions.enumerated()), id: \.element.id) { index, condition in
                if index > 0 {
                    Text(group.combinator.joiner)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .textCase(.uppercase)
                        .accessibilityLabel(
                            group.combinator == .and
                                ? "and also" : "or alternatively"
                        )
                }
                conditionView(condition)
            }
        }
        .padding(.leading, indent)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, depth == 0 ? Theme.Space.s : 0)
    }

    @ViewBuilder
    private func conditionView(_ condition: CohortCondition) -> some View {
        switch condition {
        case .group(let nested):
            // The nested group brings its own leading padding, so this one adds
            // none: `padding(.horizontal)` applied twice would compound into a
            // margin that eats the line at an accessibility size.
            CohortGroupView(group: nested, depth: depth + 1)
                .padding(.horizontal, -Theme.Space.l)

        case .property(let property):
            CohortConditionRow(
                glyph: property.scope == .column ? "tablecells" : "tag",
                key: property.key,
                comparison: property.comparison,
                value: property.valueText,
                caption: property.scope.noun,
                summary: property.summary,
                tint: Theme.accent
            )

        case .behavioural(let behaviour):
            CohortConditionRow(
                glyph: behaviour.negated ? "bolt.slash" : "bolt",
                key: behaviour.event,
                comparison: behaviour.summary,
                value: nil,
                caption: behaviour.eventType == "actions" ? "Action" : "Event",
                summary: behaviour.summary,
                tint: Theme.accentWarm,
                // The behavioural phrasing is a whole sentence rather than a
                // key/verb/value triple — "has performed event X at least 5
                // times in the last 14 days" does not decompose — so the row is
                // told to draw the sentence instead of the triple.
                prefersSentence: true
            )

        case .cohortReference(let reference):
            CohortConditionRow(
                glyph: "person.3",
                key: reference.name ?? "Cohort #\(reference.cohortID)",
                comparison: reference.negated ? "is not a member of" : "is a member of",
                value: nil,
                caption: "Another cohort",
                summary: reference.summary,
                tint: Theme.accent,
                prefersSentence: true,
                sentence: reference.summary
            )

        case .unrenderable(let unknown):
            CohortConditionRow(
                glyph: "questionmark.square.dashed",
                key: unknown.type,
                comparison: unknown.summary,
                value: nil,
                caption: "Unsupported rule",
                summary: unknown.summary,
                tint: Theme.accentWarm,
                prefersSentence: true
            )
        }
    }
}

/// One rule, drawn as a card so a group of them reads as a list of rules rather
/// than as a paragraph.
struct CohortConditionRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    let glyph: String
    let key: String
    let comparison: String
    var value: String?
    let caption: String
    /// The whole rule as one string, which is what VoiceOver reads. The visual
    /// layout splits it across three runs and a glyph; a screen reader hearing
    /// those as four separate elements would have to reassemble the sentence.
    let summary: String
    var tint: Color = Theme.accent
    var prefersSentence: Bool = false
    var sentence: String?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: glyph)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.secondary)
                    .textCase(.uppercase)
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))
                    // Measured at ax5 on `cohort-definition-rules`: "PERSON
                    // RECORD" came back as "PERSON RE…" while "PERSON PROPERTY"
                    // in the card above it wrapped to two lines. A caption that
                    // truncates is worse than one that wraps, because "PERSON
                    // RE…" and "PERSON PR…" are the same string to a reader and
                    // they name the two *different* halves of the persons table
                    // this row is distinguishing.
                    .fixedSize(horizontal: false, vertical: true)

                if prefersSentence {
                    Text(sentence ?? comparison)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Key, verb, value on their own runs: the key is an
                    // identifier and takes the monospaced face, the verb is
                    // prose, and the value is user data that may be an address
                    // or a path. Wrapping is left to each run, which is why the
                    // three are not one interpolated string.
                    Text(key)
                        .font(.subheadline.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        // An identifier is not prose. `$current_url` broken as
                        // `$cur-` / `rent_url` reads as a different property.
                        .typesettingLanguage(Locale.Language(identifier: "zxx"))
                    // **Two columns become two rows at accessibility sizes, and
                    // that is not tidying.** Measured at ax5: the verb and the
                    // value each wrapped inside their own column of an `HStack`,
                    // and `created_at is after 2026-01-01` rendered as
                    // `is │ 2026-` over `after │ 01-01` — two interleaved
                    // columns that a reader has to reassemble in the right
                    // order to get the condition, and can reassemble in the
                    // wrong one.
                    comparisonAndValue
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(
            Theme.cardBackground,
            in: .rect(cornerRadius: Theme.Radius.medium, style: .continuous)
        )
        // One element, one sentence. The glyph is decorative and the caption
        // duplicates what the sentence already says.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    @ViewBuilder
    private var comparisonAndValue: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                comparisonText
                valueText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                comparisonText
                valueText
            }
        }
    }

    private var comparisonText: some View {
        Text(comparison)
            .font(.subheadline)
            .foregroundStyle(Theme.Ink.secondary)
    }

    @ViewBuilder
    private var valueText: some View {
        if let value {
            Text(value)
                .font(.subheadline.weight(.medium))
                // A cohort's right-hand side is user data — an address, a path,
                // a version, a date — never prose, so no hyphenation dictionary
                // may break it.
                .typesettingLanguage(Locale.Language(identifier: "zxx"))
        }
    }
}
