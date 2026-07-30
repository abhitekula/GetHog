import GetHogKit
import SwiftUI

@MainActor
@Observable
final class NotebooksStore {
    var notebooks: [Notebook] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<Notebook> = try await client.send(
                PostHogAPI.notebooks(projectID: projectID)
            )
            // Most recently edited first: a notebook is a working document, and
            // the one you touched last is the one you came back for.
            notebooks = page.results
                .filter { !$0.deleted }
                .sorted {
                    ($0.lastModifiedAt ?? $0.createdAt ?? .distantPast)
                        > ($1.lastModifiedAt ?? $1.createdAt ?? .distantPast)
                }
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

struct NotebooksRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = NotebooksStore()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Notebooks")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search notebooks")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
                .navigationDestination(for: Notebook.self) { notebook in
                    NotebookDetailView(summary: notebook)
                }
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
        } else if let error = store.error, store.notebooks.isEmpty {
            EmptyStateView(
                title: "Couldn't load notebooks",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.notebooks.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No notebooks",
                systemImage: "book.closed",
                message: "A notebook is a written document with charts and queries embedded in it, composed in the PostHog web console. Nobody has started one in this project — notebooks are a place to write up an investigation, not something a project accumulates on its own."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                if filtered.isEmpty {
                    Text("No notebooks matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { notebook in
                        NavigationLink(value: notebook) {
                            NotebookRowView(notebook: notebook)
                        }
                        .notebooksRowCard()
                    }
                }
            } footer: {
                // Stated once, here, rather than as an empty snippet line on
                // every row: `GET /notebooks/` serialises without `content` or
                // `text_content`, so a preview genuinely is not available yet.
                Text("Open a notebook to read it — the list only carries titles.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.notebooks.isEmpty)
    }

    private var filtered: [Notebook] {
        guard !search.isEmpty else { return store.notebooks }
        return store.notebooks.filter {
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

struct NotebookRowView: View {
    let notebook: Notebook

    var body: some View {
        DataRow(
            glyph: "book.closed",
            tint: Theme.accent,
            title: notebook.title,
            subtitle: secondaryLine,
            // No footnote and no snippet: the list payload carries neither, and
            // a placeholder line on every row would imply one is coming.
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notebook.title), \(secondaryLine)")
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let author = notebook.authorName { parts.append(author) }
        if let modified = notebook.lastModifiedAt {
            parts.append("edited \(modified.formatted(.relative(presentation: .named)))")
        } else if let created = notebook.createdAt {
            parts.append("created \(created.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? "No edit history" : parts.joined(separator: " · ")
    }
}

// MARK: - Detail

@MainActor
@Observable
final class NotebookDetailStore {
    var notebook: Notebook?
    var isLoading = false
    var error: String?

    func load(client: PostHogClient, projectID: Int, shortID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            notebook = try await client.send(
                PostHogAPI.notebook(projectID: projectID, shortID: shortID)
            )
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// A notebook, rendered as the plain text PostHog stores alongside its blocks.
///
/// The `content` tree is ProseMirror: headings, paragraphs, queries, embedded
/// insights, images. A partial renderer for it would drop the blocks it doesn't
/// know about *silently*, which on a notebook — a document whose point is the
/// charts in it — reads as a shorter document rather than an incomplete one.
/// Plain text plus a link out is the honest version.
struct NotebookDetailView: View {
    let summary: Notebook

    @Environment(AppModel.self) private var model
    @State private var store = NotebookDetailStore()

    private var notebook: Notebook { store.notebook ?? summary }

    var body: some View {
        List {
            Section {
                LabeledContent("Short ID") {
                    Text(notebook.shortID).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let author = notebook.authorName {
                    LabeledContent("Created by") { Text(author) }
                }
                if let created = notebook.createdAt {
                    LabeledContent("Created") {
                        Text(created, format: .relative(presentation: .named))
                    }
                }
                if let modified = notebook.lastModifiedAt {
                    LabeledContent("Last edited") {
                        Text(modified, format: .relative(presentation: .named))
                    }
                }
            } header: {
                SectionLabel(text: "Notebook", systemImage: "book.closed")
            }

            contents(for: notebook)

            Section {
                if let url = model.webURL(path: "notebooks/\(notebook.shortID)") {
                    Link(destination: url) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
            } footer: {
                Text("GetHog shows a notebook's text. Its charts, queries and embedded insights are drawn in the web console.")
            }
        }
        .pageSurface()
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func contents(for notebook: Notebook) -> some View {
        Section {
            if store.isLoading && store.notebook == nil {
                Text(String(repeating: "Loading notebook text ", count: 6))
                    .font(.callout)
                    .skeleton(true)
            } else if let error = store.error {
                EmptyStateView(
                    title: "Couldn't load this notebook",
                    systemImage: "exclamationmark.triangle",
                    message: error,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
            } else if let text = notebook.textContent {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            } else if notebook.isRichContentOnly {
                EmptyStateView(
                    title: "Nothing to show as text",
                    systemImage: "chart.bar.doc.horizontal",
                    message: "This notebook is made entirely of charts, queries or images. Open it in PostHog to read it."
                )
            } else {
                EmptyStateView(
                    title: "This notebook is empty",
                    systemImage: "doc",
                    message: "It has been created but nothing has been written in it yet."
                )
            }
        } header: {
            SectionLabel(text: "Contents", systemImage: "text.alignleft")
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, shortID: summary.shortID)
    }
}

// MARK: - Row chrome
//
// File-private so concurrent work on other screens can't collide with the name.

private extension View {
    /// The list treatment from the dashboards screen: every row is its own card
    /// on the page ground, with the system separator suppressed because the gap
    /// between cards already does that work.
    func notebooksRowCard() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}
