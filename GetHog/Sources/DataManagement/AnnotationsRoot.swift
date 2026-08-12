import GetHogKit
import GetHogUI
import SwiftUI

@MainActor
@Observable
final class AnnotationsStore {
    /// The flat list is the state; the day grouping is a view of it.
    ///
    /// This used to store `days` directly, which was right while the screen could
    /// only read. It cannot be now: inserting one annotation into a pre-grouped
    /// list means finding or creating its day bucket and re-sorting within it,
    /// and withdrawing one means unwinding that and deleting the bucket if it
    /// emptied. Both are `groupedByDay` written a second time, by hand, in the
    /// one place where getting it wrong shows a note under the wrong date.
    private(set) var annotations: [Annotation] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var days: [AnnotationDay] { Annotation.groupedByDay(annotations) }

    var isEmpty: Bool { annotations.isEmpty }

    var totalCount: Int { annotations.count }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<Annotation> = try await client.send(
                PostHogAPI.annotations(projectID: projectID, limit: 100)
            )
            annotations = page.results.filter { !$0.isDeleted }
            error = nil
            loadedAt = Date()
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Optimistic edits
    //
    // Called only by `AnnotationComposer`, which owns the write and the rollback.
    // A refresh replaces the whole list, so nothing here has to be reconciled the
    // way `FlagToggleController.reconcile(with:)` does: an override that outlives
    // its write is a problem for a *field* on a row the server also sends, and a
    // created annotation is either in the next fetch or it never existed.

    func insert(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    func remove(id: Int) {
        annotations.removeAll { $0.id == id }
    }

    /// Swaps a placeholder for the row PostHog actually created.
    ///
    /// Appends rather than dropping the response if the placeholder has gone —
    /// a refresh landing mid-write would have replaced the list, and the created
    /// annotation is real either way.
    func replace(id: Int, with annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            if !annotations.contains(where: { $0.id == annotation.id }) {
                annotations.append(annotation)
            }
            return
        }
        annotations[index] = annotation
    }
}

