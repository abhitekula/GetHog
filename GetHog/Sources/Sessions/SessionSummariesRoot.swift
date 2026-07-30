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
    @State private var store = SessionSummariesStore()
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle("Summaries")
            .toolbar {
                ProjectSwitcher()
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search the narrative or person")
            .refreshable { await load() }
            // Keyed on the filters too, so changing one issues the new request
            // rather than re-filtering the page already in hand — the counts
            // differ, and a client-side pass would answer "26 failures" with
            // however few of them landed in the first fifty rows.
            .task(id: filterKey) { await load() }
            .navigationDestination(for: SessionSummaryRow.self) { row in
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

    private var list: some View {
        List {
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
            title: total == 1 ? "1 summarised session" : "\(total) summarised sessions",
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

/// One summarised session.
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
        var parts = [SessionOutcomeStyle.title(row.outcome)]
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
/// screen shows it immediately and then fetches the chapters — which is the
/// second request, made on open, exactly once.
///
/// Chapters here are read rather than played: there is no replay on this screen
/// to seek. "Watch this session" pushes the session screen, where the same card
/// is drawn again with its chapters wired to the player.
struct SessionSummaryDetailView: View {
    let row: SessionSummaryRow

    @Environment(AppModel.self) private var model
    @State private var store = SessionSummaryStore()

    private var replayWebURL: URL? {
        model.webURL(path: "replay/\(row.id)")
    }

    var body: some View {
        PageScaffold {
            headerCard
            watchCard

            SessionSummaryCard(
                store: store,
                // No player on this screen, so offsets stay measured from
                // `session_start_time` — which is what they are recorded
                // against, and the honest reading when nothing is playing.
                origin: nil,
                canSeek: false,
                onRetry: { Task { await load() } }
            )

            FreshnessLabel(date: store.loadedAt)
        }
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

    private var headerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: SessionOutcomeStyle.systemImage(row.outcome))
                        .font(.title3)
                        .foregroundStyle(SessionOutcomeStyle.tint(row.outcome))
                        .accessibilityHidden(true)
                    Text(SessionOutcomeStyle.title(row.outcome))
                        .font(.headline)
                    Spacer()
                    if row.hasExceptions, let count = row.exceptionCount, count > 0 {
                        StatusPill(
                            text: count == 1 ? "1 exception" : "\(count) exceptions",
                            tint: Theme.Status.critical
                        )
                    }
                }

                if let narrative = row.outcome?.detail, !narrative.isEmpty {
                    Text(narrative)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(facts, id: \.label) { fact in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Text(fact.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: Theme.Space.s)
                            Text(fact.value)
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(fact.label), \(fact.value)")
                    }
                }
            }
        }
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
                        Text("Chapters below become a table of contents for the player")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.xs)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
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
        // session nobody has summarised, so the mistake would be invisible.
        await store.load(client: client, projectID: projectID, sessionID: row.id)
    }
}
