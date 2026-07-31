import GetHogKit
import SwiftUI

@MainActor
@Observable
final class EventsStore {
    var events: [EventRow] = []
    var isLoading = false
    var isPaging = false
    var failure: LoadFailure?
    var loadedAt: Date?
    var reachedEnd = false

    /// The rows exactly as `/query/` returned them, kept alongside the decoded
    /// `EventRow`s so the feed can be exported as what it actually is.
    ///
    /// **This costs very little, which is why it is worth doing rather than
    /// re-deriving.** `EventRow` already holds the row's `properties` value, and
    /// `JSONValue`'s payloads are copy-on-write, so keeping the positional array
    /// as well shares that storage instead of duplicating it — the addition is
    /// one array header per row. Re-deriving would have meant re-formatting
    /// timestamps back into text and inventing column names, so the export would
    /// have disagreed in small ways with the query that produced it. An export
    /// that disagrees with its source is the failure mode `InsightCSV` was
    /// written to avoid.
    private(set) var responseColumns: [String] = []
    private(set) var responseRows: [[JSONValue]] = []

    /// Owns the time bound and the keyset cursor. Every request the feed makes
    /// is bounded, because an unbounded one does not reliably finish — see
    /// `EventFeed.swift` for the measurements.
    private var pager = EventFeedPager()
    private let pageSize = 50

    /// The loaded page of the feed as CSV.
    ///
    /// Deliberately **what has been loaded**, not what matches the filter on the
    /// server. The feed is keyset-paged 50 rows at a time and the button sits
    /// above a list the reader can see the end of; an export that quietly went
    /// back and fetched everything would spend an unbounded, organisation-wide
    /// query budget on a tap that looks like it costs nothing. The row count in
    /// the menu says how much there is, and "Load older events" is how you get
    /// more into it.
    var export: CSVExport? {
        guard !responseRows.isEmpty else { return nil }
        return .query(title: "Events", columns: responseColumns, rows: responseRows)
    }

    /// How far back the feed has actually looked, so an empty screen can say so
    /// rather than implying it searched everything.
    var searchedDescription: String {
        let days = Int(pager.window / 86_400)
        if days >= 365 {
            let years = days / 365
            return years == 1 ? "year" : "\(years) years"
        }
        return days == 1 ? "day" : "\(days) days"
    }

    func reload(
        client: PostHogClient, projectID: Int, tokens: [EventFilterToken], search: String?
    ) async {
        pager.restart()
        events = []
        responseColumns = []
        responseRows = []
        reachedEnd = false
        isLoading = true
        defer { isLoading = false }

        // A window that came back empty is not evidence that the project has no
        // events, only that this window is thin — so widen and look again before
        // the screen is allowed to say there is nothing here.
        //
        // **Cost.** One request whenever the project has traffic in the last
        // week, which is the case this is tuned for; at worst one per rung of
        // `EventFeedPager.windows`, and only while the feed is still empty. Live
        // Tail restarts the pager on each tick, so a project with nothing in the
        // last week costs that worst case every 30s — the budget is
        // organisation-wide, and that is the price of not telling someone with
        // two years of events that they have none.
        repeat {
            guard await fetchPage(
                client: client, projectID: projectID, tokens: tokens, search: search
            ) else { return }
        } while events.isEmpty && !pager.isExhausted
    }

    func loadMore(
        client: PostHogClient, projectID: Int, tokens: [EventFilterToken], search: String?
    ) async {
        guard !isPaging, !isLoading, !reachedEnd else { return }
        isPaging = true
        defer { isPaging = false }

        // Keeps going until it has rows to show or the pager is finished, for
        // the same reason `reload` does: a page that came back empty *widened
        // the window* rather than declaring the end, and nothing schedules the
        // request that widening implies. The footer's `.task` fires once per
        // appearance, so a single fetch could leave the feed asking for more
        // and nobody asking again — which is precisely how the spinner outlived
        // the request that justified it.
        //
        // **Cost.** At worst one request per rung of `EventFeedPager.windows`,
        // and only while there is nothing to show for them; a page that returns
        // rows returns here immediately.
        repeat {
            let before = events.count
            guard await fetchPage(
                client: client, projectID: projectID, tokens: tokens, search: search
            ) else { return }
            if events.count > before { return }
        } while !pager.isExhausted
    }

