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

    @Test("a feed that was never fetched is not reported as an empty one")
    func footerSeparatesUncheckedFromEmpty() {
        let now = WatchFixtures.now
        #expect(
            WatchActivityFooter.text(lineCount: 0, capturedAt: nil, now: now)
                == "Not checked yet"
        )
        #expect(
            WatchActivityFooter.text(
                lineCount: 0, capturedAt: now.addingTimeInterval(-600), now: now
            ) == "No events in the last \(QueryBudget.wrist.hours) h · updated 10 min ago"
        )
        #expect(
            WatchActivityFooter.text(
                lineCount: 4, capturedAt: now.addingTimeInterval(-600), now: now
            ) == "Last \(QueryBudget.wrist.hours) h · newest \(QueryBudget.wrist.pageSize) "
                + "· updated 10 min ago"
        )
    }

    @Test("the feed round-trips through the watch-local file it is carried in")
    func feedRoundTripsThroughTheStore() throws {
        let store = WatchFixtures.tempStore()
        #expect(WatchActivity.read(from: store) == nil)

        let feed = ActivityFeed(
            lines: [ActivityLine(id: "example-row-0001", event: "example_event_0", timestamp: nil)],
            capturedAt: WatchFixtures.now
        )
        try WatchActivity.write(feed, to: store)

        #expect(WatchActivity.read(from: store) == feed)
    }

    /// The file outlives the build that wrote it, so the cap has to hold on
    /// the way in as well as on the way out — a downgrade, or the page-size
    /// reduction this app has already been through, hands the reader a longer
    /// feed than it is willing to draw.
    @Test("a longer feed than this build draws is cut on read, not trusted")
    func readEnforcesTheCapAsWellAsWrite() throws {
        let store = WatchFixtures.tempStore()
        let overlong = (0..<(WatchActivity.maxLines + 15)).map { index in
            ActivityLine(
                id: "example-row-\(String(format: "%04d", index))",
                event: "example_event_\(index)",
                timestamp: nil
            )
        }
        try WatchActivity.write(
            ActivityFeed(lines: overlong, capturedAt: WatchFixtures.now), to: store
        )

        let read = try #require(WatchActivity.read(from: store))
        #expect(read.lines.count == WatchActivity.maxLines)
        // Cut from the tail: the newest rows are the ones worth keeping.
        #expect(read.lines.first?.event == "example_event_0")
        #expect(read.capturedAt == WatchFixtures.now)
    }

    @Test("the cap is the wrist budget's page size, not a number beside it")
    func capComesFromTheBudget() {
        #expect(WatchActivity.maxLines == QueryBudget.wrist.pageSize)
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
