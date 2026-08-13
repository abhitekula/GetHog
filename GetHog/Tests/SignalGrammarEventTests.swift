import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Event Signal Grammar")
struct SignalGrammarEventTests {
    private func event(_ name: String, person: String, time: String) -> EventRow {
        EventRow(row: QueryRow(
            columns: ["event", "distinct_id", "timestamp"],
            values: [.string(name), .string(person), .string(time)]
        ))!
    }

    @Test("Summary facts are scoped to the loaded feed and rank ties stably")
    func summaryFacts() {
        let events = [
            event("project_created", person: "person-a", time: "2026-08-01T12:03:00Z"),
            event("$screen", person: "person-b", time: "2026-08-01T12:02:00Z"),
            event("project_created", person: "person-a", time: "2026-08-01T12:01:00Z"),
        ]
        let facts = EventOverviewFacts(events: events)

        #expect(facts.eventCount == 3)
        #expect(facts.kindCount == 2)
        #expect(facts.peopleCount == 2)
        #expect(facts.reach == "2m")
        #expect(facts.ranked.map(\.name) == ["project_created", "$screen"])
    }

    @Test("Equal frequencies rank alphabetically")
    func stableTieRanking() {
        let events = [
            event("project_created", person: "person-a", time: "2026-08-01T12:03:00Z"),
            event("$screen", person: "person-b", time: "2026-08-01T12:02:00Z"),
        ]

        #expect(EventOverviewFacts(events: events).ranked.map(\.name) == [
            "$screen",
            "project_created",
        ])
    }

    @Test("Stable event kinds map to original object glyphs")
    func glyphKinds() {
        #expect(EventAppearance.brandGlyph(for: "$screen") == .screenEvent)
        #expect(EventAppearance.brandGlyph(for: "$exception") == .exceptionEvent)
        #expect(EventAppearance.brandGlyph(for: "$feature_flag_called") == .featureFlagEvent)
        #expect(EventAppearance.brandGlyph(for: "project_created") == .event)
    }

    @Test("a long person id stays on one line while a URL path may use two")
    func eventRowSubtitleHeightPolicy() throws {
        let longPersonID = "synthetic-person-" + String(repeating: "0123456789", count: 16)
        let personEvent = try #require(EventRow(row: QueryRow(
            columns: ["event", "distinct_id", "timestamp"],
            values: [.string("project_created"), .string(longPersonID), .string("2026-08-01T12:00:00Z")]
        )))
        let pathEvent = try #require(EventRow(row: QueryRow(
            columns: ["event", "distinct_id", "timestamp", "$current_url"],
            values: [
                .string("$pageview"),
                .string("synthetic-person"),
                .string("2026-08-01T12:00:00Z"),
                .string("https://example.invalid/a/long/synthetic/path/that/can/wrap"),
            ]
        )))

        let person = EventRowPresentation(event: personEvent)
        let path = EventRowPresentation(event: pathEvent)

        #expect(person.subtitle == longPersonID)
        #expect(person.subtitleLineLimit == 1)
        #expect(path.subtitle == "/a/long/synthetic/path/that/can/wrap")
        #expect(path.subtitleLineLimit == 2)
    }
}

