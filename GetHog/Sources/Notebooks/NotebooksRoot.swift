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
            ContentUnavailableView {
                Label("Couldn't load notebooks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.notebooks.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No notebooks",
                systemImage: "book.closed",
                description: Text(
                    "Notebooks written in the PostHog web console will appear here."
                )
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
                } else {
                    ForEach(filtered) { notebook in
                        NavigationLink(value: notebook) {
                            NotebookRowView(notebook: notebook)
                        }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(notebook.title)
                .font(.body)
                .lineLimit(2)

            Text(secondaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func contents(for notebook: Notebook) -> some View {
        Section("Contents") {
            if store.isLoading && store.notebook == nil {
                Text(String(repeating: "Loading notebook text ", count: 6))
                    .font(.callout)
                    .skeleton(true)
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Couldn't load this notebook", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else if let text = notebook.textContent {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            } else if notebook.isRichContentOnly {
                ContentUnavailableView(
                    "Nothing to show as text",
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text(
                        "This notebook is made entirely of charts, queries or images. Open it in PostHog to read it."
                    )
                )
            } else {
                ContentUnavailableView(
                    "This notebook is empty",
                    systemImage: "doc",
                    description: Text("It has been created but nothing has been written in it yet.")
                )
            }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, shortID: summary.shortID)
    }
}
