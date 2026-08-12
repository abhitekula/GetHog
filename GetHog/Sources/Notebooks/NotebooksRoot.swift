import GetHogKit
import GetHogUI
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
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = NotebooksStore()
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle("Notebooks")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search notebooks")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
            .navigationDestination(item: selection) { notebook in
                NotebookDetailView(summary: notebook)
            }
    }

    /// The open notebook, held in `OpenDetails` rather than pushed as a value
    /// onto the container's path.
    ///
    /// This screen is one of `AppTab.secondary`: hosted by a sidebar `Tab` above
    /// the size-class boundary and by the search stack below it, and a value on
    /// the host's stack goes when the host does.
    private var selection: Binding<Notebook?> {
        Binding(
            get: { openDetails[.notebooks] as? Notebook },
            set: { openDetails[.notebooks] = $0.map(AnyHashable.init) }
        )
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
                illustration: .workspace,
                message: "A notebook is a written document with charts and queries embedded in it, composed in the PostHog web console. Nobody has started one in this project — notebooks are a place to write up an investigation, not something a project accumulates on its own."
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
                    Text("No notebooks matched “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(Theme.Ink.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { notebook in
                        NavigationLink(value: notebook) {
                            NotebookRowView(notebook: notebook)
                        }
                        .notebooksRowCard(id: notebook.shortID)
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
    /// A summary fit for a reader, with the verbatim fault kept separately.
    ///
    /// This used to be a bare `String` holding `PostHogError.localizedDescription`,
    /// which for `.decoding` is a `String(describing: DecodingError)` — a Swift
    /// dump, printed at the reader as the message. It was reachable: demo mode
    /// does not route `/notebooks/:shortID/`, so the request fell through to an
    /// empty page whose `{"count": 0, "results": []}` has no `id`, the decode
    /// threw `keyNotFound`, and the screen showed it. Every *list* screen escapes
    /// this because `Page<T>` never has to decode an element.
    ///
    /// `LoadFailure` is the pattern the rest of the app already uses for exactly
    /// this: it asks `hasReadableDescription` and substitutes a written sentence
    /// when the error cannot describe itself, keeping the dump behind a
    /// disclosure for whoever can use it. The decoder was loosened as well —
    /// `Notebook` now needs only one of `id`/`short_id` — so a real notebook
    /// missing one no longer reaches this path at all.
    var failure: LoadFailure?

    func load(client: PostHogClient, projectID: Int, shortID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            notebook = try await client.send(
                PostHogAPI.notebook(projectID: projectID, shortID: shortID)
            )
            failure = nil
        } catch {
            failure = LoadFailure(error, loading: "notebook")
        }
    }
}

/// A notebook, rendered from its ProseMirror `content` tree.
///
/// This screen used to show `text_content` and a link out, on the reasoning that
/// a partial renderer would drop unknown blocks *silently* — which on a notebook,
/// a document whose point is often the charts in it, reads as a shorter document
/// rather than an incomplete one. That reasoning was right about the failure
/// mode and wrong about the remedy: the fix for silent dropping is to stop
/// dropping silently, not to stop rendering. `NotebookUnsupportedBlock` names
/// every node this build cannot draw, in place, so the document's shape survives
/// even where its content does not.
struct NotebookDetailView: View {
    let summary: Notebook

    @Environment(AppModel.self) private var model
    @State private var store = NotebookDetailStore()
    /// A recording opened from an embedded `ph-recording` block.
    ///
    /// Pushed from here rather than from the block so the destination is
    /// declared once. It is a push *below* an already-open secondary screen, so
    /// unlike the notebook itself — which `OpenDetails` keeps across the
    /// compact-width boundary — an open recording is lost when the window
    /// crosses it and SwiftUI swaps hosts. The notebook underneath survives, so
    /// the reader lands back on the block they tapped, which is the recoverable
    /// half of the two.
    @State private var openRecording: SessionRecording?
    /// Owned here rather than by each block — see `NotebookInsightCache`.
    @State private var insightCache = NotebookInsightCache()

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
                Text(footerText)
            }
        }
        .pageSurface()
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.notebookRecordingOpener) { openRecording = $0 }
        .navigationDestination(item: $openRecording) { SessionDetailView(recording: $0) }
        .task { await load() }
        .refreshable { await load() }
    }

    /// Named once, at the foot of the document, rather than as a badge on every
    /// block: a reader who has just scrolled past four unsupported cards does
    /// not need a fifth explanation, they need to know what the document as a
    /// whole is missing.
    private var footerText: String {
        guard let document = store.notebook?.document else {
            return "Notebooks are composed in the PostHog web console."
        }
        let missing = document.unsupportedTypeNames
        guard !missing.isEmpty else {
            return "Notebooks are composed in the PostHog web console."
        }
        let list = missing.map { $0.lowercased() }.formatted(.list(type: .and))
        return "This notebook also contains \(list). Those blocks aren't drawn here — open it in PostHog to see them."
    }

    @ViewBuilder
    private func contents(for notebook: Notebook) -> some View {
        Section {
            if store.isLoading && store.notebook == nil {
                Text(String(repeating: "Loading notebook ", count: 6))
                    .font(.callout)
                    .skeleton(true)
            } else if let failure = store.failure, store.notebook == nil {
                // This is one row of the Contents section, so keep the failure
                // compact while preserving the same summary, disclosed detail,
                // and retry path as the whole-screen `LoadFailureState`.
                SectionEmptyState(
                    text: "Couldn't load this notebook. \(failure.summary)",
                    systemImage: "exclamationmark.triangle",
                    detail: failure.detail,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
            } else {
                documentBody(of: notebook)
            }
        } header: {
            SectionLabel(text: "Contents", systemImage: "text.alignleft")
        }
    }

    @ViewBuilder
    private func documentBody(of notebook: Notebook) -> some View {
        switch notebook.readingStrategy {
        case .richContent:
            // Each block is its own row so a long notebook stays scrollable at
            // AX5 and so `Text` selection works per block rather than fighting
            // one enormous string. Index-keyed because two identical paragraphs
            // are a normal thing for a document to contain.
            let blocks = notebook.document?.blocks ?? []
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                NotebookBlockRow(block: block, insightCache: insightCache)
                    .listRowSeparator(.hidden)
            }

        case .plainTextFallback:
            // Says what it is doing rather than pretending this is the document.
            // The likely cause is PostHog's newer markdown notebook format,
            // whose body this build cannot walk — see `Notebook.ReadingStrategy`.
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Label {
                    Text("Shown as plain text")
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                Text("This notebook's body is in a format GetHog can't lay out, so this is the text PostHog stores alongside it. Any charts, queries or images it contains are missing here.")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let text = notebook.textContent {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

        case .empty:
            SectionEmptyState(
                text: "This notebook is empty. It has been created but nothing has been written in it yet.",
                systemImage: "doc",
            )
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
    func notebooksRowCard(id: String) -> some View {
        listCardBackground(route: "notebooks", id: id)
        .listRowSeparator(.hidden)
    }
}
