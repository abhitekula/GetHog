import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay timeline markers")
struct ReplayTimelineMarkerTests {
    private func detail() async throws -> SessionSummaryDetail {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
        return try await client.send(
            PostHogAPI.sessionSummary(
                projectID: 1_001,
                sessionID: "018f1000-0000-7000-8000-000000000001"
            )
        )
    }

    @Test("maps every timed key event onto the replay clock")
    func mapsKeyEvents() async throws {
        let origin = try #require(PostHogDate.parse("2026-01-15T12:00:00Z"))
        let markers = SessionReplayMarker.make(
            detail: try await detail(), origin: origin, duration: 10
        )

        #expect(markers.map(\.id) == ["event-open", "event-refresh"])
        #expect(markers.map(\.offset) == [0.5, 0.9])
        #expect(markers.map(\.kind) == [.keyAction, .struggle])
        #expect(markers[1].label == "The user pressed the fictional refresh button.")
    }

    @Test("selects the active, previous and next semantic moments")
    func markerNavigation() async throws {
        let origin = try #require(PostHogDate.parse("2026-01-15T12:00:00Z"))
        let markers = SessionReplayMarker.make(
            detail: try await detail(), origin: origin, duration: 10
        )

        #expect(SessionReplayMarker.active(in: markers, at: 0.4) == nil)
        #expect(SessionReplayMarker.active(in: markers, at: 0.7)?.id == "event-open")
        #expect(SessionReplayMarker.active(in: markers, at: 1.0)?.id == "event-refresh")
        #expect(SessionReplayMarker.previous(in: markers, before: 1.0)?.id == "event-open")
        #expect(SessionReplayMarker.next(in: markers, after: 0.5)?.id == "event-refresh")
    }

    @Test("deduplicates, omits untimed events, and clamps to duration")
    func sanitizesMarkerOffsets() throws {
        let detail = try SessionSummaryDetail.decode(from: Data(#"""
            {
              "session_id":"synthetic-session",
              "summary":{
                "segments":[{"index":0,"name":"Synthetic moments"}],
                "key_actions":[{"segment_index":0,"events":[
                  {"event_id":"duplicate","description":"Untimed duplicate"},
                  {"event_id":"duplicate","description":"Timed duplicate",
                   "milliseconds_since_start":1000},
                  {"event_id":"past-duration","description":"Past duration",
                   "milliseconds_since_start":12000,"exception":"high"},
                  {"event_id":"missing-time","description":"No time"}
                ]}]
              }
            }
            """#.utf8))

        let markers = SessionReplayMarker.make(
            detail: detail, origin: nil, duration: 10
        )

        #expect(markers.map(\.id) == ["duplicate", "past-duration"])
        #expect(markers.map(\.offset) == [1, 10])
        #expect(markers.map(\.kind) == [.keyAction, .exception])
        #expect(markers.first?.label == "Timed duplicate")
        #expect(
            SessionReplayMarker.make(detail: nil, origin: nil, duration: 10).isEmpty
        )
    }
}