private actor LiveTailRecoveryTransport: HTTPTransport {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 2 {
            throw PostHogError.transport("Synthetic live-tail interruption")
        }

        let rows: [String]
        if requestCount == 1 {
            rows = (0..<50).map(Self.row)
        } else {
            rows = [Self.row(999), Self.row(0)]
        }
        let body = """
        {"columns":["uuid","event","distinct_id","timestamp","properties","$current_url"],
         "results":[\(rows.joined(separator: ","))]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }

    private static func row(_ index: Int) -> String {
        let suffix = String(format: "%012d", index)
        let second = index == 999 ? 59 : index % 50
        return """
        ["018f7e00-0000-7000-8000-\(suffix)","synthetic_event",\
        "synthetic-person-\(index)","2026-08-08T12:00:\(String(format: "%02d", second))Z",{},null]
        """
    }
}

private actor ProjectEventsTransport: HTTPTransport {
    private let tag: String
    private let gate: AsyncStream<Void>.Continuation?
    private let gateStream: AsyncStream<Void>?
    private var requestCount = 0

    init(tag: String, gated: Bool = false) {
        self.tag = tag
        if gated {
            var continuation: AsyncStream<Void>.Continuation?
            let stream = AsyncStream<Void> { continuation = $0 }
            gate = continuation
            gateStream = stream
        } else {
            gate = nil
            gateStream = nil
        }
    }

    func requests() -> Int { requestCount }
    func release() { gate?.finish() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if let gateStream {
            for await _ in gateStream {}
        }
        let body = """
        {"columns":["uuid","event","distinct_id","timestamp","properties","$current_url"],
         "results":[["synthetic-\(tag)","synthetic_\(tag)","person-\(tag)",
         "2026-08-08T12:00:00Z",{},null]]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// Serves one initial page immediately, then holds the same client's Live Tail
/// request so a replacement project can retire it before its response arrives.
private actor HeldLiveTailEventsTransport: HTTPTransport {
    private var requestCount = 0
    private let gate: AsyncStream<Void>.Continuation
    private let gateStream: AsyncStream<Void>

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        gateStream = AsyncStream<Void> { continuation = $0 }
        gate = continuation!
    }

    func requests() -> Int { requestCount }
    func release() { gate.finish() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let tag = requestCount == 1 ? "project-one" : "stale-tick"
        if requestCount == 2 {
            for await _ in gateStream {}
        }
        let body = """
        {"columns":["uuid","event","distinct_id","timestamp","properties","$current_url"],
         "results":[["synthetic-\(tag)","synthetic_\(tag)","person-\(tag)",
         "2026-08-08T12:00:00Z",{},null]]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// Holds a same-signature replacement request while allowing an accidental
/// concurrent Live Tail request to complete, making the request-count contract
/// deterministic rather than deadlocking the test.
private actor HeldSameSignatureReloadTransport: HTTPTransport {
    private var requestCount = 0
    private var heldContinuation: CheckedContinuation<Void, Never>?

    func requests() -> Int { requestCount }
    func isHoldingReload() -> Bool { heldContinuation != nil }

    func releaseReload() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let requestNumber = requestCount
        if requestNumber == 2 {
            await withCheckedContinuation { continuation in
                heldContinuation = continuation
            }
        }
        let body = """
        {"columns":["uuid","event","distinct_id","timestamp","properties","$current_url"],
         "results":[["synthetic-request-\(requestNumber)","synthetic_event",\
         "person-request-\(requestNumber)","2026-08-08T12:00:00Z",{},null]]}
        """
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

/// Holds the first request so two reload callers overlap deterministically and
/// the request budget can be checked before either one completes.
private actor HeldFirstEventsTransport: HTTPTransport {
    private var requestCount = 0
    private let gate: AsyncStream<Void>.Continuation
    private let gateStream: AsyncStream<Void>

    init() {
        var continuation: AsyncStream<Void>.Continuation?
        gateStream = AsyncStream<Void> { continuation = $0 }
        gate = continuation!
    }

    func requests() -> Int { requestCount }
    func release() { gate.finish() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 1 {
            for await _ in gateStream {}
        }
        let body = """
        {"columns":["uuid","event","distinct_id","timestamp","properties","$current_url"],
         "results":[["synthetic-coalesced","synthetic_event","person-coalesced",
         "2026-08-08T12:00:00Z",{},null]]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// Captures the actual HogQL bodies while returning one full page and one short
/// page, so paging remains available long enough to inspect its query scope.
private actor PagingSearchCaptureTransport: HTTPTransport {
    private var bodies: [String] = []

    func capturedBodies() -> [String] { bodies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let firstPage = bodies.count == 1
        let indexes = firstPage ? Array(0..<50) : [50]
        let rows = indexes.map { index in
            let suffix = String(format: "%012d", index)
            let second = 59 - (index % 50)
            return """
            ["018f7e00-0000-7000-8000-\(suffix)","synthetic_event",\
            "synthetic-person-\(index)","2026-08-08T12:00:\(String(format: "%02d", second))Z",{},null]
            """
        }
        let body = """
        {"columns":["uuid","event","distinct_id","timestamp","properties","$current_url"],
         "results":[\(rows.joined(separator: ","))]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

@MainActor
private final class ReloadCallProbe {
    var entered = false
}

@Suite("Events live-tail recovery")
@MainActor
struct EventsLiveTailRecoveryTests {
    private func client(_ transport: some HTTPTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
    }

    @Test("a failed tick keeps the feed and retry merges only genuinely new rows")
    func failedTickPreservesFeedPagerAndExport() async {
        let transport = LiveTailRecoveryTransport()
        let store = EventsStore()
        let client = client(transport)

        await store.reload(client: client, projectID: 1, tokens: [], search: nil)
        let originalIDs = store.events.map(\.id)
        let originalRows = store.responseRows
        let originalReachedEnd = store.reachedEnd
        let originalWindow = store.searchedDescription
        #expect(originalIDs.count == 50)
        #expect(store.export != nil)

        await store.refreshLatest(client: client, projectID: 1, tokens: [], search: nil)

        #expect(store.events.map(\.id) == originalIDs)
        #expect(store.responseRows == originalRows)
        #expect(store.reachedEnd == originalReachedEnd)
        #expect(store.searchedDescription == originalWindow)
        #expect(store.liveTailFailure != nil)
        #expect(store.export != nil)

        await store.refreshLatest(client: client, projectID: 1, tokens: [], search: nil)

        #expect(store.events.count == 51)
        #expect(store.events.first?.distinctID == "synthetic-person-999")
        #expect(Set(store.events.map(\.id)).count == 51)
        #expect(store.responseRows.count == 51)
        #expect(store.reachedEnd == originalReachedEnd)
        #expect(store.searchedDescription == originalWindow)
        #expect(store.liveTailFailure == nil)
        #expect(store.export != nil)
    }

    @Test("concurrent identical reloads spend one events request")
    func concurrentIdenticalReloadsCoalesce() async {
        let transport = HeldFirstEventsTransport()
        let store = EventsStore()
        let client = client(transport)

        let first = Task {
            await store.reload(client: client, projectID: 1, tokens: [], search: nil)
        }
        while await transport.requests() == 0 { await Task.yield() }

        let duplicateCall = ReloadCallProbe()
        let duplicate = Task {
            duplicateCall.entered = true
            await store.reload(client: client, projectID: 1, tokens: [], search: nil)
        }
        while !duplicateCall.entered { await Task.yield() }

        #expect(
            await transport.requests() == 1,
            "one mounted feed and one restoration task must share the same request"
        )

        await transport.release()
        await first.value
        await duplicate.value
        #expect(store.events.map(\.distinctID) == ["person-coalesced"])
    }

    @Test("paging retains the submitted search instead of a newer visible draft")
    func pagingRetainsSubmittedSearch() async throws {
        let transport = PagingSearchCaptureTransport()
        let store = EventsStore()
        let api = client(transport)
        let submittedSearch = "submitted-meteor"
        let visibleDraftSearch = "draft-comet"

        await store.reload(
            client: api, projectID: 1, tokens: [], search: submittedSearch
        )
        #expect(!store.reachedEnd)

        // The draft is deliberately not submitted. Page two is a continuation
        // of the first query and must retain that query's search term.
        await store.loadMore(
            client: api, projectID: 1, tokens: [], search: visibleDraftSearch
        )

        let bodies = await transport.capturedBodies()
        try #require(bodies.count == 2)
        #expect(bodies[1].contains(submittedSearch))
        #expect(!bodies[1].contains(visibleDraftSearch))
    }

    @Test("paging failure preserves the feed and retry appends older events")
    func pagingFailurePreservesFeedAndRecovers() async {
        let transport = LiveTailRecoveryTransport()
        let store = EventsStore()
        let api = client(transport)

        await store.reload(client: api, projectID: 1, tokens: [], search: nil)
        let originalIDs = store.events.map(\.id)
        let originalRows = store.responseRows
        let originalReachedEnd = store.reachedEnd
        let originalWindow = store.searchedDescription
        #expect(originalIDs.count == 50)

        await store.loadMore(client: api, projectID: 1, tokens: [], search: nil)

        #expect(store.events.map(\.id) == originalIDs)
        #expect(store.responseRows == originalRows)
        #expect(store.reachedEnd == originalReachedEnd)
        #expect(store.searchedDescription == originalWindow)
        #expect(store.export != nil)
        #expect(store.failure == nil)
        #expect(store.pagingFailure != nil)

        await store.loadMore(client: api, projectID: 1, tokens: [], search: nil)

        #expect(store.events.count == 52)
        #expect(store.responseRows.count == 52)
        #expect(store.pagingFailure == nil)
        #expect(store.failure == nil)
    }

    @Test("an identical follower survives cancellation of the reload leader")
    func identicalFollowerSurvivesLeaderCancellation() async {
        let transport = HeldFirstEventsTransport()
        let store = EventsStore()
        let client = client(transport)

        let leader = Task {
            await store.reload(client: client, projectID: 1, tokens: [], search: nil)
        }
        while await transport.requests() == 0 { await Task.yield() }

        // Setting this immediately before the async call makes the hand-off
        // deterministic on MainActor: once this test observes `entered`, the
        // follower has reached reload's first suspension (or returned).
        let followerCall = ReloadCallProbe()
        let follower = Task {
            followerCall.entered = true
            await store.reload(client: client, projectID: 1, tokens: [], search: nil)
        }
        while !followerCall.entered { await Task.yield() }

        leader.cancel()
        await transport.release()
        await leader.value
        await follower.value

        #expect(
            await transport.requests() == 1,
            "a surviving identical caller must share, not duplicate, the held request"
        )
        #expect(store.events.map(\.distinctID) == ["person-coalesced"])
        #expect(store.loadedAt != nil)
        #expect(store.failure == nil)
    }

    @Test("Live Tail stands down while a same-signature reload replaces the feed")
    func liveTailStandsDownDuringReload() async {
        let transport = HeldSameSignatureReloadTransport()
        let store = EventsStore()
        let api = client(transport)

        await store.reload(client: api, projectID: 1, tokens: [], search: nil)
        let pendingReload = Task {
            await store.reload(client: api, projectID: 1, tokens: [], search: nil)
        }
        while await !transport.isHoldingReload() { await Task.yield() }
        #expect(store.isLoading)

        await store.refreshLatest(client: api, projectID: 1, tokens: [], search: nil)

        #expect(await transport.requests() == 2)
        await transport.releaseReload()
        await pendingReload.value
        #expect(store.events.map(\.distinctID) == ["person-request-2"])
    }

    @Test("a late reload from the prior project cannot replace the new project feed")
    func lateProjectReloadIsDiscarded() async {
        let store = EventsStore()
        let slow = ProjectEventsTransport(tag: "project-one", gated: true)
        let pending = Task {
            await store.reload(client: client(slow), projectID: 1, tokens: [], search: nil)
        }
        while await slow.requests() == 0 { await Task.yield() }

        let current = ProjectEventsTransport(tag: "project-two")
        await store.reload(client: client(current), projectID: 2, tokens: [], search: nil)
        await slow.release()
        await pending.value

        #expect(store.events.map(\.distinctID) == ["person-project-two"])
        #expect(store.responseRows.count == 1)
    }

    @Test("a late live-tail tick cannot prepend into a replacement project's feed")
    func lateProjectLiveTailIsDiscarded() async {
        let store = EventsStore()
        let original = HeldLiveTailEventsTransport()
        let originalClient = client(original)
        await store.reload(
            client: originalClient, projectID: 1, tokens: [], search: nil
        )

        let pending = Task {
            await store.refreshLatest(
                client: originalClient, projectID: 1, tokens: [], search: nil
            )
        }
        while await original.requests() < 2 { await Task.yield() }

        let current = ProjectEventsTransport(tag: "project-two")
        await store.reload(client: client(current), projectID: 2, tokens: [], search: nil)
        await original.release()
        await pending.value

        #expect(store.events.map(\.distinctID) == ["person-project-two"])
        #expect(store.liveTailFailure == nil)
    }
}