    /// One page. Returns whether it succeeded, so `reload` stops widening after
    /// a failure instead of spending the shared budget on the same error.
    private func fetchPage(
        client: PostHogClient,
        projectID: Int,
        tokens: [EventFilterToken],
        search: String?
    ) async -> Bool {
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.events(
                    projectID: projectID,
                    limit: pageSize,
                    since: pager.floor(now: Date()),
                    before: pager.cursor,
                    tokens: tokens,
                    search: search
                )
            )
            let page = response.rows.compactMap(EventRow.init(row:))
            events.append(contentsOf: page)

            // Every page of this feed is the same SELECT, so the columns are
            // the same each time; taking the first non-empty set rather than
            // overwriting means a later page that came back with none — an
            // empty widening step — cannot blank the header of rows already
            // held.
            if responseColumns.isEmpty { responseColumns = response.columns }
            responseRows.append(contentsOf: response.rows.map(\.values))

            pager.advance(rowCount: page.count, limit: pageSize, cursor: response.eventCursor())
            reachedEnd = pager.isExhausted
            loadedAt = Date()
            failure = nil
            return true
        } catch {
            failure = LoadFailure(error, loading: "events")
            return false
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

    // MARK: - Rotors

    /// Every `$exception` in the feed, in the order it is drawn.
    ///
    /// Built from `buckets` rather than from `events` so the order matches what
    /// is on screen exactly: `buckets` is a partition, not a filter, and a rotor
    /// whose entries run in a different order than the list reads as the screen
    /// jumping about at random.
    var exceptionRows: [EventRow] {
        buckets.flatMap(\.events).filter { $0.event == "$exception" }
    }

    /// The events somebody on the product team instrumented themselves.
    ///
    /// The same distinction `EventAppearance.isCustom` draws for the row tint,
    /// and for the same stated reason: a feed that is mostly `$autocapture` and
    /// `$pageview` buries the handful of rows that were deliberately added. A
    /// tint answers that for a reader who can see the list; this answers it for
    /// one who is hearing it one row at a time.
    var customEventRows: [EventRow] {
        buckets.flatMap(\.events).filter { EventAppearance.isCustom($0.event) }
    }

    /// The first row of each time bucket, labelled with the bucket's own
    /// heading — so a rotor jump lands on a row rather than on a header, which
    /// is what a reader actually wants to be put next to.
    var bucketAnchors: [RotorAnchor] {
        buckets.compactMap { bucket in
            bucket.events.first.map { RotorAnchor(id: $0.id, label: bucket.title) }
        }
    }
}

extension View {

    /// The events feed's three rotors, as one named thing.
    ///
    /// Split out of `EventsRoot.list` so the declaration can be applied to a
    /// list of real `EventRowView`s in a test and read back off the rendered
    /// tree. Demo mode answers every `/query/` with the same five-row HogQL
    /// fixture — see `AccessibilityAuditTests`, which documents the same
    /// limitation from the other side — so the feed there has neither an
    /// exception nor more than one time bucket to jump between.
    func eventFeedRotors(
        exceptions: [EventRow],
        custom: [EventRow],
        periods: [RotorAnchor]
    ) -> some View {
        accessibilityRotor(
            Text("Errors"),
            entries: exceptions,
            entryID: \.id,
            entryLabel: \.rotorLabel
        )
        .accessibilityRotor(
            Text("Custom events"),
            entries: custom,
            entryID: \.id,
            entryLabel: \.rotorLabel
        )
        // The "by day" rotor, named for what this feed actually buckets by. Its
        // sections are relative — "Just now", "Earlier today" — not calendar
        // days, and a rotor called "Days" that jumps to "Last hour" would be
        // claiming a granularity the screen does not have.
        .accessibilityRotor(
            Text("Time periods"),
            entries: periods,
            entryLabel: \.label
        )
    }
}

