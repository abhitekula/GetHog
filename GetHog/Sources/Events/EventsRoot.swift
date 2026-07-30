import GetHogKit
import SwiftUI

@MainActor
@Observable
final class EventsStore {
    var events: [EventRow] = []
    var isLoading = false
    var isPaging = false
    var error: String?
    var loadedAt: Date?
    var reachedEnd = false

    private var cursor: Date?
    private let pageSize = 50

    func reload(
        client: PostHogClient, projectID: Int, tokens: [EventFilterToken], search: String?
    ) async {
        cursor = nil
        reachedEnd = false
        events = []
        await fetch(
            client: client, projectID: projectID, tokens: tokens, search: search, replacing: true
        )
    }

    func loadMore(
        client: PostHogClient, projectID: Int, tokens: [EventFilterToken], search: String?
    ) async {
        guard !isPaging, !reachedEnd, cursor != nil else { return }
        await fetch(
            client: client, projectID: projectID, tokens: tokens, search: search, replacing: false
        )
    }

    private func fetch(
        client: PostHogClient,
        projectID: Int,
        tokens: [EventFilterToken],
        search: String?,
        replacing: Bool
    ) async {
        if replacing { isLoading = true } else { isPaging = true }
        defer { isLoading = false; isPaging = false }

        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.events(
                    projectID: projectID,
                    limit: pageSize,
                    before: cursor,
                    tokens: tokens,
                    search: search
                )
            )
            let page = response.rows.compactMap(EventRow.init(row:))

            if replacing { events = page } else { events.append(contentsOf: page) }

            // Keyset paging: PostHog rejects OFFSET for personal API keys.
            cursor = response.keysetCursor(column: "timestamp")
            reachedEnd = page.count < pageSize
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Groups into human time buckets rather than raw timestamps.
    var buckets: [(title: String, events: [EventRow])] {
        let now = Date()
        var justNow: [EventRow] = [], lastHour: [EventRow] = []
        var today: [EventRow] = [], earlier: [EventRow] = []

        for event in events {
            guard let ts = event.timestamp else { earlier.append(event); continue }
            let age = now.timeIntervalSince(ts)
            if age < 300 { justNow.append(event) }
            else if age < 3600 { lastHour.append(event) }
            else if Calendar.current.isDateInToday(ts) { today.append(event) }
            else { earlier.append(event) }
        }

        return [
            ("Just now", justNow), ("Last hour", lastHour),
            ("Earlier today", today), ("Earlier", earlier),
        ].filter { !$0.1.isEmpty }
    }
}

struct EventsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = EventsStore()
    @State private var search = ""
    @State private var tokens: [EventFilterToken] = []
    @State private var suggestedTokens: [EventFilterToken] = []
    @State private var selected: EventRow?
    @State private var liveTail = LiveTailController()

    /// Committed filters reload immediately; free text waits for submit, because
    /// one request per keystroke would spend a budget shared with the whole
    /// organisation.
    private var filterSignature: String {
        "\(model.projectID ?? 0)|" + tokens.map(\.id).joined(separator: ",")
    }

    var body: some View {
        NavigationSplitView {
            content
                .navigationTitle("Events")
                .toolbar {
                    ProjectSwitcher()
                    ToolbarItem(placement: .topBarTrailing) {
                        SavedFiltersMenu(projectID: model.projectID, tokens: $tokens)
                    }
                    ToolbarItem(placement: .topBarTrailing) { liveTailButton }
                }
                .projectSubtitle()
                // Placement is pinned rather than left to `.automatic`. Measured
                // on iPad: with the placement automatic the field was not drawn
                // at all in the list column — the list was short enough to fit
                // without scrolling, so it was absent rather than scrolled off —
                // while the iPhone drew it normally. The drawer is where the
                // field belongs at both widths, and `.always` keeps a *filter*
                // visible, which is the point of one.
                .searchable(
                    text: $search,
                    tokens: $tokens,
                    suggestedTokens: $suggestedTokens,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Filter events"
                ) { token in
                    Label(token.displayText, systemImage: token.systemImage)
                }
                .onChange(of: search) { _, text in
                    suggestedTokens = EventFilterToken.suggestions(for: text)
                }
                // A term an intent asked this screen to filter by, typed in
                // rather than dropped on the floor.
                .onAppear {
                    if let term = LinkInbox.consumeQuery(for: .events) { search = term }
                }
                .onSubmit(of: .search) { Task { await reload() } }
                .refreshable { await reload() }
                .task(id: filterSignature) {
                    AppTips.refresh(from: model)
                    await reload()
                }
                .onDisappear { liveTail.stop() }
                // Sized to the monospaced line under the event name, which is a
                // path or a distinct id — and a distinct id is a 36-character
                // UUID, ~300pt set monospaced. At the ~320pt the column took by
                // default that left the row identifying nothing.
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420)
                // The tab sidebar already puts a toggle in this bar; the split
                // view added a second, identical one beside it.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
        }
    }

    /// The detail column: the chosen event, or a summary of the feed when nothing
    /// is chosen yet.
    ///
    /// The no-selection branch mirrors the list's own states rather than summarising thin air: a locked
    /// key and a filter that matches nothing are both normal outcomes, and a
    /// grid of zeroes would misreport either one.
    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            EventDetailView(event: selected)
        } else if !model.isAvailable(.events) {
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.events.isEmpty {
            EmptyStateView(
                title: "Couldn't load events",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await reload() } }
            )
        } else if store.events.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.large)
            } else {
                EmptyStateView(
                    title: "No events",
                    systemImage: "bolt.slash",
                    message: "No events matched. Try a different filter."
                )
            }
        } else {
            EventsOverview(events: store.events, loadedAt: store.loadedAt)
        }
    }

    /// Live Tail is explicit and self-limiting: no hidden polling, no fake pulse
    /// indicator, and it draws from the same visible rate-limit budget.
    private var liveTailButton: some View {
        Button {
            if liveTail.isRunning {
                liveTail.stop()
            } else {
                liveTail.start { await reload() }
            }
        } label: {
            if liveTail.isRunning {
                Label("\(liveTail.secondsRemaining)s", systemImage: "stop.circle.fill")
                    .font(.caption.monospacedDigit())
            } else {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .accessibilityLabel(liveTail.isRunning ? "Stop live tail" : "Start live tail for five minutes")
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.events.isEmpty {
            EmptyStateView(
                title: "Couldn't load events",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await reload() } }
            )
        } else if store.events.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No events",
                systemImage: "bolt.slash",
                message: "No events matched. Try a different filter."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selected) {
            ForEach(store.buckets, id: \.title) { bucket in
                Section {
                    ForEach(bucket.events) { event in
                        NavigationLink(value: event) { EventRowView(event: event) }
                            .listRowBackground(
                                Theme.cardBackground
                                    .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                    .padding(.vertical, 1)
                            )
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    SectionLabel(text: bucket.title, systemImage: "clock")
                }
            }

            if !store.reachedEnd {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .task { await loadMore() }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.events.isEmpty)
    }

    private func reload() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.reload(
            client: client,
            projectID: projectID,
            tokens: tokens,
            search: search.isEmpty ? nil : search
        )
    }

    private func loadMore() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadMore(
            client: client,
            projectID: projectID,
            tokens: tokens,
            search: search.isEmpty ? nil : search
        )
    }
}

