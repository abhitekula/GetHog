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

private func staleRefreshClient(_ transport: some HTTPTransport) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_synthetic_mac", region: .usCloud),
        transport: transport
    )
}

@MainActor
@Suite("Mac stale refresh preservation", .serialized)
struct StaleRefreshPreservationTests {
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
}