extension EventRow {

    /// What a rotor speaks for this row.
    ///
    /// The name leads, because that is what the rotor selected on. The path or
    /// distinct id follows for the same reason `EventRowView` prints it: four
    /// consecutive `$autocapture` rows are otherwise indistinguishable, and a
    /// rotor that reads the same four words four times has not moved anywhere as
    /// far as the listener can tell.
    var rotorLabel: String {
        var parts = [event]
        if let url = currentURL, let path = URL(string: url)?.path, !path.isEmpty {
            parts.append(path)
        } else if let distinctID {
            parts.append(distinctID)
        }
        if let timestamp {
            parts.append(timestamp.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: ", ")
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
                    if let export = store.export {
                        ToolbarItem(placement: .topBarTrailing) {
                            CSVShareMenu(export: export)
                        }
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
        } else if let failure = store.failure, store.events.isEmpty {
            LoadFailureState(
                title: "Couldn't load events",
                failure: failure,
                retry: { Task { await reload() } }
            )
        } else if store.events.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.large)
            } else {
                EmptyStateView(
                    title: "No events",
                    systemImage: "bolt.slash",
                    message: emptyMessage
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
        } else if let failure = store.failure, store.events.isEmpty {
            LoadFailureState(
                title: "Couldn't load events",
                failure: failure,
                retry: { Task { await reload() } }
            )
        } else if store.events.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No events",
                systemImage: "bolt.slash",
                message: emptyMessage
            )
        } else {
            list
        }
    }

    /// Names the window that was actually searched.
    ///
    /// The feed now looks back a bounded distance per request, so a bare "No
    /// events" would assert something it never checked — the same overclaim as
    /// the scope message this release also removes. What the app knows is that
    /// it looked back this far and found nothing.
    private var emptyMessage: String {
        let searched = "Nothing in the last \(store.searchedDescription)."
        return tokens.isEmpty && search.isEmpty
            ? searched
            : searched + " Try a different filter."
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
                // A spinner only while a request is actually in flight.
                //
                // It used to spin whenever the feed had not reached its end,
                // which is not the same fact: the footer's `.task` runs once per
                // appearance, so the moment a page came back short the screen
                // held an animation over a request nobody was going to make. A
                // view that animates forever means the app never quiesces, and
                // XCUITest waits for quiescence on every launch and every query
                // — measured, the third consecutive launch on this tab ended the
                // run rather than failing an assertion.
                //
                // The button is not just somewhere to put the idle state. Scroll
                // position was the only thing that could ask for another page,
                // and scroll position is not something a VoiceOver or Full
                // Keyboard Access user has — so until now the feed's second page
                // was unreachable for them.
                HStack {
                    Spacer()
                    if store.isPaging {
                        ProgressView()
                    } else {
                        Button("Load older events") { Task { await loadMore() } }
                            .font(.footnote)
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .minimumHitTarget()
                    }
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
        // Three rotors, and each one is a question this feed already answers for
        // a reader who can see it and answered for nobody else.
        //
        // The feed's first page is 50 rows and it pages further; scrolling is
        // how a sighted reader skips the noise, and scroll position is not
        // something a VoiceOver user has — the same gap that made the "Load
        // older events" button necessary in the footer above.
        //
        // Every entry id is an `EventRow.id`, which is the identity the
        // `ForEach` above uses, so each entry resolves to a row on screen. The
        // entry lists are built from `buckets` rather than from `events` so
        // their order is the drawn order.
        .eventFeedRotors(
            exceptions: store.exceptionRows,
            custom: store.customEventRows,
            periods: store.bucketAnchors
        )
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
    /// `$autocapture / /s/nina-bruno / 10h ago`, indistinguishable from one
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
