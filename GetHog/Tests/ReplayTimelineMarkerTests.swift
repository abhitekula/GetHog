import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay timeline markers")
struct ReplayTimelineMarkerTests {
    @Test("prefers absolute timestamps and preserves close semantic moments")
    func mapsKeyEvents() throws {
        let detail = try SessionSummaryDetail.decode(from: Data(#"""
            {
              "session_id":"synthetic-session",
              "summary":{
                "segments":[{"index":0,"name":"Synthetic moments"}],
                "key_actions":[{"segment_index":0,"events":[
                  {"event_id":"late","description":"Second moment",
                   "timestamp":"2026-01-15T12:00:01.500500Z",
                   "milliseconds_since_start":9000},
                  {"event_id":"early","description":"First moment",
                   "timestamp":"2026-01-15T12:00:01.500000Z",
                   "milliseconds_since_start":8000},
                  {"event_id":"fallback","description":"Offset fallback",
                   "milliseconds_since_start":1500}
                ]}]
              }
            }
            """#.utf8))
        let origin = try #require(PostHogDate.parse("2026-01-15T12:00:01Z"))
        let markers = SessionReplayMarker.make(
            detail: detail, origin: origin, duration: 10
        )

        #expect(markers.map(\.id) == ["early", "late", "fallback"])
        #expect(abs(markers[0].offset - 0.5) < 0.000_001)
        #expect(abs(markers[1].offset - 0.5005) < 0.000_001)
        #expect(abs(markers[2].offset - 1.5) < 0.000_001)
        #expect(SessionReplayMarker.active(in: markers, at: 0.5)?.id == "early")
        #expect(SessionReplayMarker.next(in: markers, after: 0.5)?.id == "late")
        #expect(SessionReplayMarker.active(in: markers, at: 0.5005)?.id == "late")
        #expect(SessionReplayMarker.previous(in: markers, before: 0.5005)?.id == "early")
        #expect(SessionReplayMarker.next(in: markers, after: 0.5005)?.id == "fallback")
    }

    @Test("selects the active, previous and next semantic moments")
    func markerNavigation() {
        let markers = [
            SessionReplayMarker(id: "early", offset: 0.5, label: "First", kind: .keyAction),
            SessionReplayMarker(id: "late", offset: 0.501, label: "Second", kind: .keyAction),
            SessionReplayMarker(id: "end", offset: 1, label: "Last", kind: .keyAction)
        ]

        #expect(SessionReplayMarker.active(in: markers, at: 0.4) == nil)
        #expect(SessionReplayMarker.active(in: markers, at: 0.5)?.id == "early")
        #expect(SessionReplayMarker.next(in: markers, after: 0.5)?.id == "late")
        #expect(SessionReplayMarker.active(in: markers, at: 0.501)?.id == "late")
        #expect(SessionReplayMarker.previous(in: markers, before: 0.501)?.id == "early")
        #expect(SessionReplayMarker.next(in: markers, after: 0.501)?.id == "end")
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
