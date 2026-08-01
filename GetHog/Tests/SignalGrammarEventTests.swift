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
}
