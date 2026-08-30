import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Event Quick Preview")
struct EventQuickPreviewTests {
    @Test("the expanded preview keeps detail ordering, removes header duplicates, and caps properties")
    func orderedPropertiesExcludeHeaderDuplicates() throws {
        let row = try Self.event(
            properties: [
                "event": .string("Synthetic signup"),
                "timestamp": .string("2026-08-27T14:15:30Z"),
                "distinct_id": .string("synthetic-person-0001"),
                "$current_url": .string("https://example.invalid/account"),
                "copy_of_event": .string("Synthetic signup"),
                "copy_of_url": .string("https://example.invalid/account"),
                "alpha": .string("first"),
                "beta": .bool(false),
                "gamma": .number(3),
                "zeta": .string("fourth retained property"),
                "zz-over-limit": .string("not shown"),
            ]
        )

        #expect(
            EventQuickPreviewPresentation(row: row).properties == [
                .init(key: "alpha", value: "first"),
                .init(key: "beta", value: "false"),
                .init(key: "gamma", value: "3"),
                .init(key: "zeta", value: "fourth retained property"),
                .init(key: "zz-over-limit", value: "not shown"),
            ]
        )
    }

    @Test("collections become one-level shape summaries")
    func collectionsDoNotRecurse() throws {
        let row = try Self.event(
            properties: [
                "array": .array([.string("one"), .object(["nested": .bool(true)]), .null]),
                "object": .object(["left": .string("one"), "right": .array([.number(2)])]),
            ]
        )

        #expect(EventQuickPreviewPresentation(row: row).properties == [
            .init(key: "array", value: "[3 items]"),
            .init(key: "object", value: "{2 fields}"),
        ])
    }

    @Test("scalar values retain the detail view's formatting and display policy")
    func scalarsRemainStableAndUnredacted() throws {
        let longID = "synthetic-person-" + String(repeating: "0123456789", count: 12)
        let longPath = "/account/settings/billing/invoices/2026/08/a-long-synthetic-route-that-must-not-be-truncated"

        #expect(Self.value("bool", .bool(true)) == "true")
        #expect(Self.value("integer", .number(7)) == "7")
        #expect(Self.value("decimal", .number(1.5)) == "1.5")
        #expect(Self.value("null", .null) == "null")
        #expect(Self.value("distinct_copy", .string(longID)) == longID)
        #expect(Self.value("path_copy", .string(longPath)) == longPath)
        // Event detail displays scalar values verbatim, including sensitive-looking keys.
        #expect(Self.value("api_key", .string("synthetic-not-a-secret")) == "synthetic-not-a-secret")
    }

    @Test("the accessibility summary names the header and displayed property values")
    func accessibilitySummaryIsComplete() throws {
        let row = try Self.event(properties: ["answer": .number(42)])

        #expect(
            EventQuickPreviewPresentation(row: row).accessibilitySummary
                == "Synthetic signup. Timestamp 2026-08-27T14:15:30Z. Person synthetic-person-0001. URL https://example.invalid/account. answer, 42."
        )
    }

    @Test("a missing event timestamp remains unavailable instead of becoming the distant past")
    func missingTimestampStaysOptional() throws {
        let presentation = EventQuickPreviewPresentation(
            row: try Self.event(properties: [:], timestamp: .null)
        )

        #expect(presentation.timestamp == nil)
        #expect(presentation.accessibilitySummary.contains("Timestamp unavailable."))
        #expect(!presentation.accessibilitySummary.contains("0001-01-01"))
    }

    @Test("valid JSON 1e300 and nonfinite range edges format without trapping")
    func extremeNumericPropertiesAreSafe() throws {
        let huge = try JSONDecoder().decode(JSONValue.self, from: Data("1e300".utf8))

        #expect(Self.value("huge", huge) == String(1e300))
        #expect(Self.value("int_edge", .number(Double(Int.max))) == String(Double(Int.max)))
        #expect(
            Self.value("finite_edge", .number(.greatestFiniteMagnitude))
                == String(Double.greatestFiniteMagnitude)
        )
        #expect(Self.value("infinite", .number(.infinity)) == "Unavailable")
        #expect(Self.value("nan", .number(.nan)) == "Unavailable")
    }

    private static func value(_ key: String, _ value: JSONValue) -> String? {
        EventQuickPreviewPresentation(row: try! event(properties: [key: value])).properties.first?.value
    }

    private static func event(
        properties: [String: JSONValue],
        timestamp: JSONValue = .string("2026-08-27T14:15:30Z")
    ) throws -> EventRow {
        let row = EventRow(row: QueryRow(
            columns: ["uuid", "event", "timestamp", "distinct_id", "$current_url", "properties"],
            values: [
                .string("event-quick-preview-1"),
                .string("Synthetic signup"),
                timestamp,
                .string("synthetic-person-0001"),
                .string("https://example.invalid/account"),
                .object(properties),
            ]
        ))
        return try #require(row)
    }
}
