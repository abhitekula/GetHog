import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// Serves recordings from a fixed pool, honouring `limit`/`offset` and
/// recording every URL it was asked for.
///
/// A stub rather than `DemoTransport` for the same reason the insights library
/// uses one: the demo answers every `/session_recordings/` path with the same
/// five-row fixture regardless of filter or offset, which is precisely the
/// pathological case the store has to survive and therefore cannot be the thing
/// that proves it pages and re-filters correctly.
private actor RecordingsTransport: HTTPTransport {
    private let total: Int
    /// Rewinds every page after the first by this many rows, which is what a
    /// recording landing between two pages does to offset paging over a
    /// time-ordered table: the next page repeats rows the last one already had.
    private let overlap: Int
    /// Held open until released, so a response can be made to arrive *after*
    /// the filter it belonged to has already been replaced.
    private let gate: AsyncStream<Void>.Continuation?
    private let gateStream: AsyncStream<Void>?
    private(set) var requestedURLs: [URL] = []

    init(total: Int, overlap: Int = 0, gated: Bool = false) {
        self.total = total
        self.overlap = overlap
        if gated {
            var continuation: AsyncStream<Void>.Continuation?
            let stream = AsyncStream<Void> { continuation = $0 }
            self.gate = continuation
            self.gateStream = stream
        } else {
            self.gate = nil
            self.gateStream = nil
        }
    }

    func release() { gate?.finish() }

    func urls() -> [URL] { requestedURLs }

    /// Query items of the nth request, for asserting what was actually sent.
    func items(_ index: Int) -> [String: String] {
        guard requestedURLs.indices.contains(index),
              let components = URLComponents(url: requestedURLs[index], resolvingAgainstBaseURL: false)
        else { return [:] }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a }
        )
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requestedURLs.append(url)

        if let gateStream {
            for await _ in gateStream {}
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let limit = value("limit").flatMap(Int.init) ?? 50
        let asked = value("offset").flatMap(Int.init) ?? 0
        let offset = asked == 0 ? 0 : max(asked - overlap, 0)

        // A filtered request answers with a disjoint id space, so a page from
        // the old filter is recognisable if it ever lands in the new results.
        let filtered = value("events") != nil || value("having_predicates") != nil
        let prefix = filtered ? "f" : "u"

        let ids = Array(1...max(total, 1)).dropFirst(offset).prefix(limit)
        let rows = ids.map { index in
            """
            {"id": "\(prefix)-\(index)", "distinct_id": "d\(index)",
             "recording_duration": \(index * 10), "active_seconds": \(index),
             "start_time": "2026-01-15T10:00:00Z",
             "click_count": \(index), "keypress_count": 0,
             "console_log_count": 0, "console_warn_count": 0,
             "console_error_count": 0, "snapshot_source": "web",
             "ongoing": false, "viewed": false}
            """
        }
        let body = """
        {"results": [\(rows.joined(separator: ","))],
         "has_next": \(offset + ids.count < total), "version": 4}
        """
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private func client(
    _ transport: some HTTPTransport,
    region: PostHogRegion = .usCloud
) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_test", region: region),
        transport: transport
    )
}

@Suite("Sessions filtering")
@MainActor
struct SessionsFilterScreenTests {

    private func sessionPreferences(_ name: String = #function) -> SessionsPreferences {
        let suite = "SessionsFilterScreenTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SessionsPreferences(defaults: defaults)
    }

    private func sessionsStore(_ name: String = #function) -> SessionsStore {
        SessionsStore(preferences: sessionPreferences(name))
    }

    // MARK: - What actually goes on the wire

    @Test("an unfiltered load asks for exactly what it always did")
    func unfilteredRequestIsUnchanged() async throws {
        let transport = RecordingsTransport(total: 10)
        let store = sessionsStore()
        await store.load(client: client(transport), projectID: 1)

        let items = await transport.items(0)
        #expect(items["limit"] == "50")
        #expect(items["offset"] == "0")
        #expect(items.count == 2)
    }

