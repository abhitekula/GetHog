import Foundation
import Testing

@testable import GetHogKit

/// Deterministic coverage for the public session-recording filter contract.
@Suite("Session recording filters")
struct SessionRecordingFilterTests {

    private func items(_ filter: SessionRecordingFilter) -> [String: String] {
        Dictionary(
            filter.queryItems.map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a }
        )
    }

    // MARK: - The default filter

    @Test("an untouched filter explicitly asks for all retained recordings")
    func defaultFilterEscapesTheServerDefault() {
        let filter = SessionRecordingFilter()
        #expect(items(filter) == ["date_from": "1970-01-01T00:00:00Z"])
        #expect(!filter.filterTestAccounts)
        #expect(!filter.isNarrowed)
        #expect(filter.activeCount == 0)
    }

    @Test("test users are excluded only when the server-side option is enabled")
    func filterTestAccountsEncodes() {
        var filter = SessionRecordingFilter()
        #expect(items(filter)["filter_test_accounts"] == nil)

        filter.filterTestAccounts = true
        #expect(items(filter)["filter_test_accounts"] == "true")
        #expect(filter.activeCount == 1)
        #expect(filter.isNarrowed)

        filter.clear()
        #expect(!filter.filterTestAccounts)
        #expect(items(filter)["filter_test_accounts"] == nil)
    }

    @Test("the default order is not sent either — PostHog's own default is start_time")
    func defaultOrderIsSilent() {
        var filter = SessionRecordingFilter()
        filter.order = .startTime
        #expect(items(filter)["order"] == nil)

        filter.order = .consoleErrorCount
        #expect(items(filter)["order"] == "console_error_count")
    }

    // MARK: - Duration

    @Test("minimum duration becomes a having_predicate, not a client-side drop")
    func durationPredicate() throws {
        var filter = SessionRecordingFilter()
        filter.minimumDuration = 120

        let raw = try #require(items(filter)["having_predicates"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        )
        #expect(json.count == 1)
        #expect(json[0]["key"] as? String == "duration")
        #expect(json[0]["type"] as? String == "recording")
        // `gte`, not `gt`: the client-side picker this replaces dropped a
        // recording only when it was *shorter* than the choice, so a
        // exactly-120-second recording was kept and must still be.
        #expect(json[0]["operator"] as? String == "gte")
        #expect(json[0]["value"] as? Double == 120)
    }

    @Test("active time is a different number from wall-clock duration and gets its own key")
    func activeDurationUsesItsOwnKey() throws {
        var filter = SessionRecordingFilter()
        filter.minimumDuration = 30
        filter.durationMetric = .active

        let raw = try #require(items(filter)["having_predicates"])
        #expect(raw.contains("active_seconds"))
        #expect(!raw.contains("\"duration\""))
    }

    @Test("a zero minimum is no minimum")
    func zeroDurationIsNoPredicate() {
        var filter = SessionRecordingFilter()
        filter.minimumDuration = 0
        #expect(items(filter)["having_predicates"] == nil)
        #expect(!filter.isNarrowed)
    }

    // MARK: - Signals

    @Test("each frustration signal maps to the PostHog event that records it")
    func signalEventNames() {
        #expect(SessionRecordingFilter.Signal.rageClick.eventName == "$rageclick")
        #expect(SessionRecordingFilter.Signal.deadClick.eventName == "$dead_click")
        #expect(SessionRecordingFilter.Signal.exception.eventName == "$exception")
    }

    @Test("a signal becomes an events entry in the shape the API validates")
    func signalEncodes() throws {
        var filter = SessionRecordingFilter()
        filter.signal = .rageClick

        let raw = try #require(items(filter)["events"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        )
        #expect(json.count == 1)
        #expect(json[0]["id"] as? String == "$rageclick")
        #expect(json[0]["name"] as? String == "$rageclick")
        #expect(json[0]["type"] as? String == "events")
        #expect(json[0]["order"] as? Int == 0)
    }

    @Test("console errors are a log-entry filter, not an event")
    func consoleErrorEncodes() throws {
        var filter = SessionRecordingFilter()
        filter.signal = .consoleError

        #expect(items(filter)["events"] == nil)
        let raw = try #require(items(filter)["console_log_filters"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        )
        #expect(json[0]["key"] as? String == "level")
        #expect(json[0]["type"] as? String == "log_entry")
        #expect(json[0]["value"] as? [String] == ["error"])
        #expect(json[0]["operator"] as? String == "exact")
    }

    // MARK: - The operand invariant
    //
    // Measured: `operand=OR` dissolves *every* clause in the filter group —
    // events, properties and console_log_filters together — so an OR that was
    // meant to widen the signal choice silently deletes the person filter
    // beside it. The type therefore has no OR to set.

    @Test("operand is never emitted, because only AND composes correctly")
    func operandIsNeverSent() {
        var filter = SessionRecordingFilter()
        filter.signal = .rageClick
        filter.personSearch = "nina"
        filter.minimumDuration = 60
        #expect(items(filter)["operand"] == nil)
    }

    @Test("signal is single-valued, so no combination can need an OR")
    func signalIsSingleValued() {
        var filter = SessionRecordingFilter()
        filter.signal = .rageClick
        filter.signal = .exception
        let raw = items(filter)["events"] ?? ""
        #expect(raw.contains("$exception"))
        #expect(!raw.contains("$rageclick"))
    }

    // MARK: - Person

    @Test("person search becomes a case-insensitive person-property contains")
    func personSearchEncodes() throws {
        var filter = SessionRecordingFilter()
        filter.personSearch = "  Nina  "

        let raw = try #require(items(filter)["properties"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        )
        #expect(json[0]["key"] as? String == "email")
        #expect(json[0]["type"] as? String == "person")
        #expect(json[0]["operator"] as? String == "icontains")
        // Trimmed: a trailing space from a phone keyboard is not a search term.
        #expect(json[0]["value"] as? String == "Nina")
    }

    @Test("whitespace-only person search is no search")
    func blankPersonSearchIsSilent() {
        var filter = SessionRecordingFilter()
        filter.personSearch = "   "
        #expect(items(filter)["properties"] == nil)
        #expect(!filter.isNarrowed)
    }

    @Test("URL search is an event property, because the recording column does not match")
    func urlSearchEncodes() throws {
        var filter = SessionRecordingFilter()
        filter.urlSearch = "/checkout"

        let raw = try #require(items(filter)["properties"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        )
        #expect(json[0]["key"] as? String == "$current_url")
        #expect(json[0]["type"] as? String == "event")
        #expect(json[0]["operator"] as? String == "icontains")
        #expect(json[0]["value"] as? String == "/checkout")
    }

    @Test("person and URL search compose in one AND'd properties array")
    func personAndURLCompose() throws {
        var filter = SessionRecordingFilter()
        filter.personSearch = "nina"
        filter.urlSearch = "/budget"

        let raw = try #require(items(filter)["properties"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        )
        #expect(json.count == 2)
        #expect(items(filter)["operand"] == nil)
        #expect(filter.activeCount == 2)
    }

    @Test("playable-only rides in having_predicates beside the duration floor")
    func sourceAndDurationShareOneParameter() throws {
        var filter = SessionRecordingFilter()
        filter.source = .web
        filter.minimumDuration = 60

        let raw = try #require(items(filter)["having_predicates"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        )
        #expect(json.count == 2)
        #expect(json.contains { $0["key"] as? String == "duration" })
        #expect(json.contains { $0["key"] as? String == "snapshot_source" })
    }

    @Test("an explicit distinct id filters exactly, without the property round-trip")
    func distinctIDsEncode() throws {
        var filter = SessionRecordingFilter()
        filter.distinctIDs = ["abc123"]
        let raw = try #require(items(filter)["distinct_ids"])
        #expect(raw == #"["abc123"]"#)
    }

    // MARK: - Dates

    @Test("every date window sends the date_from that its label promises")
    func dateWindowEncodes() {
        var filter = SessionRecordingFilter()
        filter.dateWindow = .last7Days
        #expect(items(filter)["date_from"] == "-7d")

        filter.dateWindow = .last24Hours
        #expect(items(filter)["date_from"] == "-24h")

        filter.dateWindow = .allTime
        #expect(items(filter)["date_from"] == "1970-01-01T00:00:00Z")
    }

    // MARK: - Counting, for the badge on the toolbar button

    @Test("every narrowing counts once, and the count matches what the sheet shows")
    func activeCount() {
        var filter = SessionRecordingFilter()
        #expect(filter.activeCount == 0)

        filter.dateWindow = .last7Days
        filter.signal = .rageClick
        filter.minimumDuration = 60
        filter.personSearch = "nina"
        #expect(filter.activeCount == 4)
        #expect(filter.isNarrowed)

        // Sort order narrows nothing, so it must not inflate the badge.
        filter.order = .consoleErrorCount
        #expect(filter.activeCount == 4)
    }

    @Test("clearing returns exactly the all-retention default filter")
    func clearing() {
        var filter = SessionRecordingFilter()
        filter.dateWindow = .last30Days
        filter.signal = .exception
        filter.personSearch = "x"
        filter.minimumDuration = 90
        filter.order = .duration
        filter.clear()
        #expect(items(filter) == ["date_from": "1970-01-01T00:00:00Z"])
        #expect(filter == SessionRecordingFilter())
    }

    // MARK: - Endpoint wiring

    @Test("the recordings endpoint carries the filter alongside paging")
    func endpointCarriesFilter() {
        var filter = SessionRecordingFilter()
        filter.signal = .rageClick
        filter.dateWindow = .last30Days

        let endpoint = PostHogAPI.sessionRecordings(
            projectID: 1, limit: 20, offset: 40, filter: filter
        )
        let names = endpoint.query.map(\.name)
        #expect(names.contains("limit"))
        #expect(names.contains("offset"))
        #expect(names.contains("events"))
        #expect(names.contains("date_from"))
        #expect(endpoint.category == .analytics)
        #expect(endpoint.method == "GET")
    }

    @Test("page one omits offset and carries the explicit all-retention date")
    func endpointDefaultIsCursorReadyAndExplicitlyDated() {
        let endpoint = PostHogAPI.sessionRecordings(projectID: 1, limit: 50)
        #expect(endpoint.query.map(\.name) == ["limit", "date_from"])
        #expect(endpoint.query.first { $0.name == "date_from" }?.value == "1970-01-01T00:00:00Z")
        #expect(endpoint.path == "/api/projects/1/session_recordings/")
    }

    // MARK: - What the API does with a filter it does not have
    //
    // A deterministic validation envelope settles the behavior: there is no
    // such thing as a filter this API silently ignores, so an unsupported key
    // fails loudly rather than returning a plausible, wider list.
    @Test("an unsupported filter key is a named 400, not a silently wider list")
    func unsupportedKeyIsRefusedByName() async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: RefusingTransport(
                status: 400,
                body: try Fixture.data("session_recordings_filter_rejected.json")
            )
        )

        do {
            let _: RecordingList = try await client.send(
                PostHogAPI.sessionRecordings(projectID: 1)
            )
            Issue.record("expected the request to be refused")
        } catch let error as PostHogError {
            guard case .http(let status, let detail) = error else {
                Issue.record("expected .http, got \(error)")
                return
            }
            #expect(status == 400)
            let message = try #require(detail)
            #expect(message.contains("extra_forbidden"))
            // The rejected key is named, which is what makes it debuggable.
            #expect(message.contains("rage_click"))
        }
    }
}

