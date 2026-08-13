import Foundation
import GetHogKit
import Testing

@testable import GetHog

private actor DashboardListRefreshTransport: HTTPTransport {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 2 {
            throw PostHogError.transport("Synthetic dashboard list refresh failed")
        }

        let body = #"{"count":1,"next":null,"previous":null,"results":[{"id":9101,"name":"Synthetic Mac dashboard","pinned":true}]}"#
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private actor SessionsRefreshTransport: HTTPTransport {
    private var requestCount = 0

    func requests() -> Int { requestCount }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 2 {
            throw PostHogError.transport("Synthetic sessions refresh failed")
        }

        let rows = (1...3).map { index in
            """
            {"id":"synthetic-mac-session-\(index)","distinct_id":"synthetic-mac-person-\(index)",
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
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private actor EventsRefreshTransport: HTTPTransport {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 2 {
            throw PostHogError.transport("Synthetic events refresh failed")
        }

        let body = """
        {"columns":["uuid","event","distinct_id","timestamp","properties","$current_url"],
         "results":[["018f7e00-0000-7000-8000-000000000001","synthetic_event",
         "synthetic-mac-person","2026-08-08T12:00:00Z",{},null]]}
        """
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private actor SessionsFilterChangeTransport: HTTPTransport {
    private var requestCount = 0
    private var staleContinuation: CheckedContinuation<Void, Never>?

    func requests() -> Int { requestCount }

    func releaseStaleRequest() {
        staleContinuation?.resume()
        staleContinuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let requestNumber = requestCount
        if requestNumber == 2 {
            await withCheckedContinuation { continuation in
                staleContinuation = continuation
            }
        }

        let phase = switch requestNumber {
        case 1: "initial"
        case 2: "stale"
        default: "replacement"
        }
        let body = """
        {"results":[{"id":"synthetic-mac-\(phase)",
         "distinct_id":"synthetic-mac-person-\(phase)",
         "recording_duration":120,"active_seconds":60,
         "start_time":"2026-01-15T10:00:00Z","click_count":1,
         "keypress_count":0,"console_log_count":0,"console_warn_count":0,
         "console_error_count":0,"snapshot_source":"web",
         "ongoing":false,"viewed":false}],"has_next":true,"version":4}
        """
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private func staleRefreshClient(
    _ transport: some HTTPTransport,
    region: PostHogRegion = .usCloud
) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_synthetic_mac", region: region),
        transport: transport
    )
}

@MainActor
@Suite("Mac stale refresh preservation", .serialized)
struct StaleRefreshPreservationTests {
    @Test("dashboard list does not retain another host's same-project rows after failure")
    func dashboardListHostSwitchFailureClearsRows() async {
        let store = DashboardsStore()
        let transport = DashboardListRefreshTransport()

        await store.load(
            client: staleRefreshClient(transport, region: .usCloud),
            projectID: 1
        )
        #expect(store.dashboards.map(\.id) == [9101])

        await store.load(
            client: staleRefreshClient(transport, region: .euCloud),
            projectID: 1
        )

        #expect(store.dashboards.isEmpty)
        #expect(store.loadedAt == nil)
        guard case .failed = store.contentState(isAvailable: true) else {
            Issue.record("A failed EU load retained the US host's dashboard rows")
            return
        }
    }

    @Test("dashboard list keeps same-project rows and exposes retry state")
    func dashboardListRefreshFailurePreservesRows() async {
        let store = DashboardsStore()
        let transport = DashboardListRefreshTransport()
        let client = staleRefreshClient(transport)

        await store.load(client: client, projectID: 1)
        let ids = store.dashboards.map(\.id)
        #expect(ids == [9101])

        await store.load(client: client, projectID: 1)

        #expect(store.dashboards.map(\.id) == ids)
        #expect(store.contentState(isAvailable: true) == .loaded)
        #expect(
            DashboardListRefreshPresentation.resolve(
                dashboardCount: store.dashboards.count,
                error: store.error
            ) == DashboardListRefreshPresentation(
                message: "Couldn't refresh dashboards. Couldn't reach PostHog: Synthetic dashboard list refresh failed",
                actionTitle: "Try again"
            )
        )
    }

    @Test("sessions same-filter refresh keeps rows and exposes retry state")
    func sessionsRefreshFailurePreservesRows() async {
        let store = SessionsStore()
        let transport = SessionsRefreshTransport()
        let client = staleRefreshClient(transport)

        await store.load(client: client, projectID: 1)
        let ids = store.recordings.map(\.id)
        #expect(ids.count == 3)

        await store.load(client: client, projectID: 1)

        #expect(store.recordings.map(\.id) == ids)
        #expect(store.hasMore)
        #expect(
            SessionsRefreshPresentation.resolve(
                recordingCount: store.recordings.count,
                error: store.error
            ) == SessionsRefreshPresentation(
                message: "Couldn't refresh sessions. Couldn't reach PostHog: Synthetic sessions refresh failed",
                actionTitle: "Try again"
            )
        )
    }

    @Test("events same-filter refresh keeps its last-good feed")
    func eventsRefreshFailurePreservesRows() async {
        let store = EventsStore()
        let transport = EventsRefreshTransport()
        let client = staleRefreshClient(transport)

        await store.reload(client: client, projectID: 1, tokens: [], search: nil)
        let ids = store.events.map(\.id)
        let columns = store.responseColumns
        let rows = store.responseRows
        let loadedAt = store.loadedAt
        let reachedEnd = store.reachedEnd
        let searchedDescription = store.searchedDescription
        #expect(ids == ["018f7e00-0000-7000-8000-000000000001"])
        #expect(store.export != nil)

        await store.reload(client: client, projectID: 1, tokens: [], search: nil)

        #expect(store.events.map(\.id) == ids)
        #expect(store.responseColumns == columns)
        #expect(store.responseRows == rows)
        #expect(store.loadedAt == loadedAt)
        #expect(store.reachedEnd == reachedEnd)
        #expect(store.searchedDescription == searchedDescription)
        #expect(store.export != nil)
        #expect(store.failure?.summary.contains("Synthetic events refresh failed") == true)
        #expect(!store.isLoading)
    }

    @Test("events do not retain another client's same-host feed after failure")
    func eventsClientReplacementFailureClearsRows() async {
        let store = EventsStore()
        let transport = EventsRefreshTransport()
        let originalClient = staleRefreshClient(transport)
        let replacementClient = staleRefreshClient(transport)

        await store.reload(
            client: originalClient, projectID: 1, tokens: [], search: nil
        )
        #expect(store.events.map(\.id) == ["018f7e00-0000-7000-8000-000000000001"])

        await store.reload(
            client: replacementClient, projectID: 1, tokens: [], search: nil
        )

        #expect(store.events.isEmpty)
        #expect(store.responseColumns.isEmpty)
        #expect(store.responseRows.isEmpty)
        #expect(store.loadedAt == nil)
        #expect(store.export == nil)
        #expect(store.failure?.summary.contains("Synthetic events refresh failed") == true)
        #expect(!store.isLoading)
    }

    @Test("sessions filter edit retires rows and paging before replacement load")
    func sessionsFilterEditInvalidatesPaging() async {
        let store = SessionsStore()
        let transport = SessionsRefreshTransport()
        let client = staleRefreshClient(transport)

        await store.load(client: client, projectID: 1)
        store.filter.signal = .rageClick

        await store.loadMore(client: client, projectID: 1)

        #expect(await transport.requests() == 1)
        #expect(store.recordings.isEmpty)
        #expect(!store.hasMore)
        #expect(store.isLoading)
        #expect(store.pagingError == nil)
        #expect(!store.isLoadingMore)
    }

    @Test("sessions filter edit clears rows and rejects a held refresh before replacement")
    func sessionsFilterEditInvalidatesHeldRefresh() async {
        let store = SessionsStore()
        let transport = SessionsFilterChangeTransport()
        let client = staleRefreshClient(transport)

        await store.load(client: client, projectID: 1)
        #expect(store.recordings.map(\.id) == ["synthetic-mac-initial"])
        #expect(store.hasMore)

        let staleRefresh = Task {
            await store.load(client: client, projectID: 1)
        }
        while await transport.requests() < 2 { await Task.yield() }
        #expect(store.isLoading)

        store.filter.signal = .rageClick

        #expect(store.recordings.isEmpty)
        #expect(store.isLoading)
        #expect(!store.hasMore)
        #expect(store.loadedAt == nil)
        #expect(store.error == nil)
        #expect(store.pagingError == nil)
        #expect(!store.isLoadingMore)

        await transport.releaseStaleRequest()
        await staleRefresh.value

        #expect(store.recordings.isEmpty)
        #expect(store.isLoading)

        await store.load(client: client, projectID: 1)

        #expect(store.recordings.map(\.id) == ["synthetic-mac-replacement"])
        #expect(store.hasMore)
        #expect(!store.isLoading)
    }
}
