import GetHogKit
import SwiftUI

/// Server-side ordering. The raw values are the literals PostHog's
/// `ErrorTrackingQuery.orderBy` accepts.
enum ErrorIssueOrder: String, CaseIterable, Identifiable, Hashable {
    case users
    case occurrences
    case lastSeen = "last_seen"
    case firstSeen = "first_seen"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .users: "Users"
        case .occurrences: "Occurrences"
        case .lastSeen: "Last seen"
        case .firstSeen: "First seen"
        }
    }
}

/// Client-side status filter. Statuses come back on the same page, so filtering
/// locally avoids paying for another query just to hide rows.
enum ErrorIssueFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case active
    case resolved
    case suppressed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .resolved: "Resolved"
        case .suppressed: "Suppressed"
        }
    }

    func matches(_ issue: ErrorIssue) -> Bool {
        switch self {
        case .all: true
        case .active: issue.isActive
        case .resolved: issue.isResolved
        case .suppressed: issue.isSuppressed
        }
    }
}

extension ErrorIssue {
    var isActive: Bool { !isResolved && !isSuppressed }

    var statusTitle: String {
        status.isEmpty ? "Unknown" : status.capitalized
    }

    var statusTint: Color {
        if isResolved { return Theme.Status.good }
        if isSuppressed { return .secondary }
        return Theme.Status.critical
    }
}

@MainActor
@Observable
final class ErrorTrackingStore {
    var issues: [ErrorIssue] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(
        client: PostHogClient,
        projectID: Int,
        window: AnalyticsWindow,
        order: ErrorIssueOrder
    ) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: ErrorTrackingResponse = try await client.send(
                PostHogAPI.errorTrackingIssues(
                    projectID: projectID,
                    dateFrom: window.rawValue,
                    orderBy: order.rawValue
                )
            )
            issues = response.issues
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

struct ErrorTrackingRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var store = ErrorTrackingStore()
    // Ranked by people hurt, not by noise: an error hitting 200 users matters
    // more than one firing 50,000 times in a single retry loop.
    @State private var order: ErrorIssueOrder = .users
    @State private var filter: ErrorIssueFilter = .all
    @State private var window: AnalyticsWindow = .week
    @State private var selection: ErrorIssue?

    var body: some View {
        NavigationSplitView {
            content
                .navigationTitle("Errors")
                .toolbar {
                    ProjectSwitcher()
                    ToolbarItem(placement: .topBarTrailing) { optionsMenu }
                }
                .refreshable { await load() }
                .task(id: LoadKey(projectID: model.projectID, window: window, order: order)) {
                    await load()
                }
        } detail: {
            if let selection {
                ErrorIssueDetailView(issue: selection)
                    .id(selection.id)
            } else {
                ContentUnavailableView(
                    "Select an issue",
                    systemImage: "ladybug",
                    description: Text("Pick an error to see its impact and where it came from.")
                )
            }
        }
    }

    private struct LoadKey: Hashable {
        let projectID: Int?
        let window: AnalyticsWindow
        let order: ErrorIssueOrder
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Sort by", selection: $order) {
                ForEach(ErrorIssueOrder.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Picker("Period", selection: $window) {
                ForEach(AnalyticsWindow.allCases) { option in
                    Text(option.spokenTitle).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
        .accessibilityLabel("Sorting and time period. Sorted by \(order.title), \(window.spokenTitle).")
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.events) {
            // Error tracking is served by `/query/`, the same endpoint and scope
            // the events feed needs.
            LockedCapabilityView(capability: .events, scope: model.lockedScope(for: .events)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.issues.isEmpty {
            EmptyStateView(
                title: "Couldn't load errors",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.issues.isEmpty && !store.isLoading {
            // A quiet period is the outcome everyone wants, so it gets a tick
            // rather than the warning triangle used for genuine failures.
            EmptyStateView(
                title: "No errors in this period",
                systemImage: "checkmark.circle",
                message: "Nothing was reported in the \(window.spokenTitle.lowercased())."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if visibleIssues.isEmpty {
                ContentUnavailableView {
                    Label("No \(filter.title.lowercased()) issues", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("\(store.issues.count) issue\(store.issues.count == 1 ? "" : "s") are hidden by this filter.")
                } actions: {
                    Button("Show all") { filter = .all }
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleIssues, id: \.self) { issue in
                    NavigationLink(value: issue) {
                        ErrorIssueRow(issue: issue)
                    }
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .skeleton(store.isLoading && store.issues.isEmpty)
        // Pinned rather than scrolled away: the filter explains what the list is
        // showing, so it has to stay visible while reading it.
        .safeAreaInset(edge: .top) {
            statusFilter
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    private var statusFilter: some View {
        let picker = Picker("Status", selection: $filter) {
            ForEach(ErrorIssueFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        // Segmented labels become unreadable at accessibility text sizes.
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Data

    private var visibleIssues: [ErrorIssue] {
        store.issues.filter(filter.matches)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, window: window, order: order)
    }
}

struct ErrorIssueRow: View {
    let issue: ErrorIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Error class names are code, so they read as code.
                Text(issue.name)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Active is the default and needs no badge; anything else is a
                // deliberate human decision worth surfacing.
                if !issue.isActive {
                    StatusPill(text: issue.statusTitle, tint: issue.statusTint)
                }
            }

            if let description = issue.issueDescription, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                figure(issue.users, "users")
                figure(issue.sessions, "sessions")
                figure(issue.occurrences, "occurrences")

                Spacer(minLength: 4)

                if let lastSeen = issue.lastSeen {
                    Text(lastSeen, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private func figure(_ value: Double, _ noun: String) -> some View {
        Text("\(value.compactFormatted) \(noun)")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var spokenSummary: String {
        var parts = [issue.name]
        if let description = issue.issueDescription, !description.isEmpty {
            parts.append(description)
        }
        parts.append(
            """
            \(issue.users.formatted(.number.precision(.fractionLength(0)))) users, \
            \(issue.sessions.formatted(.number.precision(.fractionLength(0)))) sessions, \
            \(issue.occurrences.formatted(.number.precision(.fractionLength(0)))) occurrences
            """
        )
        if let lastSeen = issue.lastSeen {
            parts.append("last seen \(lastSeen.formatted(.relative(presentation: .named)))")
        }
        if !issue.isActive {
            parts.append(issue.statusTitle)
        }
        return parts.joined(separator: ". ")
    }
}
