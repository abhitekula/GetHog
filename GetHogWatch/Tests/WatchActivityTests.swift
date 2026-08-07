import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch activity")
struct WatchActivityTests {

    private func response(_ json: String) throws -> QueryResponse {
        try QueryResponse.decode(from: Data(json.utf8))
    }

    @Test("a response longer than the cap is cut to it")
    func capsTheRowCount() throws {
        let lines = WatchActivity.lines(from: try response(WatchFixtures.events(30)))
        #expect(lines.count == WatchActivity.maxLines)
    }

    @Test("an event name longer than one wrist line is trimmed, not wrapped")
    func trimsLongEventNames() throws {
        let long = String(repeating: "e", count: 70)
        let lines = WatchActivity.lines(from: try response("""
            {"columns":["uuid","event","timestamp","distinct_id"],
             "results":[["example-row-0001","\(long)","2026-01-18T12:00:00.000Z","person-example-1"]]}
            """))

        #expect(lines.count == 1)
        #expect(lines[0].event.count == WatchActivity.maxEventNameLength)
        #expect(lines[0].event == String(repeating: "e", count: 60))
    }

    @Test("the server's order is the order shown — newest first, no re-sorting")
    func preservesServerOrder() throws {
        let lines = WatchActivity.lines(from: try response(WatchFixtures.events(3)))
        #expect(lines.map(\.event) == ["example_event_0", "example_event_1", "example_event_2"])
    }

    @Test("a row with neither a uuid nor a timestamp still gets a stable identity")
    func toleratesMissingColumns() throws {
        let lines = WatchActivity.lines(from: try response("""
            {"columns":["event"],"results":[["example_event_0"],["example_event_0"]]}
            """))

        #expect(lines.count == 2)
        #expect(lines[0].timestamp == nil)
        // Two identical events must not collapse into one row in a ForEach.
        #expect(lines[0].id != lines[1].id)
    }

    @Test("an empty response draws nothing rather than a zero")
    func emptyResponseYieldsNoLines() throws {
        let lines = WatchActivity.lines(from: try response("""
            {"columns":["uuid","event","timestamp","distinct_id"],"results":[]}
            """))
        #expect(lines.isEmpty)
    }

    @Test("a row with no event name says so rather than rendering blank")
    func missingEventNameIsNamed() throws {
        let lines = WatchActivity.lines(from: try response("""
            {"columns":["uuid","timestamp"],
             "results":[["example-row-0001","2026-01-18T12:00:00.000Z"]]}
            """))

        #expect(lines.count == 1)
        #expect(lines[0].event == "unknown event")
        #expect(lines[0].id == "example-row-0001")
    }
}
