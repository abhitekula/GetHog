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
        let original = ProjectEventsTransport(tag: "project-one")
        await store.reload(client: client(original), projectID: 1, tokens: [], search: nil)

        let slowTick = ProjectEventsTransport(tag: "stale-tick", gated: true)
        let pending = Task {
            await store.refreshLatest(
                client: client(slowTick), projectID: 1, tokens: [], search: nil
            )
        }
        while await slowTick.requests() == 0 { await Task.yield() }

        let current = ProjectEventsTransport(tag: "project-two")
        await store.reload(client: client(current), projectID: 2, tokens: [], search: nil)
        await slowTick.release()
        await pending.value

        #expect(store.events.map(\.distinctID) == ["person-project-two"])
        #expect(store.liveTailFailure == nil)
    }
}
