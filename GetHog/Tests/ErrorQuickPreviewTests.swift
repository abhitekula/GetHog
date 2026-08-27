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

    private static func issue(id: String, status: String, assignee: String?) throws -> ErrorIssue {
        let assigneeField = assignee.map { ", \"assignee\": \($0)" } ?? ""
        return try JSONDecoder().decode(
            ErrorIssue.self,
            from: Data(
                """
                {
                  "id": "\(id)",
                  "name": "SyntheticNetworkFault",
                  "description": "Synthetic checkout request timed out.",
                  "status": "\(status)",
                  "last_seen": "2026-08-27T12:00:00Z",
                  "aggregations": {"occurrences": 42, "sessions": 11, "users": 7}
                  \(assigneeField)
                }
                """.utf8
            )
        )
    }
}
