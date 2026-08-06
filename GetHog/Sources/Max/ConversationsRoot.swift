import GetHogKit
import SwiftUI

@MainActor
@Observable
final class ConversationsStore {
    var conversations: [MaxConversation] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<MaxConversation> = try await client.send(
                PostHogAPI.conversations(projectID: projectID)
            )
            conversations = MaxConversation.newestFirst(page.results)
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// Max AI threads, read-only.
///
/// There is deliberately no way to send a message from here. Posting to this
/// resource starts an agent run against the user's account and their AI budget,
/// which is not something a viewer should be able to trigger from a list row.
struct ConversationsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = ConversationsStore()
    @State private var search = ""

    /// The open conversation, held in `OpenDetails` rather than pushed as a value onto
    /// the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it, and a value on
    /// the host's stack goes when the host does.
    private var selection: Binding<MaxConversation?> {
        Binding(
            get: { openDetails[.max] as? MaxConversation },
            set: { openDetails[.max] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        content
            .navigationTitle("Max")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search conversations")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
            .navigationDestination(item: selection) { conversation in
                ConversationDetailView(conversation: conversation)
            }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.conversations.isEmpty {
            EmptyStateView(
                title: "Couldn't load conversations",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.conversations.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No Max conversations",
                systemImage: "sparkles",
                message: "Threads you start with Max in PostHog will appear here. Only titled conversations are listed."
            )
        } else {
            list
        }
    }

    /// Selection-driven: the binding on the `List` makes a row tap set
    /// `selection`, and `navigationDestination(item:)` in `body` displays it.
    private var list: some View {
        List(selection: selection) {
            Section {
                if filtered.isEmpty {
                    Text("No conversations matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filtered) { conversation in
                        NavigationLink(value: conversation) {
                            ConversationRowView(conversation: conversation)
                        }
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                SectionLabel(text: "Threads", systemImage: "bubble.left.and.bubble.right")
            } footer: {
                Text("GetHog reads Max threads. Asking Max something new stays in the PostHog web console.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.conversations.isEmpty)
    }

    private var filtered: [MaxConversation] {
        guard !search.isEmpty else { return store.conversations }
        return store.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || ($0.authorName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Row

struct ConversationRowView: View {
    let conversation: MaxConversation

    var body: some View {
        DataRow(
            glyph: conversation.kind.systemImage,
            title: conversation.title,
            subtitle: conversation.kind.title,
            footnote: secondaryLine,
            accessory: statusAccessory
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Only surfaced while Max is still working; "Idle" on every row would be
    /// noise hiding the one row that isn't.
    private var statusAccessory: RowAccessory {
        conversation.status == .inProgress
            ? .pill(conversation.status.title, Theme.accent)
            : .none
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let author = conversation.authorName { parts.append(author) }
        if let activity = conversation.lastActivityAt {
            parts.append(activity.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? "No activity recorded" : parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = [conversation.title, conversation.kind.title]
        if conversation.status == .inProgress { parts.append("Max is still working") }
        parts.append(secondaryLine)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

@MainActor
@Observable
final class ConversationDetailStore {
    var thread: MaxConversationThread?
    var isLoading = false
    var error: String?

    func load(client: PostHogClient, projectID: Int, conversationID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            thread = try await client.send(
                PostHogAPI.conversation(projectID: projectID, conversationID: conversationID)
            )
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// One Max thread, rendered read-only.
///
/// Messages come only from `GET /conversations/{id}/` — the list serializer
/// omits them. Max's message union grows with every agent feature, so a message
/// this version cannot render as text is *named* rather than skipped: a silently
/// dropped reply makes the thread look like Max never answered.
struct ConversationDetailView: View {
    let conversation: MaxConversation

    @Environment(AppModel.self) private var model
    @State private var store = ConversationDetailStore()

    var body: some View {
        List {
            Section {
                LabeledContent("Started by") { Text(conversation.authorName ?? "Unknown") }
                LabeledContent("Kind") { Text(conversation.kind.title) }
                LabeledContent("Status") { Text(conversation.status.title) }
                if let created = conversation.createdAt {
                    LabeledContent("Started") {
                        Text(created, format: .relative(presentation: .named))
                    }
                }
                if let updated = conversation.updatedAt {
                    LabeledContent("Last activity") {
                        Text(updated, format: .relative(presentation: .named))
                    }
                }
                if let workspace = conversation.slackWorkspace {
                    LabeledContent("Slack workspace") { Text(workspace) }
                }
            } header: {
                SectionLabel(text: "Thread", systemImage: conversation.kind.systemImage)
            }

            transcript

            Section {
                if let url = model.webURL(path: "max") {
                    Link(destination: url) {
                        Label("Open Max in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
            } footer: {
                Text("Read-only. GetHog does not send messages to Max — that would start a new agent run on your account.")
            }
        }
        .pageSurface()
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var transcript: some View {
        Section {
            if store.isLoading && store.thread == nil {
                Text(String(repeating: "Loading this conversation ", count: 5))
                    .font(.callout)
                    .skeleton(true)
            } else if let error = store.error {
                EmptyStateView(
                    title: "Couldn't load this conversation",
                    systemImage: "exclamationmark.triangle",
                    message: error,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
            } else if let thread = store.thread {
                if thread.messages.isEmpty {
                    EmptyStateView(
                        title: "No messages stored",
                        systemImage: "bubble.left",
                        message: "PostHog kept the conversation's title but not its transcript."
                    )
                } else {
                    ForEach(thread.messages) { message in
                        MaxMessageRowView(message: message)
                    }
                }
            }
        } header: {
            SectionLabel(text: "Transcript", systemImage: "text.bubble")
        } footer: {
            if store.thread?.hasUnsupportedContent == true {
                Text("PostHog reports that part of this thread cannot be rendered outside its own editor.")
            }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, conversationID: conversation.id)
    }
}

struct MaxMessageRowView: View {
    let message: MaxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(roleTint(message.role))

            if let text = message.text {
                // Max writes markdown; printing it raw put literal backticks
                // and `- ` bullets on screen. Inline-only: block structure
                // stays as typed, but code spans, bold and links render.
                Text(Self.inlineMarkdown(text))
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                Text(placeholder)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role.title): \(message.text ?? placeholder)")
    }

    private var placeholder: String {
        switch message.role {
        case .visualization: "A chart Max built. Open the thread in PostHog to see it."
        case .tool: "Max used a tool here."
        default: "Not shown on mobile."
        }
    }

    /// Inline markdown only; a parse failure falls back to the verbatim text,
    /// never to an empty message.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }
}

// MARK: - Formatting

private func roleTint(_ role: MaxMessageRole) -> Color {
    switch role {
    case .person: Theme.accent
    case .failure: Theme.Status.critical
    default: .secondary
    }
}
