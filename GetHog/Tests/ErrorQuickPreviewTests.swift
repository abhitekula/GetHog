import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Error Quick Preview")
struct ErrorQuickPreviewTests {
    @Test("an active list issue preserves every available preview fact")
    func activeIssuePreservesAvailableFacts() throws {
        let issue = try Self.issue(
            id: "error-quick-preview-active",
            status: "active",
            assignee: #"{"id":707,"type":"user"}"#
        )

        let presentation = ErrorQuickPreviewPresentation(issue: issue)

        #expect(presentation.title == "SyntheticNetworkFault")
        #expect(presentation.message == "Synthetic checkout request timed out.")
        #expect(presentation.status == "Active")
        #expect(presentation.occurrences == 42)
        #expect(presentation.sessions == 11)
        #expect(presentation.users == 7)
        #expect(presentation.lastSeen == Date(timeIntervalSince1970: 1_787_832_000))
        #expect(presentation.assignment == "User 707")
        #expect(presentation.release == nil)
        #expect(presentation.environment == nil)
    }

    @Test("a triage-effective resolved issue is presented as resolved")
    func triageEffectiveResolvedIssueIsPresentedAsResolved() throws {
        let effectiveIssue = try Self.issue(
            id: "error-quick-preview-resolved",
            status: "active",
            assignee: nil
        )
        .withStatus(.resolved)

        let presentation = ErrorQuickPreviewPresentation(issue: effectiveIssue)

        #expect(presentation.status == "Resolved")
        #expect(presentation.assignment == nil)
    }

    @Test("a triage-effective suppressed issue remains a read-only presentation")
    func triageEffectiveSuppressedIssueRemainsReadOnly() throws {
        let effectiveIssue = try Self.issue(
            id: "error-quick-preview-suppressed",
            status: "active",
            assignee: #"{"id":"synthetic-on-call","type":"role"}"#
        )
        .withStatus(.suppressed)

        let presentation = ErrorQuickPreviewPresentation(issue: effectiveIssue)

        #expect(presentation.status == "Suppressed")
        #expect(presentation.assignment == "Role synthetic-on-call")
        #expect(!presentation.accessibilitySummary.contains("Resolve issue"))
        #expect(!presentation.accessibilitySummary.contains("Suppress issue"))
        #expect(!presentation.accessibilitySummary.contains("Assign issue"))
    }

    @Test("valid JSON 1e300, range edges, and nonfinite counts never trap")
    func extremeCountsAreFormattedSafely() throws {
        let extreme = ErrorQuickPreviewPresentation(issue: try Self.issue(
            id: "error-quick-preview-extreme",
            status: "active",
            assignee: nil,
            occurrences: "1e300",
            sessions: String(Double(Int.max)),
            users: String(Double.greatestFiniteMagnitude)
        ))

        #expect(extreme.occurrenceText == "\(String(1e300)) occurrences")
        #expect(extreme.sessionText == "\(String(Double(Int.max))) sessions")
        #expect(extreme.userText == "\(String(Double.greatestFiniteMagnitude)) users")

        let nonfinite = ErrorQuickPreviewPresentation(issue: try Self.issue(
            id: "error-quick-preview-nonfinite",
            status: "active",
            assignee: nil,
            occurrences: #""Infinity""#,
            sessions: #""-Infinity""#,
            users: #""NaN""#,
            decodeNonFinite: true
        ))

        #expect(nonfinite.occurrenceText == "Occurrences unavailable")
        #expect(nonfinite.sessionText == "Sessions unavailable")
        #expect(nonfinite.userText == "Users unavailable")
    }

    private static func issue(
        id: String,
        status: String,
        assignee: String?,
        occurrences: String = "42",
        sessions: String = "11",
        users: String = "7",
        decodeNonFinite: Bool = false
    ) throws -> ErrorIssue {
        let assigneeField = assignee.map { ", \"assignee\": \($0)" } ?? ""
        let decoder = JSONDecoder()
        if decodeNonFinite {
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity",
                negativeInfinity: "-Infinity",
                nan: "NaN"
            )
        }
        return try decoder.decode(
            ErrorIssue.self,
            from: Data(
                """
                {
                  "id": "\(id)",
                  "name": "SyntheticNetworkFault",
                  "description": "Synthetic checkout request timed out.",
                  "status": "\(status)",
                  "last_seen": "2026-08-27T12:00:00Z",
                  "aggregations": {
                    "occurrences": \(occurrences),
                    "sessions": \(sessions),
                    "users": \(users)
                  }
                  \(assigneeField)
                }
                """.utf8
            )
        )
    }
}
