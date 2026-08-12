import GetHogKit
import GetHogUI
import SwiftUI

// MARK: - Store

@MainActor
@Observable
final class CommentsStore {
    private(set) var comments: [GetHogKit.Comment] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasLoaded = false

    /// One request, for one object.
    ///
    /// Deliberately not paired with `commentCount`: that would spend two
    /// requests against an organisation-wide budget to learn one thing, and the
    /// thread this returns already answers "how many" for everything a phone
    /// can show at once.
    func load(client: PostHogClient, projectID: Int, scope: CommentScope, itemID: String) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let page: Page<GetHogKit.Comment> = try await client.send(
                PostHogAPI.comments(projectID: projectID, scope: scope, itemID: itemID)
            )
            // The API returns newest first; a thread is read oldest first, and
            // rendering the response order puts a reply above what it answers.
            comments = page.results
                .filter { !$0.deleted }
                .sorted(by: GetHogKit.Comment.oldestFirst)
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    var openTaskCount: Int {
        comments.filter { $0.isTask && !$0.isCompleted }.count
    }
}

// MARK: - Section

/// The comment thread on one PostHog object.
///
/// **Why this is a section and not a tab.** Comments are keyed by `scope` +
/// `item_id`: every one is an annotation *on* something — an insight, a
/// dashboard, a recording. A Comments tab would be a list of sentences with
/// their subjects removed, where the only way to learn what "the dip on the
/// 24th" refers to is to go and open the insight anyway. So the thread lives
/// where the thing it is about lives.
///
/// It sits on insight detail specifically because that is the object PostHog's
/// own users comment on most, and because one insertion covers both
/// presentations — the iPad side panel and the iPhone sheet share this body.
///
/// Read-only. Posting needs `comment:write`, a scope this app does not ask for;
/// see `PostHogAPI.comments`.
struct CommentsSection: View {
    let scope: CommentScope
    let itemID: String

    @Environment(AppModel.self) private var model
    @State private var store = CommentsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: header, systemImage: "bubble.left.and.text.bubble.right")

            content
        }
        .task(id: itemID) { await load() }
    }

    private var header: String {
        guard !store.comments.isEmpty else { return "Comments" }
        let open = store.openTaskCount
        return open > 0 ? "Comments · \(open) open" : "Comments"
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error {
            SectionEmptyState(
                text: "Couldn't load comments for this insight.",
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                detail: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.comments.isEmpty {
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Compact on purpose: this is a section of a scrolling detail
                // view, and a full `ContentUnavailableView` here would push the
                // chart it belongs to off the screen. It still says what the
                // surface is for rather than shrugging.
                SectionEmptyState(
                    text: "No comments on this insight. PostHog threads discussion onto the "
                        + "object it's about, so a note left here in the web console — or a "
                        + "task raised on it — would appear at this point.",
                    systemImage: "bubble.left.and.text.bubble.right"
                )
            }
        } else {
            VStack(spacing: Theme.Space.s) {
                ForEach(store.comments) { comment in
                    CommentRow(comment: comment)
                }
            }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, scope: scope, itemID: itemID)
    }
}

// MARK: - Row

private struct CommentRow: View {
    let comment: GetHogKit.Comment

    var body: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(comment.displayAuthor)
                        .font(Theme.Typography.body.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: Theme.Space.s)

                    if let created = comment.createdAt {
                        Text(created, format: .relative(presentation: .named))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Ink.tertiary)
                            .lineLimit(1)
                    }
                }

                Text(comment.content)
                    .font(Theme.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let badge {
                    // Word plus glyph, never a colour on its own — done and open
                    // have to be distinguishable in greyscale.
                    Label(badge.text, systemImage: badge.glyph)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Status.ink(for: badge.tint))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /// Only states that vary get a badge. `is_task` is immutable after creation
    /// and impossible on a reply, so what changes — and what is worth showing —
    /// is whether the task has been completed.
    private var badge: (text: String, glyph: String, tint: Color)? {
        if comment.isTask {
            return comment.isCompleted
                ? ("Done", "checkmark.circle.fill", Theme.Status.good)
                : ("Open task", "circle", Theme.accentWarm)
        }
        if case .unknown = comment.type {
            // A type this client has not learned still says what it is, rather
            // than being rendered as a plain comment it may not be.
            return (comment.type.title, "sparkles", Theme.neutralMark)
        }
        if comment.type == .review {
            return ("Review", "text.magnifyingglass", Theme.accent)
        }
        return nil
    }

    private var spoken: String {
        // `content` is whatever the author typed, and people end comments with a
        // full stop, so the badge cannot assume it is starting a fresh sentence.
        var text = ["\(comment.displayAuthor): \(comment.content)", badge?.text]
            .compactMap { $0 }
            .joinedAsSentences()
        // Stays a clause: "completed by" reads as part of the badge it follows,
        // not as a statement of its own.
        if comment.isCompleted, let by = comment.completedBy { text += ", completed by \(by)" }
        return text
    }
}
