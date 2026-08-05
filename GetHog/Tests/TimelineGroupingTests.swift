import Foundation
import GetHogKit
import Testing
@testable import GetHog

/// The folding rules for `TimelineDisplayItem.grouped` — what may collapse
/// into a run, what must never, and where the boundaries fall.
@Suite("Timeline run grouping")
struct TimelineGroupingTests {

    private func entry(
        _ name: String,
        url: String = "https://app.example/s/demo/dashboard",
        at seconds: TimeInterval = 0,
        properties: [String: JSONValue] = [:]
    ) -> TimelineEntry {
        let origin = Date(timeIntervalSince1970: 1_000_000)
        let stamp = ISO8601DateFormatter().string(
            from: origin.addingTimeInterval(seconds)
        )
        let row = QueryRow(
            columns: ["uuid", "event", "timestamp", "$current_url", "properties"],
            values: [
                .string(UUID().uuidString),
                .string(name),
                .string(stamp),
                .string(url),
                .object(properties),
            ]
        )
        return TimelineEntry(event: EventRow(row: row)!, origin: origin)
    }

    @Test("three or more consecutive lookalikes fold into one run")
    func foldsRuns() {
        let items = TimelineDisplayItem.grouped([
            entry("$autocapture", at: 0),
            entry("$autocapture", at: 1),
            entry("$autocapture", at: 2),
            entry("$pageview", at: 3),
        ])
        #expect(items.count == 2)
        guard case .run(let run) = items[0] else {
            Issue.record("Expected a run first, got \(items[0])")
            return
        }
        #expect(run.count == 3)
        guard case .single = items[1] else {
            Issue.record("Expected the lone pageview to stay single")
            return
        }
    }

    @Test("two lookalikes stay as rows — a ×2 costs more than it saves")
    func pairsStaySingle() {
        let items = TimelineDisplayItem.grouped([
            entry("$autocapture", at: 0),
            entry("$autocapture", at: 1),
        ])
        #expect(items.count == 2)
        for item in items {
            guard case .single = item else {
                Issue.record("A pair must not fold")
                return
            }
        }
    }

    @Test("a different URL breaks the run even when the name repeats")
    func urlBreaksRuns() {
        let items = TimelineDisplayItem.grouped([
            entry("$autocapture", url: "https://app.example/a", at: 0),
            entry("$autocapture", url: "https://app.example/a", at: 1),
            entry("$autocapture", url: "https://app.example/a", at: 2),
            entry("$autocapture", url: "https://app.example/b", at: 3),
            entry("$autocapture", url: "https://app.example/b", at: 4),
            entry("$autocapture", url: "https://app.example/b", at: 5),
        ])
        #expect(items.count == 2)
        for item in items {
            guard case .run(let run) = item else {
                Issue.record("Both URL groups should fold separately")
                return
            }
            #expect(run.count == 3)
        }
    }

    @Test("errors never fold, and never let neighbours fold across them")
    func errorsNeverFold() {
        let items = TimelineDisplayItem.grouped([
            entry("$autocapture", at: 0),
            entry("$autocapture", at: 1),
            entry("$exception", at: 2),
            entry("$autocapture", at: 3),
            entry("$autocapture", at: 4),
        ])
        // 2 autocaptures (below threshold, single), the exception, 2 more.
        #expect(items.count == 5)
        guard case .single(let middle) = items[2] else {
            Issue.record("The exception must stand alone")
            return
        }
        #expect(middle.isError)
    }

    @Test("custom events never fold — they are what a session is scanned for")
    func customNeverFolds() {
        let items = TimelineDisplayItem.grouped([
            entry("checkout_completed", at: 0),
            entry("checkout_completed", at: 1),
            entry("checkout_completed", at: 2),
        ])
        #expect(items.count == 3)
        for item in items {
            guard case .single = item else {
                Issue.record("Custom events must never fold")
                return
            }
        }
    }
}
