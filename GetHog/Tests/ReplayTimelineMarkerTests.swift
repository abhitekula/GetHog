import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Replay timeline markers")
struct ReplayTimelineMarkerTests {
    @Test("maps Replay Vision citation chips to labelled replay positions")
    func mapsSummaryCitations() throws {
        let summary = try JSONDecoder().decode(ReplayVisionSummary.self, from: Data(#"""
        {
          "scanner_type":"summarizer",
          "title":"Synthetic session",
          "summary":"The user opened a dashboard and refreshed it.",
          "summary_segments":[
            {"kind":"text","value":"Opened the fictional dashboard "},
            {"kind":"chip","timestamp_ms":500},
            {"kind":"text","value":" then refreshed its widgets "},
            {"kind":"chip","timestamp_ms":1500}
          ],
          "friction_points":[],
          "keywords":[],
          "confidence":0.9
        }
        """#.utf8))

        let markers = SessionReplayMarker.make(summary: summary, duration: 10)

        #expect(markers.map(\.id) == ["summary-citation-0", "summary-citation-1"])
        #expect(markers.map(\.offset) == [0.5, 1.5])
        #expect(markers.map(\.label) == [
            "Opened the fictional dashboard",
            "then refreshed its widgets",
        ])
        #expect(markers.allSatisfy { $0.kind == .keyAction })
    }

    @Test("deduplicates citation times and clamps positions to the replay duration")
    func sanitizesSummaryCitations() throws {
        let summary = try JSONDecoder().decode(ReplayVisionSummary.self, from: Data(#"""
        {
          "summary_segments":[
            {"kind":"chip","timestamp_ms":1000},
            {"kind":"text","value":"Duplicate moment"},
            {"kind":"chip","timestamp_ms":1000},
            {"kind":"text","value":"Past the replay"},
            {"kind":"chip","timestamp_ms":12000}
          ]
        }
        """#.utf8))

        let markers = SessionReplayMarker.make(summary: summary, duration: 10)

        #expect(markers.map(\.offset) == [1, 10])
        #expect(markers.map(\.label) == ["Summary citation", "Past the replay"])
        #expect(SessionReplayMarker.make(summary: nil, duration: 10).isEmpty)
    }

    @Test("selects the active, previous and next summary citations")
    func markerNavigation() {
        let markers = [
            SessionReplayMarker(id: "early", offset: 0.5, label: "First", kind: .keyAction),
            SessionReplayMarker(id: "late", offset: 0.501, label: "Second", kind: .keyAction),
            SessionReplayMarker(id: "end", offset: 1, label: "Last", kind: .keyAction),
        ]

        #expect(SessionReplayMarker.active(in: markers, at: 0.4) == nil)
        #expect(SessionReplayMarker.active(in: markers, at: 0.5)?.id == "early")
        #expect(SessionReplayMarker.next(in: markers, after: 0.5)?.id == "late")
        #expect(SessionReplayMarker.active(in: markers, at: 0.501)?.id == "late")
        #expect(SessionReplayMarker.previous(in: markers, before: 0.501)?.id == "early")
        #expect(SessionReplayMarker.next(in: markers, after: 0.501)?.id == "end")
    }

    @Test("accessibility marker counts use singular grammar")
    func markerCountDescription() {
        #expect(SessionReplayMarker.accessibilityCountDescription(1) == "1 key event")
        #expect(SessionReplayMarker.accessibilityCountDescription(2) == "2 key events")
    }
}
