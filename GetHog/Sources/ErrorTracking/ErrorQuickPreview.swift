import Foundation
import GetHogKit
import GetHogUI
import SwiftUI

struct ErrorQuickPreviewPresentation: Equatable {
    let title: String
    let message: String?
    let status: String
    let occurrences: Int
    let sessions: Int
    let users: Int
    let lastSeen: Date?
    let assignment: String?
    let release: String?
    let environment: String?

    init(issue: ErrorIssue) {
        title = issue.name
        message = issue.issueDescription?.isEmpty == false ? issue.issueDescription : nil
        status = issue.statusTitle
        occurrences = Int(issue.occurrences)
        sessions = Int(issue.sessions)
        users = Int(issue.users)
        lastSeen = issue.lastSeen
        assignment = Self.assignment(for: issue.assignee)
        // ErrorIssue is the list model. It does not carry release or environment,
        // so this preview must not infer either one from stack/source metadata.
        release = nil
        environment = nil
    }

    var occurrenceText: String { Self.countText(occurrences, singular: "occurrence") }
    var sessionText: String { Self.countText(sessions, singular: "session") }
    var userText: String { Self.countText(users, singular: "user") }

    var accessibilitySummary: String {
        var parts = [title]
        if let message { parts.append(message) }
        parts.append("Status \(status)")
        parts.append(occurrenceText)
        parts.append(sessionText)
        parts.append(userText)
        if let lastSeen {
            parts.append("Last seen \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
        }
        if let assignment { parts.append("Assigned to \(assignment)") }
        if let release { parts.append("Release \(release)") }
        if let environment { parts.append("Environment \(environment)") }
        return parts.joinedAsSentences()
    }

    private static func assignment(for assignee: ErrorIssueAssignee?) -> String? {
        guard let assignee else { return nil }
        let kind = assignee.kind == .role ? "Role" : "User"
        return "\(kind) \(assignee.identifier.description)"
    }

    private static func countText(_ count: Int, singular: String) -> String {
        let noun = count == 1 ? singular : singular + "s"
        return "\(count) \(noun)"
    }
}

struct ErrorQuickPreview: View {
    let issue: ErrorIssue

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: ErrorQuickPreviewPresentation {
        ErrorQuickPreviewPresentation(issue: issue)
    }

    var body: some View {
        QuickPreviewCard(
            title: presentation.title,
            subtitle: presentation.message,
            systemImage: "ladybug.fill",
            accessibilitySummary: presentation.accessibilitySummary
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(presentation.status, systemImage: "circle.fill")
                facts
                if let lastSeen = presentation.lastSeen {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lastSeen, format: .dateTime.day().month().year().hour().minute())
                            Text(lastSeen, format: .relative(presentation: .named))
                                .font(.caption2)
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
                if let assignment = presentation.assignment {
                    Label("Assigned to \(assignment)", systemImage: "person.crop.circle")
                }
                if let release = presentation.release {
                    Label(release, systemImage: "shippingbox")
                }
                if let environment = presentation.environment {
                    Label(environment, systemImage: "server.rack")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityIdentifier("gethog.quick-preview.error.\(issue.id)")
    }

    private var facts: some View {
        let layout = if QuickPreviewLayout.factsAxis(for: dynamicTypeSize) == .vertical {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.m))
        }
        return layout {
            Label(presentation.occurrenceText, systemImage: "exclamationmark.triangle")
            Label(presentation.sessionText, systemImage: "rectangle.on.rectangle")
            Label(presentation.userText, systemImage: "person.2")
        }
    }
}
