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
                .searchable(
                    text: $search,
                    tokens: $tokens,
                    suggestedTokens: $suggestedTokens,
                    prompt: "Filter events"
                ) { token in
                    Label(token.displayText, systemImage: token.systemImage)
                }
                .onChange(of: search) { _, text in
                    suggestedTokens = EventFilterToken.suggestions(for: text)
                }
                .onSubmit(of: .search) { Task { await reload() } }
                .refreshable { await reload() }
                .task(id: filterSignature) {
                    AppTips.refresh(from: model)
                    await reload()
                }
                .onDisappear { liveTail.stop() }
        } detail: {
            if let selected {
                EventDetailView(event: selected)
            } else {
                ContentUnavailableView(
                    "Select an event",
                    systemImage: "bolt",
                    description: Text("Pick an event to inspect its properties.")
                )
            }
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
            ContentUnavailableView {
                Label("Couldn't load events", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Try again") { Task { await reload() } }
            }
        } else if store.events.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No events",
                systemImage: "bolt.slash",
                description: Text("No events matched. Try a different filter.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selected) {
            ForEach(store.buckets, id: \.title) { bucket in
                Section(bucket.title) {
                    ForEach(bucket.events) { event in
                        NavigationLink(value: event) { EventRowView(event: event) }
                    }
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
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
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

struct EventRowView: View {
    let event: EventRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                // PostHog's $-prefixed events read as code, so they're monospaced.
                Text(event.event)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                Spacer()
                if let ts = event.timestamp {
                    Text(ts, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if let url = event.currentURL, let path = URL(string: url)?.path, !path.isEmpty {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let distinctID = event.distinctID {
                Text(distinctID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
