import GetHogKit
import SwiftUI

@MainActor
@Observable
final class AnnotationsStore {
    var days: [AnnotationDay] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    var isEmpty: Bool { days.isEmpty }

    var totalCount: Int { days.reduce(0) { $0 + $1.annotations.count } }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<Annotation> = try await client.send(
                PostHogAPI.annotations(projectID: projectID, limit: 100)
            )
            days = Annotation.groupedByDay(page.results.filter { !$0.isDeleted })
            error = nil
            loadedAt = Date()
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

/// Dated notes drawn on charts — releases, incidents, campaign starts.
///
/// Grouped by the day they mark rather than listed flat, because an annotation
/// only means anything next to the other things that happened that day.
struct AnnotationsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var store = AnnotationsStore()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Annotations")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search annotations")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
        }
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
                message: "An annotation pins a note to a date — a release, an incident, the day a campaign started — so a spike on a chart has an explanation beside it. Nobody has written one for this project, and a project can run a long time without needing to.",
                // Annotations are read here and written in the console; the app
                // has no way to create one.
                actionTitle: consoleURL == nil ? nil : "Add one in PostHog",
                action: openConsole
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
                    .foregroundStyle(.secondary)
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

    private var consoleURL: URL? { model.webURL(path: "data-management/annotations") }

    private var openConsole: (() -> Void)? {
        guard let consoleURL else { return nil }
        return { openURL(consoleURL) }
    }

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
        if annotation.isHidden { return .pill("Hidden", .secondary) }
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
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}