private struct RefusingTransport: HTTPTransport {
    let status: Int
    let body: Data

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            body,
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

// MARK: - Saved filters

@Suite("Saved replay filters")
struct SavedRecordingFilterTests {

    private func playlist(named name: String) throws -> SessionRecordingPlaylist {
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        return try #require(page.results.first { $0.name == name })
    }

    @Test("a saved filter's stored duration clause becomes a having predicate")
    func translatesDuration() throws {
        let saved = try playlist(named: "Example long orbit sessions")
        let filter = try #require(saved.recordingFilter)
        #expect(filter.minimumDuration == 90)
        #expect(filter.durationMetric == .total)
        #expect(filter.dateWindow == .last7Days)
        // The console stored `gt`; translating it to this app's own `gte`
        // default would run a filter wider than the saved filter's name.
        #expect(filter.durationComparison == .greaterThan)
        #expect(filter.queryItems.first { $0.name == "having_predicates" }?
            .value?.contains("\"gt\"") == true)
    }

    @Test("a stored active_seconds clause keeps its own metric")
    func translatesActiveSeconds() throws {
        let saved = try playlist(named: "Example console signal sessions")
        let filter = try #require(saved.recordingFilter)
        #expect(filter.minimumDuration == 10)
        #expect(filter.durationMetric == .active)
        // The stored group holds a level=error log-entry clause.
        #expect(filter.signal == .consoleError)
    }