    @Test("the filter reaches the wire rather than being applied after the page lands")
    func filterIsSentToTheServer() async throws {
        let transport = RecordingsTransport(total: 10)
        let store = sessionsStore()
        store.activate(scope: ProjectPreferenceScope(projectID: 1, region: .usCloud))
        store.filter.signal = .rageClick
        store.filter.minimumDuration = 60
        store.filter.dateWindow = .last7Days
        store.filter.filterTestAccounts = true
        await store.load(client: client(transport), projectID: 1)

        let items = await transport.items(0)
        #expect(items["date_from"] == "-7d")
        #expect(items["events"]?.contains("$rageclick") == true)
        #expect(items["having_predicates"]?.contains("\"duration\"") == true)
        #expect(items["filter_test_accounts"] == "true")
    }

    @Test("stored choices are active before the destination request is constructed")
    func restoresBeforeRequest() async {
        let preferences = sessionPreferences()
        let scope = ProjectPreferenceScope(projectID: 77, region: .euCloud)
        preferences.set(
            .init(filterTestAccounts: true, playableOnly: true, order: .clickCount),
            for: scope
        )
        let transport = RecordingsTransport(total: 2)
        let store = SessionsStore(preferences: preferences)

        await store.load(client: client(transport, region: .euCloud), projectID: 77)

        let items = await transport.items(0)
        #expect(items["filter_test_accounts"] == "true")
        #expect(items["having_predicates"]?.contains("snapshot_source") == true)
        #expect(items["order"] == "click_count")
    }

    @Test("a project switch clears transient investigation state and applies only destination choices")
    func projectSwitchResetsTransientState() async {
        let preferences = sessionPreferences()
        let first = ProjectPreferenceScope(projectID: 1, region: .usCloud)
        let second = ProjectPreferenceScope(projectID: 2, region: .usCloud)
        preferences.set(.init(playableOnly: true, order: .duration), for: second)
        let store = SessionsStore(preferences: preferences)

        await store.load(client: client(RecordingsTransport(total: 1)), projectID: first.projectID)
        store.filter.personSearch = "synthetic@example.com"
        store.filter.signal = .exception
        store.filter.minimumDuration = 120
        store.filter.filterTestAccounts = true

        await store.load(client: client(RecordingsTransport(total: 1)), projectID: second.projectID)

        #expect(store.filter.personSearch == nil)
        #expect(store.filter.signal == nil)
        #expect(store.filter.minimumDuration == nil)
        #expect(!store.filter.filterTestAccounts)
        #expect(store.filter.source == .web)
        #expect(store.filter.order == .duration)
    }

    @Test("the same numeric project on another host has independent state and rejects the old response")
    func hostSwitchIsADataBoundary() async {
        let preferences = sessionPreferences()
        let eu = ProjectPreferenceScope(projectID: 77, region: .euCloud)
        preferences.set(.init(filterTestAccounts: true), for: eu)
        let store = SessionsStore(preferences: preferences)
        let heldUS = RecordingsTransport(total: 9, gated: true)
        let slow = Task {
            await store.load(client: client(heldUS, region: .usCloud), projectID: 77)
        }
        while await heldUS.urls().isEmpty { await Task.yield() }

        await store.load(
            client: client(RecordingsTransport(total: 3), region: .euCloud),
            projectID: 77
        )
        await heldUS.release()
        await slow.value

        #expect(store.recordings.count == 3)
        #expect(store.filter.filterTestAccounts)
    }