/// Shape and colour for an event, keyed by its name.
///
/// Lifted out of `EventRowView` so the feed and the overview beside it agree.
/// On iPad the two are on screen at once, and the same event drawn as two
/// different glyphs in adjacent columns reads as two different things.
enum EventAppearance {

    /// Anything without PostHog's `$` prefix was instrumented by the product
    /// team, which is usually what someone is scanning a feed for.
    static func isCustom(_ name: String) -> Bool { !name.hasPrefix("$") }

    /// Says what *kind* of event a row is before the name is read.
    static func glyph(for name: String) -> String {
        switch name {
        case "$pageview", "$screen": "doc.richtext"
        case "$pageleave": "rectangle.portrait.and.arrow.right"
        case "$autocapture": "hand.tap"
        case "$rageclick": "hand.tap.fill"
        case "$exception": "exclamationmark.triangle.fill"
        case "$identify", "$set": "person.crop.circle"
        default: isCustom(name) ? "bolt.fill" : "bolt"
        }
    }

    /// Custom events take the warm secondary and PostHog's own autocapture
    /// recedes to the app accent, so a feed that is mostly `$autocapture` does
    /// not bury the handful of rows somebody deliberately instrumented.
    static func tint(for name: String) -> Color {
        if name == "$exception" { return Theme.Status.critical }
        return isCustom(name) ? Theme.accentWarm : Theme.accent
    }
}

struct EventRowView: View {
    let event: EventRow

    var body: some View {
        DataRow(
            glyph: EventAppearance.glyph(for: event.event),
            tint: EventAppearance.tint(for: event.event),
            title: event.event,
            subtitle: subtitle,
            footnote: footnote,
            // The event name leads the row as its title now. The identifier
            // beneath it — a URL path or a distinct id — is what stays
            // monospaced, since that is the column being compared downwards.
            isSubtitleMonospaced: true,
            // Two lines, against the one-line default. A feed is mostly repeats
            // of `$pageview` and `$autocapture`, so the title is shared and the
            // path or distinct id underneath is the only thing separating one
            // row from the next — the same failure the error list had, where a
            // narrow column cut exactly the distinguishing part.
            subtitleLineLimit: 2,
            accessory: .none
        )
    }

    private var subtitle: String? {
        if let url = event.currentURL, let path = URL(string: url)?.path, !path.isEmpty {
            return path
        }
        return event.distinctID
    }

    /// A clock time, not a relative one.
    ///
    /// Measured on iPhone: four consecutive rows read
    /// `$autocapture / /s/tara-zubin / 10h ago`, indistinguishable from one
    /// another, because a relative stamp rounds to the hour and these events
    /// arrived seconds apart. The section header above already gives the rough
    /// when — "Just now", "Earlier today" — so the row's remaining job is to
    /// separate one event from the next, and only a real time does that.
    private var footnote: String? {
        guard let timestamp = event.timestamp else { return nil }
        return Calendar.current.isDateInToday(timestamp)
            ? timestamp.formatted(date: .omitted, time: .standard)
            : timestamp.formatted(date: .abbreviated, time: .standard)
    }
}

/// Bounded auto-refresh: 30s cadence, stops itself after five minutes.
@MainActor
@Observable
final class LiveTailController {
    private(set) var isRunning = false
    private(set) var secondsRemaining = 0
    private var task: Task<Void, Never>?

    private let interval = 30
    private let maxDuration = 300

    func start(_ refresh: @escaping @Sendable () async -> Void) {
        stop()
        isRunning = true
        secondsRemaining = maxDuration

        // The task inherits this type's main-actor isolation, so state reads and
        // writes below need no hops.
        task = Task { [weak self] in
            while let self, self.isRunning, self.secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await refresh()
                self.secondsRemaining = max(0, self.secondsRemaining - self.interval)
                if self.secondsRemaining == 0 { self.stop() }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        secondsRemaining = 0
    }
}