    @Test("a stored event clause becomes the matching signal")
    func translatesEventClause() throws {
        let saved = try playlist(named: "Example rapid-click sessions")
        let filter = try #require(saved.recordingFilter)
        #expect(filter.signal == .rageClick)
    }

    @Test("a saved filter preserves the console's test-account exclusion")
    func translatesTestAccountExclusion() throws {
        let saved = try JSONDecoder().decode(
            SessionRecordingPlaylist.self,
            from: Data(
                #"{"id": 1, "short_id": "test-on", "name": "Synthetic", "type": "filters", "filters": {"filter_test_accounts": "true"}}"#.utf8
            )
        )
        let filter = try #require(saved.recordingFilter)
        #expect(filter.filterTestAccounts)
        #expect(filter.queryItems.first { $0.name == "filter_test_accounts" }?.value == "true")
    }

    @Test("a saved filter that includes test accounts leaves exclusion disabled")
    func translatesIncludedTestAccounts() throws {
        let saved = try JSONDecoder().decode(
            SessionRecordingPlaylist.self,
            from: Data(
                #"{"id": 2, "short_id": "test-off", "name": "Synthetic", "type": "filters", "filters": {"filter_test_accounts": "false"}}"#.utf8
            )
        )
        let filter = try #require(saved.recordingFilter)
        #expect(!filter.filterTestAccounts)
    }