/// Dated notes drawn on charts — releases, incidents, campaign starts.
///
/// Grouped by the day they mark rather than listed flat, because an annotation
/// only means anything next to the other things that happened that day.
struct AnnotationsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = AnnotationsStore()
    @State private var composer = AnnotationComposer()
    @State private var isComposing = false
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle("Annotations")
            .toolbar {
                ProjectSwitcher()
                composeButton
            }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search annotations")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
            .sheet(isPresented: $isComposing) { composerSheet }
            // A written annotation and a refused one must feel different without
            // looking away from the list, which is where the row appears.
            .sensoryFeedback(.success, trigger: composer.successCount)
            .sensoryFeedback(.error, trigger: composer.failureCount)
            .alert(
                "Couldn't save",
                isPresented: Binding(
                    get: { composer.message != nil },
                    set: { if !$0 { composer.dismissMessage() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(composer.message?.text ?? "")
            }
    }

    /// Only where the screen is usable at all.
    ///
    /// Gated on the same capability as the list, because a "+" over a locked
    /// screen offers to write into a project the key cannot even read. The
    /// *write* scope is a different question and deliberately not probed: a read
    /// preflight cannot detect `annotation:write`, so guessing it would either
    /// hide the button from someone who has it or claim it for someone who does
    /// not. The button is offered, and `AnnotationComposer` names the scope if
    /// PostHog refuses.
    @ToolbarContentBuilder
    private var composeButton: some ToolbarContent {
        if model.isAvailable(.dashboards), model.client != nil, model.projectID != nil {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isComposing = true
                } label: {
                    Label("New annotation", systemImage: "plus")
                }
                .accessibilityHint("Writes a dated note onto this project's charts")
            }
        }
    }

    private var composerSheet: some View {
        AnnotationComposerView(
            projectName: model.selectedProject?.name ?? "this project",
            save: { content, dateMarker, target in
                guard let client = model.client, let projectID = model.projectID else { return false }
                return await composer.create(
                    content: content,
                    dateMarker: dateMarker,
                    target: target,
                    store: store,
                    client: client,
                    projectID: projectID
                )
            },
            isSaving: composer.isSaving
        )
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            // Annotations exist to be drawn on insights, and the app has no
            // annotation-specific probe, so the insight gate is the closest
            // honest one. A key with one scope and not the other still gets the
            // exact 403 text in the error state below.
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.isEmpty {
            EmptyStateView(
                title: "Couldn't load annotations",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No annotations",
                systemImage: "text.bubble",
                illustration: .workspace,
                message: "An annotation pins a note to a date — a release, an incident, the day a campaign started — so a spike on a chart has an explanation beside it. Nobody has written one for this project, and a project can run a long time without needing to.",
                // This used to send people to the web console, because the app
                // could only read. The empty state of the one screen whose
                // feature is being fast is a poor place to recommend a laptop.
                actionTitle: "Write one",
                action: { isComposing = true }
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if filtered.isEmpty {
                Text("No annotations matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(Theme.Ink.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(filtered) { day in
                Section {
                    ForEach(day.annotations) { annotation in
                        AnnotationRowView(annotation: annotation)
                            .annotationsRowCard()
                    }
                } header: {
                    SectionLabel(text: header(for: day), systemImage: "calendar")
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    private func header(for day: AnnotationDay) -> String {
        // An annotation whose date the API never sent is still real; it just
        // cannot be placed on a timeline, and the header has to say that rather
        // than filing it under today.
        guard let date = day.day else { return "Undated" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    /// Filters inside each day and drops days left empty, so a search never
    /// leaves a bare date heading behind.
    private var filtered: [AnnotationDay] {
        guard !search.isEmpty else { return store.days }
        return store.days.compactMap { day in
            let matches = day.annotations.filter {
                $0.displayContent.localizedCaseInsensitiveContains(search)
                    || ($0.createdByName ?? "").localizedCaseInsensitiveContains(search)
                    || ($0.insightName ?? "").localizedCaseInsensitiveContains(search)
            }
            return matches.isEmpty ? nil : AnnotationDay(day: day.day, annotations: matches)
        }
    }

    // The console link that used to live here is gone with the empty state's old
    // action. It was only ever reachable *while the list was empty* — that is,
    // while there was nothing on this screen to go and edit — and the one thing
    // the console is still needed for, deleting an annotation, is named in the
    // composer's confirmation instead, at the moment it becomes relevant.

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Row

struct AnnotationRowView: View {
    let annotation: Annotation

    var body: some View {
        DataRow(
            // The glyph carries the origin — a person, a branch — which is the
            // first thing a reader wants to tell apart in a mixed list.
            glyph: annotation.creationType.systemImage,
            // Warm secondary for machine-stamped rows so a wall of deploy
            // markers doesn't read as a wall of hand-written notes. Never a
            // series colour: the palette belongs to chart data.
            tint: annotation.creationType == .gitIntegration ? Theme.accentWarm : Theme.accent,
            title: titleText,
            subtitle: originAndScope,
            footnote: byline,
            accessory: accessory
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Hidden is the only state an annotation has, and the row does not push
    /// anything, so every other row ends without an accessory rather than with a
    /// chevron that leads nowhere.
    private var accessory: RowAccessory {
        if annotation.isHidden { return .pill("Hidden", Theme.neutralMark) }
        return .none
    }

    /// The author's emoji rides in the title rather than as a view of its own:
    /// `DataRow` leads with a symbol glyph, and the explicit label below keeps
    /// the emoji out of VoiceOver, which is where it was always decorative — it
    /// is the author's badge choice and says nothing the text doesn't.
    private var titleText: String {
        guard let emoji = annotation.emoji else { return annotation.displayContent }
        return "\(emoji) \(annotation.displayContent)"
    }

    /// Origin and scope are both stated in words. "GIT" on its own is
    /// meaningless, and `dashboard_item` actively misleads — it means insight,
    /// not "an item on a dashboard". The attachment supersedes the bare scope
    /// where there is one, since "On insight Signups" says both at once.
    private var originAndScope: String {
        [annotation.creationType.shortTitle, annotation.attachment ?? annotation.scope.title]
            .joined(separator: " · ")
    }

    private var byline: String {
        var parts: [String] = []
        if let marker = annotation.dateMarker {
            parts.append("Marks \(marker.formatted(.dateTime.hour().minute()))")
        }
        if let author = annotation.createdByName {
            parts.append(annotation.creationType == .gitIntegration ? "via \(author)" : "by \(author)")
        }
        // No date marker and no author is a real state for an imported row; say
        // nothing rather than pad the line with a placeholder.
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = [annotation.displayContent, annotation.creationType.title]
        parts.append("scope \(annotation.scope.title.lowercased())")
        if let attachment = annotation.attachment { parts.append(attachment) }
        if let marker = annotation.dateMarker {
            parts.append("marks \(marker.formatted(.dateTime.day().month().year().hour().minute()))")
        }
        if let author = annotation.createdByName { parts.append("by \(author)") }
        if annotation.isHidden { parts.append("hidden in the PostHog interface") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Row chrome
//
// File-private so concurrent work on other screens can't collide with the name.

private extension View {
    /// The list treatment from the dashboards screen: every row is its own card
    /// on the page ground, with the system separator suppressed because the gap
    /// between cards already does that work.
    func annotationsRowCard() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
        )
        .listRowSeparator(.hidden)
    }
}