    @Test("durable edits and a saved-filter replacement update only the active scope")
    func writesDurableProjection() async {
        let preferences = sessionPreferences()
        let scope = ProjectPreferenceScope(projectID: 8, region: .usCloud)
        let store = SessionsStore(preferences: preferences)
        await store.load(client: client(RecordingsTransport(total: 1)), projectID: 8)

        store.filter.personSearch = "memory-only@example.com"
        #expect(preferences.value(for: scope) == .init())

        store.filter.filterTestAccounts = true
        #expect(preferences.value(for: scope).filterTestAccounts)
        store.filter.source = .web
        #expect(preferences.value(for: scope).playableOnly)
        store.filter.order = .clickCount
        #expect(preferences.value(for: scope).order == .clickCount)

        var saved = SessionRecordingFilter()
        saved.filterTestAccounts = true
        saved.source = .web
        saved.order = .activityScore
        saved.signal = .rageClick
        store.replaceFilter(saved)

        #expect(preferences.value(for: scope) == .init(
            filterTestAccounts: true,
            playableOnly: true,
            order: .activityScore
        ))
        #expect(store.filter.signal == .rageClick)
    }

    @Test("clearing removes every constraint and stored narrowing but preserves sort")
    func clearPreservesSort() async {
        let preferences = sessionPreferences()
        let scope = ProjectPreferenceScope(projectID: 77, region: .usCloud)
        let store = SessionsStore(preferences: preferences)
        await store.load(client: client(RecordingsTransport(total: 1)), projectID: 77)
        var filter = SessionRecordingFilter()
        filter.filterTestAccounts = true
        filter.source = .web
        filter.order = .consoleErrorCount
        filter.urlSearch = "example.com/dashboard"
        filter.inheritedProperties = [
            .init(key: "plan", type: "person", value: .string("synthetic"), op: "exact"),
        ]
        store.replaceFilter(filter)

        store.clearFilters()

        #expect(!store.filter.isNarrowed)
        #expect(store.filter.order == .consoleErrorCount)
        #expect(preferences.value(for: scope) == .init(order: .consoleErrorCount))
    }

    // MARK: - Replace, never append

    @Test("changing the filter replaces the list instead of extending it")
    func filterChangeReplaces() async throws {
        let transport = RecordingsTransport(total: 200)
        let store = sessionsStore()

        await store.load(client: client(transport), projectID: 1)
        await store.loadMore(client: client(transport), projectID: 1)
        #expect(store.recordings.count == 100)
        #expect(store.recordings.allSatisfy { $0.id.hasPrefix("u-") })

        store.filter.signal = .rageClick
        await store.load(client: client(transport), projectID: 1)

        // The whole list is from the new filter, and paging restarted at zero.
        #expect(store.recordings.count == 50)
        #expect(store.recordings.allSatisfy { $0.id.hasPrefix("f-") })
        let items = await transport.items(2)
        #expect(items["offset"] == "0")
    }

    @Test("loading more appends the next page and asks for the right offset")
    func loadMoreAppends() async throws {
        let transport = RecordingsTransport(total: 120)
        let store = sessionsStore()

        await store.load(client: client(transport), projectID: 1)
        #expect(store.recordings.count == 50)
        #expect(store.hasMore)

        await store.loadMore(client: client(transport), projectID: 1)
        #expect(store.recordings.count == 100)
        #expect(await transport.items(1)["offset"] == "50")

        await store.loadMore(client: client(transport), projectID: 1)
        #expect(store.recordings.count == 120)
        #expect(!store.hasMore)
    }

    @Test("a row repeated across two pages is not shown twice")
    func loadMoreDeduplicates() async throws {
        // The second page rewinds ten rows, so ten ids arrive that the list
        // already holds — what happens when a recording lands mid-scroll.
        let transport = RecordingsTransport(total: 200, overlap: 10)
        let store = sessionsStore()
        await store.load(client: client(transport), projectID: 1)
        await store.loadMore(client: client(transport), projectID: 1)

        #expect(Set(store.recordings.map(\.id)).count == store.recordings.count)
        #expect(store.recordings.count == 90)
    }

    @Test("a page still in flight when the filter changes cannot land in the new results")
    func staleResponseIsDiscarded() async throws {
        let gated = RecordingsTransport(total: 200, gated: true)
        let store = sessionsStore()

        // A slow load for the unfiltered list, held open at the transport...
        let slow = Task { await store.load(client: client(gated), projectID: 1) }
        while await gated.urls().isEmpty { await Task.yield() }

        // ...overtaken by a fast one for a narrower filter.
        store.filter.signal = .rageClick
        let fast = RecordingsTransport(total: 5)
        await store.load(client: client(fast), projectID: 1)
        await gated.release()
        await slow.value

        #expect(store.recordings.count == 5)
        #expect(store.recordings.allSatisfy { $0.id.hasPrefix("f-") })
        #expect(!store.isLoading)
    }

    @Test("a replacement releases stale paging state and the new results can page")
    func replacementClearsHeldPagingState() async {
        let store = sessionsStore()
        await store.load(client: client(RecordingsTransport(total: 200)), projectID: 1)

        // Hold page two of the old filter after it has claimed the paging flag.
        let heldPage = RecordingsTransport(total: 200, gated: true)
        let stale = Task {
            await store.loadMore(client: client(heldPage), projectID: 1)
        }
        while await heldPage.urls().isEmpty { await Task.yield() }
        #expect(store.isLoadingMore)

        // A same-project replacement owns paging now. The stale request cannot
        // append, and must not leave its in-flight bit blocking the new page.
        store.filter.signal = .rageClick
        let replacement = RecordingsTransport(total: 120, gated: true)
        let replacing = Task {
            await store.load(client: client(replacement), projectID: 1)
        }
        while await replacement.urls().isEmpty { await Task.yield() }
        #expect(!store.isLoadingMore)
        #expect(store.isLoading)

        await replacement.release()
        await replacing.value

        await store.loadMore(client: client(replacement), projectID: 1)
        #expect(store.recordings.count == 100)
        #expect(await replacement.items(1)["offset"] == "50")

        await heldPage.release()
        await stale.value
        #expect(store.recordings.count == 100)
        #expect(store.recordings.allSatisfy { $0.id.hasPrefix("f-") })
    }

    @Test("mismatched paging cannot take ownership from a held first-page load")
    func mismatchedLoadMorePreservesHeldFirstPageOwner() async {
        let scope = ProjectPreferenceScope(projectID: 77, region: .usCloud)
        let store = sessionsStore()
        store.activate(scope: scope)
        store.filter.personSearch = "held-first-page@example.com"
        store.filter.signal = .rageClick
        let expectedSignature = store.requestSignature

        let heldFirstPage = RecordingsTransport(total: 3, gated: true)
        let loading = Task {
            await store.load(client: client(heldFirstPage), projectID: scope.projectID)
        }
        while await heldFirstPage.urls().isEmpty { await Task.yield() }
        #expect(store.isLoading)

        let mismatched = RecordingsTransport(total: 100)
        await store.loadMore(
            client: client(mismatched, region: .euCloud),
            projectID: scope.projectID
        )

        #expect(await mismatched.urls().isEmpty)
        #expect(store.filter.personSearch == "held-first-page@example.com")
        #expect(store.filter.signal == .rageClick)
        #expect(store.requestSignature == expectedSignature)
        #expect(store.requestSignature(for: scope) == expectedSignature)
        #expect(store.isLoading)
        #expect(!store.isLoadingMore)

        await heldFirstPage.release()
        await loading.value

        #expect(store.recordings.count == 3)
        #expect(store.requestSignature == expectedSignature)
        #expect(!store.isLoading)
        #expect(!store.isLoadingMore)
    }

    @Test("mismatched paging cannot take ownership from a held same-scope page")
    func mismatchedLoadMorePreservesHeldPageOwner() async {
        let scope = ProjectPreferenceScope(projectID: 77, region: .usCloud)
        let store = sessionsStore()
        await store.load(
            client: client(RecordingsTransport(total: 120)),
            projectID: scope.projectID
        )
        store.filter.urlSearch = "example.com/held-page"
        let expectedSignature = store.requestSignature

        let heldPage = RecordingsTransport(total: 120, gated: true)
        let paging = Task {
            await store.loadMore(client: client(heldPage), projectID: scope.projectID)
        }
        while await heldPage.urls().isEmpty { await Task.yield() }
        #expect(store.isLoadingMore)

        let mismatched = RecordingsTransport(total: 100)
        await store.loadMore(client: client(mismatched), projectID: 42)

        #expect(await mismatched.urls().isEmpty)
        #expect(store.filter.urlSearch == "example.com/held-page")
        #expect(store.requestSignature == expectedSignature)
        #expect(store.requestSignature(for: scope) == expectedSignature)
        #expect(!store.isLoading)
        #expect(store.isLoadingMore)

        await heldPage.release()
        await paging.value

        #expect(store.recordings.count == 100)
        #expect(store.requestSignature == expectedSignature)
        #expect(!store.isLoading)
        #expect(!store.isLoadingMore)
    }

    @Test("switching projects clears old recordings before the replacement arrives")
    func projectSwitchClearsRowsSynchronously() async {
        let store = sessionsStore()
        await store.load(client: client(RecordingsTransport(total: 10)), projectID: 1)
        #expect(store.recordings.count == 10)

        let gated = RecordingsTransport(total: 5, gated: true)
        let replacement = Task {
            await store.load(client: client(gated), projectID: 2)
        }
        while await gated.urls().isEmpty { await Task.yield() }

        #expect(store.recordings.isEmpty)
        #expect(!store.hasMore)
        await gated.release()
        await replacement.value
        #expect(store.recordings.count == 5)
    }

    @Test("loading more never runs against a filter that has since changed")
    func loadMoreIsGated() async throws {
        let transport = RecordingsTransport(total: 200)
        let store = sessionsStore()
        await store.load(client: client(transport), projectID: 1)

        store.filter.dateWindow = .last24Hours
        await store.load(client: client(transport), projectID: 1)
        await store.loadMore(client: client(transport), projectID: 1)

        // Every request after the filter changed carried the new window.
        let last = await transport.items(2)
        #expect(last["date_from"] == "-24h")
        #expect(store.recordings.count == 100)
    }

    // MARK: - Failure

    @Test("a failed narrowing clears the previous filter's rows rather than leaving them as the answer")
    func failureClearsStaleRows() async throws {
        let good = RecordingsTransport(total: 10)
        let store = sessionsStore()
        await store.load(client: client(good), projectID: 1)
        #expect(!store.recordings.isEmpty)

        store.filter.signal = .exception
        await store.load(client: client(FailingTransport()), projectID: 1)
        #expect(store.recordings.isEmpty)
        #expect(store.error != nil)
        #expect(!store.hasMore)
    }

    @Test("a same-filter refresh failure preserves rows and remains retryable inline")
    func refreshFailurePreservesRows() async {
        let transport = RefreshFailureTransport()
        let store = sessionsStore()

        await store.load(client: client(transport), projectID: 1)
        let firstPageIDs = store.recordings.map(\.id)
        #expect(firstPageIDs.count == 50)
        #expect(store.hasMore)

        await store.load(client: client(transport), projectID: 1)

        #expect(store.recordings.map(\.id) == firstPageIDs)
        #expect(store.hasMore)
        #expect(store.error?.contains("Synthetic sessions refresh failed") == true)
        #expect(
            SessionsRefreshPresentation.resolve(
                recordingCount: store.recordings.count,
                error: store.error
            ) == SessionsRefreshPresentation(
                message: "Couldn't refresh sessions. Couldn't reach PostHog: Synthetic sessions refresh failed",
                actionTitle: "Try again"
            )
        )

        await store.load(client: client(transport), projectID: 1)

        #expect(store.recordings.map(\.id) == firstPageIDs)
        #expect(store.error == nil)
        #expect(
            SessionsRefreshPresentation.resolve(
                recordingCount: store.recordings.count,
                error: store.error
            ) == nil
        )
    }

    @Test("a failed next page preserves rows and remains retryable inline")
    func nextPageFailurePreservesRowsAndRetry() async {
        let transport = PagingRecoveryTransport()
        let store = sessionsStore()

        await store.load(client: client(transport), projectID: 1)
        let firstPageIDs = store.recordings.map(\.id)
        #expect(firstPageIDs.count == 50)
        #expect(store.hasMore)

        await store.loadMore(client: client(transport), projectID: 1)

        #expect(store.recordings.map(\.id) == firstPageIDs)
        #expect(store.hasMore)
        #expect(store.pagingError != nil)

        await store.loadMore(client: client(transport), projectID: 1)

        #expect(store.recordings.count == 100)
        #expect(Set(store.recordings.map(\.id)).count == 100)
        #expect(store.pagingError == nil)
    }

    // MARK: - The request signature that drives the debounce

    @Test("the signature changes with the filter and is stable when it does not")
    func requestSignature() {
        let store = sessionsStore()
        let empty = store.requestSignature
        store.filter.dateWindow = .last7Days
        #expect(store.requestSignature != empty)
        let narrowed = store.requestSignature
        // Sort order changes the request, so it must change the signature too —
        // otherwise picking a different sort would not reload.
        store.filter.order = .consoleErrorCount
        #expect(store.requestSignature != narrowed)
        store.filter.order = .startTime
        #expect(store.requestSignature == narrowed)

        let testAccountsStore = sessionsStore()
        let includesTestUsers = testAccountsStore.requestSignature
        testAccountsStore.filter.filterTestAccounts = true
        #expect(testAccountsStore.requestSignature != includesTestUsers)
    }

    @Test("a canonical-equivalent scope keeps transient fields in the request signature")
    func canonicalEquivalentScopeKeepsTransientSignature() {
        let active = ProjectPreferenceScope(projectID: 77, region: .usCloud)
        let equivalent = ProjectPreferenceScope(
            projectID: 77,
            region: .selfHosted(PostHogRegion.usCloud.host)
        )
        let store = sessionsStore()
        store.activate(scope: active)
        store.filter.personSearch = "signature@example.com"
        store.filter.signal = .exception

        let current = store.requestSignature
        #expect(current.contains("signature@example.com"))
        #expect(current.contains("$exception"))
        #expect(store.requestSignature(for: equivalent) == current)
    }

    // MARK: - What the list says about itself

    @Test("the summary names every active narrowing")
    func summarySentence() {
        var filter = SessionRecordingFilter()
        #expect(filter.summarySentence == "Showing all sessions.")

        var testUsers = SessionRecordingFilter()
        testUsers.filterTestAccounts = true
        #expect(testUsers.summarySentence == "Showing excluding test users.")

        filter.signal = .rageClick
        filter.dateWindow = .last7Days
        filter.minimumDuration = 120
        filter.source = .web
        filter.personSearch = "nina"

        // Three named, the rest counted: rendered uncapped at accessibility
        // sizes this ran to eight lines and pushed the first recording off the
        // screen — longer than the list it was explaining.
        let sentence = filter.summarySentence
        #expect(sentence.contains("rage clicks"))
        #expect(sentence.contains("last 7 days"))
        #expect(sentence.hasSuffix("+2 more."))
        #expect(!sentence.contains("nina"))

        // The metric is named, because "2 min" is ambiguous between two numbers
        // that differ by an order of magnitude on the same recording.
        var short = SessionRecordingFilter()
        short.minimumDuration = 120
        #expect(short.summarySentence.contains("long"))
        short.durationMetric = .active
        #expect(short.summarySentence.contains("active"))

        // Under the cap, nothing is elided.
        var two = SessionRecordingFilter()
        two.signal = .exception
        two.dateWindow = .last24Hours
        #expect(two.summarySentence == "Showing exceptions · last 24 hours.")
    }
}