    // PostHog stores `"date_to": "null"` — the four-character string, not JSON
    // null. Passed through verbatim it is a 400.
    @Test("the literal string \"null\" that PostHog stores for an open end date is not a date")
    func stringNullDateIsDropped() throws {
        let saved = try playlist(named: "Example long orbit sessions")
        let filter = try #require(saved.recordingFilter)
        let names = filter.queryItems.map(\.name)
        #expect(!names.contains("date_to"))
    }

    // Dropping a clause silently would make the result *wider* than the saved
    // filter promises, which looks identical to the filter working.
    @Test("the console-message clause PostHog stores is named as not applied")
    func untranslatedClauseIsNamed() throws {
        let saved = try playlist(named: "Example console signal sessions")
        #expect(saved.untranslatedClauses == ["console message"])
    }

    @Test("a filter with nothing dropped says so by naming nothing")
    func nothingUntranslated() throws {
        #expect(try playlist(named: "Example rapid-click sessions").untranslatedClauses.isEmpty)
        #expect(try playlist(named: "Example long orbit sessions").untranslatedClauses.isEmpty)
        #expect(try playlist(named: "Example mobile orbit sessions").untranslatedClauses.isEmpty)
    }

    @Test("a collection has no query behind it, so it yields no filter")
    func collectionHasNoFilter() throws {
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        let watchHistory = try #require(page.results.first {
            $0.name == "Example reviewed orbit sessions"
        })
        #expect(watchHistory.kind == .collection)
        #expect(watchHistory.recordingFilter == nil)
    }

    @Test("a saved filter is a query and a collection is a pinned list — the app must not merge them")
    func kindsStayDistinct() throws {
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        let saved = page.results.filter { $0.kind == .filters }
        let collections = page.results.filter { $0.kind == .collection }
        #expect(!saved.isEmpty)
        #expect(!collections.isEmpty)
        #expect(saved.allSatisfy { $0.recordingFilter != nil })
        #expect(collections.allSatisfy { $0.recordingFilter == nil })
    }
}

// MARK: - Playlist contents

@Suite("Playlist recordings")
struct PlaylistRecordingsTests {

    @Test("the endpoint is the playlist's own recordings sub-resource")
    func endpointShape() {
        let endpoint = PostHogAPI.playlistRecordings(
            projectID: 42, shortID: "abc123", limit: 25
        )
        #expect(endpoint.path == "/api/projects/42/session_recording_playlists/abc123/recordings/")
        #expect(endpoint.query.first { $0.name == "limit" }?.value == "25")
        #expect(endpoint.category == .analytics)
    }

    @Test("decodes a collection's pinned recordings")
    func decodesContents() throws {
        let page = try RecordingList.decode(
            from: Fixture.data("session_recording_playlist_recordings.json")
        )
        #expect(page.results.count == 1)
        #expect(page.hasNext == false)
        let first = try #require(page.results.first)
        #expect(first.id == "018f1000-0000-7000-8000-000000000001")
        #expect(first.consoleErrorCount == 0)
    }

    // Measured: this endpoint returns only *pinned* recordings. A saved filter
    // pins nothing, so it answers 200 with an empty list — which must not be
    // read as "this playlist is empty".
    @Test("a saved filter's pinned list is empty rather than absent")
    func savedFilterPinnedListIsEmpty() throws {
        let page = try RecordingList.decode(
            from: Fixture.data("session_recording_playlist_recordings_empty.json")
        )
        #expect(page.results.isEmpty)
        #expect(page.hasNext == false)
    }

    @Test("decodes the filtered recordings list, cursor envelope and all")
    func decodesFilteredList() throws {
        let page = try RecordingList.decode(
            from: Fixture.data("session_recordings_filtered.json")
        )
        #expect(page.results.map(\.id) == [
            "018f1000-0000-7000-8000-000000000002",
            "018f1000-0000-7000-8000-000000000003",
            "018f1000-0000-7000-8000-000000000004",
            "018f1000-0000-7000-8000-000000000005",
        ])
        #expect(!page.hasNext)
        #expect(page.nextCursor == nil)
        // The deterministic response represents `duration > 60`; every row
        // proves that boundary independently of any captured tenant data.
        #expect(page.results.allSatisfy { ($0.recordingDuration ?? 0) > 60 })
        #expect(page.results.allSatisfy { $0.startURL?.hasPrefix("https://app.example.com/") == true })
    }
}
