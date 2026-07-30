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
            ContentUnavailableView {
                Label("Couldn't load annotations", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.isEmpty && !store.isLoading {
            ContentUnavailableView {
                Label("No annotations", systemImage: "text.bubble")
            } description: {
                Text("Nobody has annotated this project yet. Annotations mark a release or an incident on a date so charts can be read against it.")
            } actions: {
                if let url = model.webURL(path: "data-management/annotations") {
                    Link("Add one in PostHog", destination: url)
                }
            }
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
            }

            ForEach(filtered) { day in
                Section {
                    ForEach(day.annotations) { annotation in
                        AnnotationRowView(annotation: annotation)
                    }
                } header: {
                    Text(header(for: day))
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
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

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Row

struct AnnotationRowView: View {
    let annotation: Annotation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if let emoji = annotation.emoji {
                    // Decorative: the emoji is the author's badge choice and
                    // carries no information the text doesn't already have.
                    Text(emoji)
                        .font(.title3)
                        .accessibilityHidden(true)
                }

                Text(annotation.displayContent)
                    .font(.body)
                    .foregroundStyle(annotation.content == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                // Origin and scope are both stated in words. "GIT" on its own is
                // meaningless, and `dashboard_item` actively misleads — it means
                // insight, not "an item on a dashboard".
                StatusPill(
                    text: annotation.creationType.shortTitle,
                    tint: annotation.creationType == .gitIntegration ? SeriesPalette.color(at: 6) : Theme.accent
                )
                StatusPill(text: annotation.scope.title, tint: .secondary)

                if annotation.isHidden {
                    StatusPill(text: "Hidden", tint: .secondary)
                }
            }

            if let attachment = annotation.attachment {
                Text(attachment)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(byline)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
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
