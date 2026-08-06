import GetHogKit
import SwiftUI

// MARK: - List

/// Sessions somebody's AI has already read, filtered by how they went.
///
/// `?outcome=failure` is the reason this screen exists. Producing a list of
/// "sessions worth watching" is the hardest thing to do on a phone — the
/// alternative is scrubbing video on a four-inch canvas — and PostHog has
/// already done it, indexed, on the server.
///
/// **Read-only, and it says so.** Generation is a write endpoint and the
/// summariser's config is PAT-incompatible, so this client can only read what
/// someone else generated. The empty state states that rather than offering a
/// button that could never work.
struct SessionSummariesRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = SessionSummariesStore()
    @State private var search = ""

    /// The open summary, held in `OpenDetails` rather than pushed as a value
    /// onto the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it. A
    /// `NavigationLink(value:)` went onto whichever stack the host owned, and
    /// the host stops existing across the boundary — measured, the open summary
    /// was gone at 375pt and did not come back at 834.
    private var selection: Binding<SessionSummaryRow?> {
        Binding(
            get: { openDetails[.sessionSummaries] as? SessionSummaryRow },
            set: { openDetails[.sessionSummaries] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        content
            .navigationTitle("Summaries")
            .toolbar {
                ProjectSwitcher()
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search the narrative or person")
            .screenRefreshable { await load() }
            // Keyed on the filters too, so changing one issues the new request
            // rather than re-filtering the page already in hand — the counts
            // differ, and a client-side pass would answer "26 failures" with
            // however few of them landed in the first fifty rows.
            .task(id: filterKey) { await load() }
            .navigationDestination(item: selection) { row in
                SessionSummaryDetailView(row: row)
            }
    }

    private var filterKey: String {
        "\(model.projectID ?? 0)-\(store.outcome?.rawValue ?? "all")-\(store.exceptionsOnly)"
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.sessions) {
            LockedCapabilityView(capability: .sessions, scope: model.lockedScope(for: .sessions)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.rows.isEmpty {
            EmptyStateView(
                title: "Couldn't load summaries",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.rows.isEmpty && !store.isLoading {
            EmptyStateView(
                title: emptyTitle,
                systemImage: "sparkles.rectangle.stack",
                message: emptyMessage
            )
        } else {
            list
        }
    }

    private var emptyTitle: String {
        store.outcome == nil && !store.exceptionsOnly ? "No summaries yet" : "Nothing under this filter"
    }

    private var emptyMessage: String {
        store.outcome == nil && !store.exceptionsOnly
            ? """
            Summaries are generated in PostHog, from the session replay page. \
            GetHog reads them; it can't ask for new ones.
            """
            : "No summary in this project matches the filter. Clear it to see the rest."
    }

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` displays it.
    private var list: some View {
        List(selection: selection) {
            if let total = store.total {
                Section { banner(total) }
            }

            Section {
                ForEach(visible) { row in
                    NavigationLink(value: row) {
                        SessionSummaryRowView(row: row)
                    }
                    .listRowBackground(cardRowBackground)
                    .listRowSeparator(.hidden)
                }
            } header: {
                // Attribution, and it is not decoration.
                //
                // Every row on this screen leads with a verdict and three lines
                // of prose that a model wrote, and nothing on the screen said so:
                // not the title ("Summaries"), not the banner, not the rows. Read
                // cold, the list is indistinguishable from a list of measurements
                // PostHog returned. This is the header that makes the whole
                // section's provenance visible; the per-row spoken label carries
                // the same word, because VoiceOver reaches a row long after a
                // header has been read and forgotten.
                SectionLabel(text: "AI summaries", systemImage: "text.append", productMark: .session)
            } footer: {
                Text(footerNote)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.rows.isEmpty)
    }

    /// States the size of what is being looked at, because the filter is applied
    /// by PostHog and the count is therefore the project's, not this page's.
    private func banner(_ total: Int) -> some View {
        DataRow(
            glyph: store.outcome == .failure ? "xmark.circle" : "sparkles.rectangle.stack",
            tint: store.outcome == .failure ? Theme.accentWarm : Theme.accent,
            title: total == 1 ? "1 summarized session" : "\(total) summarized sessions",
            subtitle: filterDescription,
            accessory: .none
        )
        .listRowBackground(cardRowBackground)
        .listRowSeparator(.hidden)
    }

    private var filterDescription: String {
        var parts: [String] = []
        parts.append(store.outcome.map(\.title) ?? "Every outcome")
        if store.exceptionsOnly { parts.append("with exceptions") }
        return parts.joined(separator: " · ")
    }

    private var footerNote: String {
        let shown = visible.count
        let fetched = store.rows.count
        var note = "PostHog applies the outcome and exception filters, so the count above is the "
            + "whole project's. This page holds the most recent \(fetched)."
        if shown != fetched {
            note += " \(shown) of them match “\(search)”."
        }
        return note
    }

    /// Search is the one filter done here rather than on the server: the API has
    /// no full-text parameter, and the narrative is the field worth searching.
    private var visible: [SessionSummaryRow] {
        guard !search.isEmpty else { return store.rows }
        return store.rows.filter { row in
            [row.outcome?.detail, row.distinctID, row.id]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Outcome", selection: Binding(
                get: { store.outcome }, set: { store.outcome = $0 }
            )) {
                Text("Every outcome").tag(SessionSummaryOutcomeFilter?.none)
                ForEach(SessionSummaryOutcomeFilter.allCases) { option in
                    Text(option.title).tag(SessionSummaryOutcomeFilter?.some(option))
                }
            }
            Toggle("With exceptions only", isOn: Binding(
                get: { store.exceptionsOnly }, set: { store.exceptionsOnly = $0 }
            ))
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter summaries")
    }

    private var cardRowBackground: some View {
        Theme.cardBackground
            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            .padding(.vertical, 1)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Row

/// One summarized session.
///
/// The narrative is the subtitle rather than the person, and it gets three
/// lines: it is the only thing on the row that tells one session from another,
/// and it is what makes the list scannable without opening anything.
struct SessionSummaryRowView: View {
    let row: SessionSummaryRow

    var body: some View {
        DataRow(
            glyph: SessionOutcomeStyle.systemImage(row.outcome),
            tint: SessionOutcomeStyle.tint(row.outcome),
            title: SessionOutcomeStyle.title(row.outcome),
            subtitle: row.outcome?.detail ?? "No narrative recorded.",
            footnote: stats,
            subtitleLineLimit: 3,
            // No accessory: every use of this row is inside a `NavigationLink`
            // in a `List`, which draws its own disclosure indicator. `DataRow`'s
            // sat beside it — and lower, because it centres on the text block
            // while the List's centres on the whole row.
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var stats: String {
        var parts: [String] = []
        if let duration = row.durationText { parts.append(duration) }
        if row.hasExceptions, let count = row.exceptionCount {
            parts.append(count == 1 ? "1 exception" : "\(count) exceptions")
        }
        if let start = row.startTime {
            parts.append(start.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        // Leads with the provenance, for the reason the section header exists:
        // the title and the subtitle are both a model's words, and a row read on
        // its own has no header above it to say so.
        var parts = ["AI summary", SessionOutcomeStyle.title(row.outcome)]
        if let narrative = row.outcome?.detail { parts.append(narrative) }
        if let duration = row.durationText { parts.append("duration \(duration)") }
        if row.hasExceptions { parts.append("has exceptions") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

/// One summary, read on its own.
///
/// **One request.** The list row already carries the headline outcome, so this
/// screen shows it immediately — as `SessionSummaryCard`'s `seed`, under that
/// card's own label — and then fetches the chapters, which is the second
/// request, made on open, exactly once.
///
/// Chapters here are read rather than played: there is no replay on this screen
/// to seek. "Watch this session" pushes the session screen, where the same card
/// is drawn again with its chapters wired to the player.
struct SessionSummaryDetailView: View {
    let row: SessionSummaryRow

    @Environment(AppModel.self) private var model
    /// Read for the facts card's *heading*, which changes shape rather than
    /// shrinking; see `factsCard`. The rows below it no longer need this — their
    /// stacking is `MeasuredPairStyle`'s, applied through the environment.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store = SessionSummaryStore()

    private var replayWebURL: URL? {
        model.webURL(path: "replay/\(row.id)")
    }

    /// **The generated card comes first, and there is only one of it.**
    ///
    /// This screen used to open with an unlabelled card carrying the model's
    /// verdict and its whole paragraph, and then repeat both verbatim further
    /// down under "AI summary · gemini-3-flash-preview". The duplication was the
    /// visible symptom; the defect was which copy came first. A reader meeting
    /// "Did not finish" and four sentences of narrative at the top of a screen,
    /// in the slot a summary of PostHog's own data would occupy, has no way to
    /// know a model wrote it — and this app's rule is that generated text is
    /// always visibly generated.
    ///
    /// So the prose lives in exactly one place, the one that names its author,
    /// and that card is moved to the top because it is what the screen is *for*.
    /// `seed:` is what stops the move costing anything: the row already carries
    /// the outcome, so the headline still renders before the second request
    /// answers — it simply renders under the label now.
    ///
    /// What is left in `factsCard` is the session's own record — when it
    /// started, how long it ran, who, which id, and when it was summarized —
    /// none of which a model wrote.
    var body: some View {
        PageScaffold {
            SessionSummaryCard(
                store: store,
                // No player on this screen, so offsets stay measured from
                // `session_start_time` — which is what they are recorded
                // against, and the honest reading when nothing is playing.
                origin: nil,
                seed: row.outcome,
                canSeek: false,
                onRetry: { Task { await load() } }
            )

            watchCard
            factsCard

            FreshnessLabel(date: store.loadedAt)
        }
        // Every label/value pair in `factsCard` stops at a readable measure
        // instead of spanning the card. See `Theme.Measure.pair`: on an iPad this
        // screen was putting "Session" and a 36-character UUID ~600pt apart.
        .measuredPairs()
        .navigationTitle("Session summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let replayWebURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: replayWebURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share a link to this session")
                }
            }
        }
        .task(id: row.id) { await load() }
        .refreshable { await load() }
    }

    /// The session's own record: when, how long, who, which id, and when it was
    /// summarized.
    ///
    /// Deliberately holds nothing a model wrote. The verdict and the narrative
    /// that used to head this card are in `SessionSummaryCard` above, once, under
    /// the label naming the model that produced them — see `body`. The exception
    /// count stays, because `exception_count` is a number PostHog counted rather
    /// than a reading of the session, and it is the one fact here that changes
    /// how urgently the rest is read.
    ///
    /// **The heading and the badge stop sharing a row at accessibility sizes.**
    /// Measured at AX5 on an iPhone 17 Pro: `2 exceptions` in a `StatusPill` is
    /// around 350pt of a 393pt window, and beside a glyph and a spacer it left the
    /// heading a column narrower than a single character — it rendered as
    /// *nothing*, while still claiming one line's height per character it could
    /// not draw, and the card came out roughly 1450pt tall holding a glyph and a
    /// pill in a field of white. `StatusPill` no longer refuses to compress at
    /// these sizes, which is the half of the fix every screen gets; this is the
    /// other half, and it is the same reflow `FunnelStepRow` and `InsightLegend`
    /// make — the elastic thing gets the whole width, and what was beside it takes
    /// its own line.
    private var factsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionLabel(text: "Session", systemImage: "clock", productMark: .session)
                        exceptionPill
                    }
                } else {
                    HStack(spacing: Theme.Space.s) {
                        SectionLabel(text: "Session", systemImage: "clock", productMark: .session)
                        Spacer()
                        exceptionPill
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(facts, id: \.label) { fact in
                        factRow(fact)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(fact.label), \(fact.value)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var exceptionPill: some View {
        if row.hasExceptions, let count = row.exceptionCount, count > 0 {
            StatusPill(
                text: count == 1 ? "1 exception" : "\(count) exceptions",
                tint: Theme.Status.critical
            )
        }
    }

    /// Label and value, capped at a readable measure.
    ///
    /// A `LabeledContent`, not the `HStack { label; Spacer(); value }` this used
    /// to be — the same conversion `ErrorIssueDetailView.seenRow` and
    /// `detailRow` made. The hand-rolled row drew exactly what a
    /// `LabeledContent` draws, so writing it out bought nothing and cost the one
    /// thing that matters: a hand-rolled row cannot be reached by
    /// `.measuredPairs()`. It obeyed "label on one edge, value on the other"
    /// literally, which on a phone is the Settings app and on an iPad card is
    /// two facts a hand's width apart.
    ///
    /// Both behaviours this row used to implement itself are ones
    /// `MeasuredPairStyle` deliberately reproduces, so the conversion loses
    /// neither — which is why the style was adopted rather than a third variant
    /// hand-rolled:
    ///
    /// - **It stacks at accessibility sizes.** Two of these five values are
    ///   identifiers rather than prose — a distinct ID and a 36-character
    ///   session UUID — and at AX5 the label side alone takes most of the width,
    ///   so past that threshold the value gets its own line rather than a
    ///   two-character gutter.
    /// - **It stays one VoiceOver element.** The style combines label and value
    ///   into a single stop; the explicit label at the call site then states the
    ///   pair in words.
    ///
    /// Text alignment is the style's too, and it lands where the two call sites
    /// used to put it by hand: trailing in the horizontal branch, and the
    /// leading default in the stacked one.
    private func factRow(_ fact: (label: String, value: String)) -> some View {
        LabeledContent {
            factValue(fact.value)
        } label: {
            factLabel(fact.label)
        }
    }

    private func factLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            // The same measured reason every other supporting line in the app is
            // on `Theme.Ink`: `.secondary` is an alpha composite and lands at
            // 3.44:1 on a white card.
            .foregroundStyle(Theme.Ink.secondary)
    }

    private func factValue(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            // Explicit, so the style's own greying does not apply.
            //
            // `MeasuredPairStyle` puts the *value* on `Theme.Ink.secondary`,
            // because the built-in style it replaces greys the value to separate
            // it from a primary label. This card is the other way round — the
            // label is already `Theme.Ink.secondary` — so inheriting would paint
            // both sides the same colour and flatten the pair into one
            // undifferentiated line. An explicit style on the content wins over
            // the inherited one, which is the escape hatch that style documents
            // and the same one the `StatusPill` in a span's Status row uses.
            .foregroundStyle(.primary)
            // `Person` and `Session` are opaque identifiers, and this is the
            // same idiom `DataRow` applies to every token it draws: `zxx` is the
            // ISO code for "no linguistic content", so no hyphenation dictionary
            // applies and a hyphen this app invented cannot be mistaken for one
            // the id contains.
            .typesettingLanguage(Locale.Language(identifier: "zxx"))
            .textSelection(.enabled)
    }

    private var facts: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let start = row.startTime {
            rows.append((
                "Started",
                start.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())
            ))
        }
        if let duration = row.durationText { rows.append(("Duration", duration)) }
        if let distinctID = row.distinctID { rows.append(("Person", distinctID)) }
        rows.append(("Session", row.id))
        if let created = row.createdAt {
            // Provenance matters here more than usual: the summary was written
            // at a moment in time by a model, against the session as it stood.
            rows.append(("Summarised", created.formatted(.relative(presentation: .named))))
        }
        return rows
    }

    /// The way through to the replay — and to the same chapters, seekable.
    private var watchCard: some View {
        Card {
            NavigationLink {
                DetachedRecordingView(recordingID: row.id)
                    .navigationTitle("Session")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Watch this session")
                            .font(.subheadline.weight(.semibold))
                        // "Above", because the summary card now leads the screen.
                        Text("The chapters above become a table of contents for the player")
                            .font(.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.xs)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        // A disclosure indicator is a control, not decoration, so
                        // it owes 3:1; `.tertiary` gave it 1.73:1 on this card.
                        .foregroundStyle(Theme.Ink.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watch this session, with the chapters as a table of contents")
        .accessibilityAddTraits(.isButton)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        // Keyed by `session_id`, never by the summary record's own id — that
        // request answers 404, which is the same answer the API gives for a
        // session nobody has summarized, so the mistake would be invisible.
        await store.load(client: client, projectID: projectID, sessionID: row.id)
    }
}
