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
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var store = ErrorTrackingStore()
    // Ranked by people hurt, not by noise: an error hitting 200 users matters
    // more than one firing 50,000 times in a single retry loop.
    @State private var order: ErrorIssueOrder = .users
    @State private var filter: ErrorIssueFilter = .all
    @State private var window: AnalyticsWindow = .week
    @State private var selection: ErrorIssue?

    // In compact width the index behind "More" owns the navigation stack (see
    // `RootView`). A `NavigationSplitView` here collapses into a stack of its
    // own inside that one and draws a second navigation bar above it — measured
    // on this screen: a bar carrying only a back chevron, then a second bar with
    // the project switcher and the sort menu, before any error was visible.
    // There is no second column at phone width anyway, so there is nothing to
    // collapse.
    var body: some View {
        if sizeClass == .compact {
            issueList
                .navigationDestination(for: ErrorIssue.self) { issue in
                    ErrorIssueDetailView(issue: issue)
                        .id(issue.id)
                }
        } else {
            NavigationSplitView {
                issueList
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
    }

    private var issueList: some View {
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
                EmptyStateView(
                    title: "No \(filter.title.lowercased()) issues",
                    systemImage: "line.3.horizontal.decrease.circle",
                    message: "\(store.issues.count) issue\(store.issues.count == 1 ? "" : "s") are hidden by this filter.",
                    actionTitle: "Show all",
                    action: { filter = .all }
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(visibleIssues, id: \.self) { issue in
                        NavigationLink(value: issue) {
                            ErrorIssueRow(issue: issue)
                        }
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    SectionLabel(
                        text: "\(visibleIssues.count) issue\(visibleIssues.count == 1 ? "" : "s")",
                        systemImage: "ladybug.fill"
                    )
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.issues.isEmpty)
        // Pinned rather than scrolled away: the filter explains what the list is
        // showing, so it has to stay visible while reading it.
        .safeAreaInset(edge: .top) {
            GlassFilterBar { statusFilter }
                .padding(.bottom, Theme.Space.s)
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
        DataRow(
            glyph: "ladybug.fill",
            tint: issue.statusTint,
            title: issue.name,
            // The class name and the message both come out of a stack trace, so
            // the message keeps code type where the headline title cannot.
            subtitle: issue.issueDescription,
            footnote: impactLine,
            isSubtitleMonospaced: true,
            // Unconditional now that the glyph is tinted by status: resolved and
            // suppressed must never be carried by colour alone.
            accessory: .pill(issue.statusTitle, issue.statusTint)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// Impact and recency share one line: the counts are what the list is
    /// ordered by, and "when did it last happen" is the next question asked.
    private var impactLine: String {
        var parts = [
            "\(issue.users.compactFormatted) users",
            "\(issue.sessions.compactFormatted) sessions",
            "\(issue.occurrences.compactFormatted) occurrences",
        ]
        if let lastSeen = issue.lastSeen {
            parts.append(lastSeen.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        return parts.joined(separator: " · ")
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
        parts.append(issue.statusTitle)
        return parts.joined(separator: ". ")
    }
}
