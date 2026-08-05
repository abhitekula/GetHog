import GetHogKit
import SwiftUI

@MainActor
@Observable
final class SessionsStore {
    var recordings: [SessionRecording] = []
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    var loadedAt: Date?
    /// Whether the API said another page exists. There is no `count` in the
    /// response, so this is the only thing that can be known about what is left.
    var hasMore = false

    /// Server-side. The whole filter, including the person search behind the
    /// navigation bar's field.
    var filter = SessionRecordingFilter()

    private var offset = 0
    private let pageSize = 50

    /// Bumped on every fresh load so a page that was already in flight when the
    /// filter changed cannot append its rows onto the new filter's results.
    private var generation = 0

    /// Loads the first page for the current filter, **replacing** what is shown.
    func load(client: PostHogClient, projectID: Int) async {
        generation += 1
        let token = generation
        offset = 0
        isLoading = true
        defer { if token == generation { isLoading = false } }

        do {
            let list: RecordingList = try await client.send(
                PostHogAPI.sessionRecordings(
                    projectID: projectID, limit: pageSize, offset: 0, filter: filter
                )
            )
            guard token == generation else { return }
            recordings = list.results
            hasMore = list.hasNext
            offset = list.results.count
            loadedAt = Date()
            error = nil
        } catch {
            guard token == generation else { return }
            // A failed narrowing must not leave the previous filter's rows on
            // screen looking like the answer to the new question.
            recordings = []
            hasMore = false
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Appends the next page. Never runs while a fresh load is in flight, and
    /// discards its result if the filter changed underneath it.
    func loadMore(client: PostHogClient, projectID: Int) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let token = generation
        isLoadingMore = true
        defer { if token == generation { isLoadingMore = false } }

        do {
            let list: RecordingList = try await client.send(
                PostHogAPI.sessionRecordings(
                    projectID: projectID, limit: pageSize, offset: offset, filter: filter
                )
            )
            guard token == generation else { return }
            // Offset paging over a live, time-ordered table can repeat a row
            // when a new recording lands between pages.
            let known = Set(recordings.map(\.id))
            recordings.append(contentsOf: list.results.filter { !known.contains($0.id) })
            hasMore = list.hasNext
            offset += list.results.count
            loadedAt = Date()
        } catch {
            guard token == generation else { return }
            hasMore = false
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// A stable key for the current request. Driving `.task(id:)` with this is
    /// what makes a filter change cancel the in-flight request and start a
    /// replacing load, rather than racing it.
    var requestSignature: String {
        filter.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }
}

struct SessionsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = SessionsStore()
    @State private var showsFilters = false

    /// The open recording's id, and deliberately **not** `@State`.
    ///
    /// See `FlagsRoot.selectedID` for the measurement. Since the tab bar became
    /// a preference this screen can be demoted, a demoted screen is pushed onto
    /// the search tab's stack, and a `NavigationSplitView` nested in a
    /// `NavigationStack` has nowhere to put its detail - so the row opened
    /// nothing at all.
    private var selectedID: Binding<String?> {
        Binding(
            get: { openDetails[.sessions] as? String },
            set: { openDetails[.sessions] = $0.map(AnyHashable.init) }
        )
    }

    private var selection: SessionRecording? {
        selectedID.wrappedValue.flatMap { id in store.recordings.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                listChrome
                    .navigationDestination(item: selectedID) { id in
                        if let recording = store.recordings.first(where: { $0.id == id }) {
                            SessionDetailView(recording: recording).id(id)
                        }
                    }
            } else {
                NavigationSplitView {
                    listChrome
                } detail: {
                    detailPane
                }
            }
        }
    }

    /// The list and everything attached to it, shared by both widths so the two
    /// arrangements cannot drift in what they load, search or filter.
    private var listChrome: some View {
        @Bindable var store = store

        return content
                .navigationTitle("Sessions")
                .toolbar {
                    ProjectSwitcher()
                    ToolbarItem(placement: .topBarTrailing) { filterButton }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Playlists are saved views over these same recordings,
                        // so they live here rather than competing for a tab.
                        NavigationLink {
                            PlaylistsView { store.filter = $0 }
                        } label: {
                            Image(systemName: "list.star")
                        }
                        .accessibilityLabel("Playlists")
                    }
                }
                .projectSubtitle()
                // Placement is pinned rather than left to `.automatic`, for the
                // reason recorded on `EventsRoot`: measured on iPad, the
                // automatic placement drew no field at all in the list column.
                //
                // The text now goes to the server. It used to filter the loaded
                // page for a substring of the person *or* the start URL; that
                // matched within 50 rows and disagreed with the duration picker
                // beside it, which also filtered locally. Both are server-side
                // now, and the URL half moved to its own field on the filter
                // sheet — one text box cannot drive two AND'd clauses.
                .searchable(
                    text: Binding(
                        get: { store.filter.personSearch ?? "" },
                        set: { store.filter.personSearch = $0.isEmpty ? nil : $0 }
                    ),
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search person email"
                )
                .refreshable { await load() }
                // One task covers project switches, typing and every control on
                // the filter sheet. `.task(id:)` cancels the previous one, so a
                // burst of keystrokes costs one request, and a filter change
                // always *replaces* the paging state rather than extending it.
                .task(id: "\(model.projectID ?? 0)|\(store.requestSignature)") {
                    if store.filter.trimmedPersonSearch != nil
                        || store.filter.trimmedURLSearch != nil {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                    }
                    await load()
                }
                // Sized to the row's caption line, which is the longest thing
                // here: "0:42 · 12 clicks · 3 errors · Mobile, not playable ·
                // 2d" needs ~300pt, and the glyph plus row insets take another
                // ~90 before it starts. At the ~320pt the column took by
                // default the caveat that a recording cannot be played was
                // being truncated away — the one thing it exists to say early.
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 440)
                // The tab sidebar already puts a toggle in this bar; the split
                // view added a second, identical one beside it.
                .toolbar(removing: .sidebarToggle)
                .sheet(isPresented: $showsFilters) {
                    SessionFilterSheet(filter: $store.filter)
                        .presentationDetents([.medium, .large])
                }
    }

    /// The detail column: the chosen recording, or a summary of the product when
    /// nothing is chosen yet.
    ///
    /// The no-selection branch mirrors the list's own states rather than summarising thin air: a locked
    /// key and a project with replay switched off are both normal outcomes, and
    /// a grid of zeroes would misreport either one.
    @ViewBuilder
    private var detailPane: some View {
        if let selection {
            SessionDetailView(recording: selection).id(selection.id)
        } else if !model.isAvailable(.sessions) {
            LockedCapabilityView(capability: .sessions, scope: model.lockedScope(for: .sessions)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.recordings.isEmpty {
            EmptyStateView(
                title: "Couldn't load sessions",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.recordings.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.large)
            } else {
                emptyState
            }
        } else {
            SessionsOverview(
                recordings: store.recordings,
                loadedAt: store.loadedAt,
                selection: selectedID
            )
        }
    }

    /// Empty means one of two different things, and they need different words.
    /// An unfiltered empty project is a fact about the project; an empty result
    /// under a filter is a fact about the filter, and the way out is to widen
    /// it — so that state offers the control that would.
    private var emptyState: some View {
        Group {
            if store.filter.isNarrowed {
                EmptyStateView(
                    title: "No matching sessions",
                    systemImage: "line.3.horizontal.decrease.circle",
                    message: "No recordings match \(store.filter.activeCount) active filter\(store.filter.activeCount == 1 ? "" : "s").",
                    actionTitle: "Clear filters",
                    action: { store.filter.clear() }
                )
            } else {
                EmptyStateView(
                    title: "No sessions",
                    systemImage: "rectangle.stack",
                    illustration: .sessions,
                    message: "No session recordings in this project yet."
                )
            }
        }
    }

    /// Badged, because a narrowed list and an empty project look identical
    /// otherwise. The count is also spoken, so the state does not depend on
    /// noticing a coloured dot.
    private var filterButton: some View {
        Button {
            showsFilters = true
        } label: {
            Image(systemName: store.filter.isNarrowed
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(
            store.filter.isNarrowed
                ? "Filter sessions, \(store.filter.activeCount) active"
                : "Filter sessions"
        )
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.sessions) {
            LockedCapabilityView(capability: .sessions, scope: model.lockedScope(for: .sessions)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.recordings.isEmpty {
            EmptyStateView(
                title: "Couldn't load sessions",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.recordings.isEmpty && !store.isLoading {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: selectedID) {
            if store.filter.isNarrowed {
                ActiveFilterSummary(filter: store.filter) { store.filter.clear() }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(store.recordings) { recording in
                NavigationLink(value: recording.id) {
                    SessionRowView(recording: recording)
                }
                .listRowBackground(
                    Theme.cardBackground
                        .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                        .padding(.vertical, 1)
                )
                .listRowSeparator(.hidden)
            }

            if store.hasMore {
                // Explicit rather than automatic on appear: the rate-limit
                // budget is organisation-wide, and a scroll that keeps fetching
                // spends it without being asked to.
                Group {
                    if store.isLoadingMore {
                        ProgressView()
                    } else {
                        Button("Load more sessions") { Task { await loadMore() } }
                    }
                }
                .frame(maxWidth: .infinity)
                .minimumHitTarget()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.recordings.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }

    private func loadMore() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadMore(client: client, projectID: projectID)
    }
}

/// A plain-language sentence for what the list is currently showing.
///
/// Sits above the rows rather than in the toolbar because the badge on the
/// filter button says *that* the list is narrowed and this says *how* — and
/// "why am I only seeing four sessions" is a question asked while looking at
/// the list, not at the toolbar.
/// Not `SectionEmptyState`, which is documented for a section that has nothing
/// in it — this describes a section that has something in it, and borrowing
/// that component would have made its contract mean two things.
///
/// **Not `ViewThatFits` either**, which is the obvious answer and does not work
/// here. Rendered and looked at: a wrapping `Text` reports that it fits any
/// width, so the horizontal candidate always won and the vertical fallback was
/// unreachable. At accessibility sizes that produced a "Clear" button floating
/// beside the first word with six lines of sentence flowing underneath it.
/// The size class is asked directly instead — the same test `PeopleRoot` uses.
struct ActiveFilterSummary: View {
    let filter: SessionRecordingFilter
    var onClear: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    sentence
                    clearButton
                }
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    sentence
                    Spacer(minLength: Theme.Space.s)
                    clearButton
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Top-aligned against the first line rather than centred on the block:
    /// `Label` centres its icon, which floated it into the middle of a
    /// four-line sentence.
    private var sentence: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(filter.summarySentence)
                .font(.subheadline)
                .foregroundStyle(Theme.Ink.secondary)
                // Wraps rather than truncates: this is the explanation for a
                // short list, and half an explanation is not one. It is kept
                // short at the source instead — see `summarySentence`.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clearButton: some View {
        Button("Clear", action: onClear)
            .font(.subheadline.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .minimumHitTarget()
            .accessibilityLabel("Clear all session filters")
    }
}

extension SessionRecordingFilter {
    /// The active narrowings, in the order the sheet lists them.
    ///
    /// Capped at three named clauses with the rest counted. Rendered at
    /// accessibility sizes, the uncapped version ran to eight lines and pushed
    /// the first recording off the screen — the sentence exists to explain a
    /// short list, and it had become longer than the list.
    var summarySentence: String {
        var parts: [String] = []
        if filterTestAccounts { parts.append("excluding test users") }
        if let signal { parts.append(signal.title.lowercased()) }
        if dateWindow != .allTime { parts.append(dateWindow.title.lowercased()) }
        if let minimum = minimumDuration, minimum > 0 {
            // The metric is named because the two numbers differ by an order of
            // magnitude on the same recording.
            let measured = durationMetric == .active ? "active" : "long"
            let length = Duration.seconds(minimum)
                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            parts.append("\(length)+ \(measured)")
        }
        if source == .web { parts.append("playable only") }
        if let term = trimmedPersonSearch { parts.append("person “\(term)”") }
        if let term = trimmedURLSearch { parts.append("URL “\(term)”") }
        if !inheritedProperties.isEmpty {
            let count = inheritedProperties.count
            parts.append("\(count) saved clause\(count == 1 ? "" : "s")")
        }

        guard !parts.isEmpty else { return "Showing all sessions." }
        let named = parts.prefix(Self.namedSummaryClauses)
        let remainder = parts.count - named.count
        let tail = remainder > 0 ? " +\(remainder) more" : ""
        return "Showing " + named.joined(separator: " · ") + tail + "."
    }

    /// Three fits two lines at the largest non-accessibility size, measured.
    private static var namedSummaryClauses: Int { 3 }
}

struct SessionRowView: View {
    let recording: SessionRecording

    var body: some View {
        DataRow(
            glyph: glyph,
            brandGlyph: SessionBrandAppearance.glyph(
                hasErrors: recording.hasErrors,
                isReplayable: recording.isReplayable
            ),
            tint: tint,
            title: recording.personDisplayName,
            subtitle: recording.pathComponent,
            footnote: stats,
            // The start URL's path is an identifier, and a column of aligned
            // paths is what makes one session's entry point comparable to the
            // next one's.
            isSubtitleMonospaced: true,
            // Usually an email; wrapping stranded an orphan `m` on its own
            // line in the iPad sidebar. See `PersonRowView`.
            titleTruncatesMiddle: true,
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The glyph carries whatever is unusual about the session — errors first,
    /// then the mobile recordings this app cannot play — so the list can be
    /// triaged by shape before a name is read.
    private var glyph: String {
        if recording.hasErrors { return "exclamationmark.triangle.fill" }
        if !recording.isReplayable { return "iphone" }
        return "play.rectangle"
    }

    private var tint: Color {
        recording.hasErrors ? Theme.Status.critical : Theme.accent
    }

    /// Duration, activity and the caveats on the row's one caption line. The
    /// error count used to be a bare number behind a red triangle, so it says
    /// "errors" now; and the order puts what is worth acting on ahead of the
    /// timestamp, which is the part that gets truncated away first.
    private var stats: String {
        var parts = [recording.durationText, "\(recording.clickCount) clicks"]
        if recording.hasErrors { parts.append("\(recording.consoleErrorCount) errors") }
        // Set expectations in the list, not after a failed load.
        if !recording.isReplayable { parts.append("Mobile, not playable") }
        if let start = recording.startTime {
            parts.append(start.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var parts = [
            recording.personDisplayName,
            "duration \(recording.durationText)",
            "\(recording.clickCount) clicks",
        ]
        if recording.hasErrors { parts.append("\(recording.consoleErrorCount) console errors") }
        if !recording.isReplayable { parts.append("mobile recording, not playable") }
        return parts.joined(separator: ", ")
    }
}