private struct FailingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PostHogError.transport("The network connection was lost.")
    }
}

/// The first page succeeds, the next same-filter refresh fails, and retrying
/// that exact request succeeds. Every row and message is synthetic.
private actor RefreshFailureTransport: HTTPTransport {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 2 {
            throw PostHogError.transport("Synthetic sessions refresh failed")
        }

        let rows = (1...50).map { index in
            """
            {"id":"synthetic-refresh-session-\(index)","distinct_id":"synthetic-refresh-person-\(index)",
             "recording_duration":120,"active_seconds":60,
             "start_time":"2026-01-15T10:00:00Z","click_count":1,
             "keypress_count":0,"console_log_count":0,"console_warn_count":0,
             "console_error_count":0,"snapshot_source":"web",
             "ongoing":false,"viewed":false}
            """
        }
        let body = """
        {"results":[\(rows.joined(separator: ","))],"has_next":true,"version":4}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// First page succeeds, the first attempt at page two fails, and retrying the
/// same offset succeeds. Every identifier and response is synthetic.
private actor PagingRecoveryTransport: HTTPTransport {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 2 {
            throw PostHogError.transport("Synthetic page-two interruption")
        }

        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let offset = components?.queryItems?
            .first(where: { $0.name == "offset" })?
            .value
            .flatMap(Int.init) ?? 0
        let rows = (offset + 1...offset + 50).map { index in
            """
            {"id":"synthetic-session-\(index)","distinct_id":"synthetic-person-\(index)",
             "recording_duration":120,"active_seconds":60,
             "start_time":"2026-01-15T10:00:00Z","click_count":1,
             "keypress_count":0,"console_log_count":0,"console_warn_count":0,
             "console_error_count":0,"snapshot_source":"web",
             "ongoing":false,"viewed":false}
            """
        }
        let body = """
        {"results":[\(rows.joined(separator: ","))],
         "has_next":\(offset == 0 ? "true" : "false"),"version":4}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

// MARK: - Playlists

@Suite("Playlist contents")
@MainActor
struct PlaylistContentsTests {

    /// Records which path was asked for, so the two kinds can be told apart by
    /// the request they produce rather than by what they claim.
    private actor RoutingTransport: HTTPTransport {
        private(set) var paths: [String] = []
        func seen() -> [String] { paths }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!
            paths.append(url.path)
            let body = #"{"results": [], "has_next": false, "version": 4}"#
            return (
                Data(body.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    @Test("a saved filter runs its stored query; a collection asks for its pinned rows")
    func routesByKind() async throws {
        // Built by hand rather than from a fixture, so the routing rule is
        // stated by the test rather than depending on which demo playlists the
        // bundle happens to hold.
        let transport = RoutingTransport()
        let store = PlaylistContentsStore()

        let savedFilter = try SessionRecordingPlaylist.decode(
            #"{"id": 1, "short_id": "sv1", "name": "Rage", "type": "filters", "filters": {"events": [{"id": "$rageclick", "type": "events", "order": 0}]}}"#
        )
        await store.load(playlist: savedFilter, client: client(transport), projectID: 42)

        let collection = try SessionRecordingPlaylist.decode(
            #"{"id": 2, "short_id": "cl1", "name": "Pinned", "type": "collection"}"#
        )
        await store.load(playlist: collection, client: client(transport), projectID: 42)

        // `URL.path` drops the trailing slash, so these are compared without it.
        let paths = await transport.seen()
        #expect(paths[0] == "/api/projects/42/session_recordings")
        #expect(paths[1] == "/api/projects/42/session_recording_playlists/cl1/recordings")
    }

    @Test("an empty answer is a state, not an error")
    func emptyIsNotAnError() async throws {
        let transport = RoutingTransport()
        let store = PlaylistContentsStore()
        let collection = try SessionRecordingPlaylist.decode(
            #"{"id": 2, "short_id": "cl1", "name": "Pinned", "type": "collection"}"#
        )
        await store.load(playlist: collection, client: client(transport), projectID: 42)
        #expect(store.recordings.isEmpty)
        #expect(store.error == nil)
        #expect(store.loadedAt != nil)
    }

    /// The page PostHog actually returns: its own synthetic views typed
    /// `collection` with negative ids, then the project's saved filters.
    @Test("the two kinds stay in separate sections of the list")
    func sectionsSplitByKind() throws {
        let store = PlaylistsStore()
        store.playlists = try [
            #"{"id": -101, "short_id": "example-reviewed-orbits", "name": "Example reviewed orbit sessions", "type": "collection", "is_synthetic": true}"#,
            #"{"id": -607, "short_id": "example-interaction-samples", "name": "Example interaction samples", "type": "collection", "is_synthetic": true}"#,
            #"{"id": 10, "short_id": "cl1", "name": "Team picks", "type": "collection"}"#,
            #"{"id": 11, "short_id": "sv1", "name": "Rage", "type": "filters", "filters": {"events": [{"id": "$rageclick", "type": "events", "order": 0}]}}"#,
        ].map(SessionRecordingPlaylist.decode)

        #expect(store.savedFilters.count == 1)
        #expect(store.collections.count == 3)
        // The team's own collection sorts above PostHog's synthetic ones.
        #expect(store.collections.first?.name == "Team picks")
        #expect(!store.savedFilters.isEmpty)
        #expect(!store.collections.isEmpty)
        #expect(store.savedFilters.allSatisfy { $0.kind == .filters })
        #expect(store.collections.allSatisfy { $0.kind != .filters })
        // Nothing is lost or duplicated between the two sections.
        #expect(store.savedFilters.count + store.collections.count == store.playlists.count)
    }
}

private extension SessionRecordingPlaylist {
    static func decode(_ json: String) throws -> SessionRecordingPlaylist {
        try JSONDecoder().decode(SessionRecordingPlaylist.self, from: Data(json.utf8))
    }
}
