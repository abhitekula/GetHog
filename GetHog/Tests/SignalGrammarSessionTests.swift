import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Session Signal Grammar")
struct SignalGrammarSessionTests {
    @Test("Overview facts preserve loaded-page scope")
    func overviewFacts() throws {
        let data = Data(#"""
        [
          {"id":"a","recording_duration":120,"console_error_count":2,"snapshot_source":"web","start_url":"https://example.com/signup"},
          {"id":"b","recording_duration":300,"console_error_count":0,"snapshot_source":"mobile","start_url":"https://example.com/home"}
        ]
        """#.utf8)
        let recordings = try JSONDecoder().decode([SessionRecording].self, from: data)
        let facts = SessionOverviewFacts(recordings: recordings)

        #expect(facts.recordingCount == 2)
        #expect(facts.withErrors.count == 1)
        #expect(facts.notPlayableCount == 1)
        #expect(facts.totalDurationText == "7m")
        #expect(facts.entryPaths.map(\.path) == ["/home", "/signup"])
    }

    @Test("Duration totals handle zero and hour boundaries")
    func durationBoundaries() throws {
        let data = Data(#"""
        [
          {"id":"empty","snapshot_source":"web"},
          {"id":"hour","recording_duration":3660,"snapshot_source":"web"}
        ]
        """#.utf8)
        let recordings = try JSONDecoder().decode([SessionRecording].self, from: data)

        #expect(SessionOverviewFacts(recordings: []).totalDurationText == "0m")
        #expect(SessionOverviewFacts(recordings: recordings).totalDurationText == "1h 1m")
    }

    @Test("Error triage includes only positive counts and caps the list")
    func errorTriage() throws {
        let rows = (0...6).map { index in
            #"{"id":"\#(index)","console_error_count":\#(index),"snapshot_source":"web"}"#
        }
        let recordings = try JSONDecoder().decode(
            [SessionRecording].self,
            from: Data("[\(rows.joined(separator: ","))]".utf8)
        )

        let facts = SessionOverviewFacts(recordings: recordings)

        #expect(facts.withErrorCount == 6)
        #expect(facts.withErrors.map(\.consoleErrorCount) == [6, 5, 4, 3, 2])
    }

    @Test("Not playable counts only mobile recordings")
    func replayAvailability() throws {
        let data = Data(#"""
        [
          {"id":"web","snapshot_source":"web"},
          {"id":"mobile","snapshot_source":"mobile"}
        ]
        """#.utf8)
        let recordings = try JSONDecoder().decode([SessionRecording].self, from: data)

        #expect(SessionOverviewFacts(recordings: recordings).notPlayableCount == 1)
    }

    @Test("Replay conditions map to stable branded glyphs")
    func glyphKinds() {
        #expect(SessionBrandAppearance.glyph(hasErrors: true, isReplayable: true) == .errorSession)
        #expect(SessionBrandAppearance.glyph(hasErrors: false, isReplayable: false) == .mobileSession)
        #expect(SessionBrandAppearance.glyph(hasErrors: false, isReplayable: true) == .session)
    }
}
