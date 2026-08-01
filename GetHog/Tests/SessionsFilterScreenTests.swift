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

private func client(_ transport: some HTTPTransport) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
        transport: transport
    )
}

@Suite("Sessions filtering")
@MainActor
struct SessionsFilterScreenTests {

    // MARK: - What actually goes on the wire

    @Test("an unfiltered load asks for exactly what it always did")
    func unfilteredRequestIsUnchanged() async throws {
        let transport = RecordingsTransport(total: 10)
        let store = SessionsStore()
        await store.load(client: client(transport), projectID: 1)

        let items = await transport.items(0)
        #expect(items["limit"] == "50")
        #expect(items["offset"] == "0")
        #expect(items.count == 2)
    }

    @Test("the filter reaches the wire rather than being applied after the page lands")
    func filterIsSentToTheServer() async throws {
        let transport = RecordingsTransport(total: 10)
        let store = SessionsStore()
        store.filter.signal = .rageClick
        store.filter.minimumDuration = 60
        store.filter.dateWindow = .last7Days
        await store.load(client: client(transport), projectID: 1)

        let items = await transport.items(0)
        #expect(items["date_from"] == "-7d")
        #expect(items["events"]?.contains("$rageclick") == true)
        #expect(items["having_predicates"]?.contains("\"duration\"") == true)
    }

    // MARK: - Replace, never append

    @Test("changing the filter replaces the list instead of extending it")
    func filterChangeReplaces() async throws {
        let transport = RecordingsTransport(total: 200)
        let store = SessionsStore()

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
        let store = SessionsStore()

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
        let store = SessionsStore()
        await store.load(client: client(transport), projectID: 1)
        await store.loadMore(client: client(transport), projectID: 1)

        #expect(Set(store.recordings.map(\.id)).count == store.recordings.count)
        #expect(store.recordings.count == 90)
    }

    @Test("a page still in flight when the filter changes cannot land in the new results")
    func staleResponseIsDiscarded() async throws {
        let gated = RecordingsTransport(total: 200, gated: true)
        let store = SessionsStore()

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

    @Test("loading more never runs against a filter that has since changed")
    func loadMoreIsGated() async throws {
        let transport = RecordingsTransport(total: 200)
        let store = SessionsStore()
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
        let store = SessionsStore()
        await store.load(client: client(good), projectID: 1)
        #expect(!store.recordings.isEmpty)

        store.filter.signal = .exception
        await store.load(client: client(FailingTransport()), projectID: 1)
        #expect(store.recordings.isEmpty)
        #expect(store.error != nil)
        #expect(!store.hasMore)
    }

    // MARK: - The request signature that drives the debounce

    @Test("the signature changes with the filter and is stable when it does not")
    func requestSignature() {
        let store = SessionsStore()
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
    }

    // MARK: - What the list says about itself

    @Test("the summary names every active narrowing")
    func summarySentence() {
        var filter = SessionRecordingFilter()
        #expect(filter.summarySentence == "Showing all sessions.")

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
