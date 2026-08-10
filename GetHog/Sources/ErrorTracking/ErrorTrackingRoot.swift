import GetHogKit
import GetHogUI
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

    /// The status as a word.
    ///
    /// Goes through `readStatus` rather than capitalising the raw value, because
    /// PostHog reports five statuses and two of them are snake_case:
    /// `"pending_release".capitalized` is `"Pending_release"`, which is a
    /// database column shown to a user. An unrecognised status still falls back
    /// to the capitalised form rather than to nothing.
    var statusTitle: String {
        if let title = readStatus?.title { return title }
        return status.isEmpty ? "Unknown" : status.capitalized
    }

    var statusTint: Color {
        if isResolved { return Theme.Status.good }
        if isSuppressed { return .secondary }
        // Archived and pending-release are neither active nor done. Grey rather
        // than red: they are not asking for attention, and colouring them
        // critical would put two issues nobody can act on at the top of a
        // glance-scan.
        if let readStatus, readStatus == .archived || readStatus == .pendingRelease {
            return .secondary
        }
        return Theme.Status.critical
    }

    /// The short label SwiftUI uses to identify this rotor entry.
    ///
    /// Once the rotor moves VoiceOver focus to the row, the row's own
    /// `spokenSummary` is announced. Keeping this label short still matters for
    /// the rotor's entry metadata and matching, but it is not a replacement for
    /// the focused row's full accessibility label.
    var rotorLabel: String {
        var parts = [name]
        if let issueDescription, !issueDescription.isEmpty {
            parts.append(issueDescription.rotorSnippet)
        }
        parts.append(users.counted("user"))
        return parts.joined(separator: ", ")
    }
}

@MainActor
@Observable
final class ErrorTrackingStore {
    /// The `limit` sent with the query, kept here so the request and the
    /// comparison the coverage note is built from cannot disagree.
    static let limit = 50

    var issues: [ErrorIssue] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// What this page of issues is, and is not, a total over.
    ///
    /// `ErrorsOverview` sums occurrences across `issues` and prints the result
    /// beside an issue count and a status split — four figures derived from one
    /// ranked, capped page and labelled as if they described the window. Nothing
    /// said so. `ErrorTrackingResponse` preserves the envelope's `hasMore` and
    /// `limit` fields. See
    /// `ErrorIssueCoverage`, which also records why there is no denominator to
    /// be had from this query and what is done instead.
    var coverage: ErrorIssueCoverage?

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
                    orderBy: order.rawValue,
                    limit: Self.limit
                )
            )
            issues = response.issues
            coverage = response.coverage(requestedLimit: Self.limit)
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
    @Environment(\.screenNavigationPlacement) private var navigationPlacement

    @Environment(OpenDetails.self) private var openDetails

    @State private var store = ErrorTrackingStore()
    /// Owned here, at the level both the list and the detail pane can see.
    ///
    /// It has to outlive the detail screen: on iPad the detail pane is rebuilt
    /// whenever the selection changes, and an override held inside it would be
    /// thrown away mid-write. Holding it here also means the list row reflects a
    /// change the moment it lands, rather than at the next refresh.
    @State private var triage = ErrorTriageController()
    // Ranked by people affected, not by repeated noise from one retry loop.
    @State private var order: ErrorIssueOrder = .users
    @State private var filter: ErrorIssueFilter = .all
    @State private var window: AnalyticsWindow = .week
    @Namespace private var issueRotor

    /// The open issue, and deliberately **not** `@State`.
    ///
    /// This screen is reached through the search tab, which means
    /// it is hosted by a sidebar `Tab` above the size-class boundary and by the
    /// search stack below it — see `OpenDetails`. Crossing the boundary rebuilds
    /// the screen in the other host. Local `@State` would be thrown away during
    /// that transition and would not restore the selected issue.
    private var selection: Binding<ErrorIssue?> {
        Binding(
            get: { openDetails[.errorTracking] as? ErrorIssue },
            set: { openDetails[.errorTracking] = $0.map(AnyHashable.init) }
        )
    }

    private var usesHostNavigation: Bool {
        sizeClass == .compact || navigationPlacement == .visionSectionDetail
    }

    // In compact width the enclosing navigation stack owns navigation. A nested
    // split view would add a redundant navigation bar without a second column.
    var body: some View {
        if usesHostNavigation {
            issueList
                // Bound to `selection`, not registered `for: ErrorIssue.self`.
                // A `for:` destination is driven by values the `NavigationLink`
                // appends to the *container's* path, which this screen can
                // neither read nor write — so the issue open at 834pt could not
                // be put back on the stack at 375pt, and the issue open at
                // 375pt was invisible to the detail column at 834pt. Bound to
                // the selection, one piece of state serves both: it pushes here
                // and fills the detail column there.
                .navigationDestination(item: selection) { issue in
                    ErrorIssueDetailView(issue: issue, triage: triage)
                        .id(issue.id)
                }
        } else {
            NavigationSplitView {
                issueList
                    // This list needs sufficient width for status, message, and
                    // impact information to remain readable.
                    .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 460)
                    // The tab sidebar already puts a toggle in this bar; the
                    // split view added a second one beside it, two identical
                    // buttons doing almost the same thing above the list.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                detailPane
            }
        }
    }

    /// The detail column: the chosen issue, or a summary of the product when
    /// nothing is chosen yet.
    ///
    /// The no-selection branch mirrors the list's own states rather than summarising thin air: a locked
    /// key and a genuinely quiet week are both normal outcomes on this screen,
    /// and a grid of zeroes would misreport either one.
    @ViewBuilder
    private var detailPane: some View {
        if let issue = selection.wrappedValue {
            ErrorIssueDetailView(issue: issue, triage: triage)
                .id(issue.id)
        } else if !model.isAvailable(.events) {
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
        } else if store.issues.isEmpty {
            if store.isLoading {
                ProgressView().controlSize(.large)
            } else {
                EmptyStateView(
                    title: "No errors in this period",
                    systemImage: "checkmark.circle",
                    illustration: .allClear,
                    message: "Nothing was reported in the \(window.spokenTitle.lowercased())."
                )
            }
        } else {
            ErrorsOverview(
                issues: store.issues,
                coverage: store.coverage,
                window: window,
                loadedAt: store.loadedAt,
                selection: selection
            )
        }
    }

    private var issueList: some View {
        content
            .navigationTitle("Errors")
            .toolbar {
                ProjectSwitcher()
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
            .projectSubtitle()
            .screenRefreshable { await load() }
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
                illustration: .allClear,
                message: "Nothing was reported in the \(window.spokenTitle.lowercased())."
            )
        } else {
            list
        }
    }

    /// The issue list, selection-driven at *both* widths.
    ///
    /// The selection binding is the delicate part. Handing one to the `List`
    /// makes it claim the row tap: the `NavigationLink` sets `selection` rather
    /// than pushing, so something else has to turn that selection into a visible
    /// screen or the tap merely highlights the row. An earlier refactor left
    /// compact width in exactly that state — binding kept, the
    /// `NavigationSplitView` that had been displaying it gone — and tapping an
    /// issue did nothing at all. Compact width has a display again:
    /// `navigationDestination(item:)` in `body`. Tapping an issue pushes its
    /// titled detail over a back button and clears selection on return.
    private var list: some View {
        ScrollViewReader { scroller in
            List(selection: selection) {
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
                                // The row is drawn from the issue *plus* anything we
                                // have written since, so resolving something on the
                                // detail screen is visible on the way back rather
                                // than at the next refresh. Deliberately no swipe
                                // action: suppression is the one triage action that
                                // changes what PostHog stores, and a data-loss
                                // gesture two pixels from a scroll is not a
                                // shortcut worth having.
                                ErrorIssueRow(issue: triage.effective(issue))
                            }
                            .accessibilityRotorEntry(id: issue.id, in: issueRotor)
                            .id(issue.id)
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
            // A rotor rather than a second filter, and the difference is the whole
            // reason it is here. The status picker above *removes* rows; this moves
            // between them. With the picker on "All" — its default, and the state a
            // triage pass starts in — the unresolved issues are interleaved with
            // everything already dealt with, and finding them again is a scroll.
            //
            // Rotor and scroll identity use the API's stable issue id rather
            // than the whole value. Triage can replace status/assignment fields
            // while this view is alive; those changes must not invalidate the
            // namespace target VoiceOver is moving toward.
            //
            // Filtered from `visibleIssues` and read through `triage.effective`, so
            // an issue resolved a moment ago on the detail screen leaves this rotor
            // at the same instant it leaves the "Active" filter.
            .unresolvedIssuesRotor(
                unresolvedIssues,
                namespace: issueRotor,
                scroller: scroller
            )
        }
    }

    /// The rows in the list that are still asking for attention.
    ///
    /// Derived from `visibleIssues` rather than from `store.issues`: a rotor
    /// entry for a row the status filter has hidden would be a jump to nothing.
    private var unresolvedIssues: [ErrorIssue] {
        visibleIssues.filter { triage.effective($0).isActive }
    }

    private var statusFilter: some View {
        let picker = Picker("Status", selection: $filter) {
            ForEach(ErrorIssueFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        // Two different ways this control runs out of room, and it needs to
        // survive both.
        //
        // Text size is the one already handled: segmented labels stop being
        // readable at accessibility sizes.
        //
        // `ViewThatFits` uses the segmented form only when it fits the available
        // width, otherwise falling back to a menu without guessed thresholds.
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                picker.pickerStyle(.menu)
            } else {
                ViewThatFits(in: .horizontal) {
                    picker.pickerStyle(.segmented)
                    picker.pickerStyle(.menu)
                }
            }
        }
        // Claim the bar width so the menu form aligns with adjacent controls.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    /// Filtered on the *effective* status, so an issue just resolved leaves the
    /// "Active" filter immediately instead of sitting in it mislabelled.
    private var visibleIssues: [ErrorIssue] {
        store.issues.filter { filter.matches(triage.effective($0)) }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, window: window, order: order)
        // The fresh page is the server's word. Whoever changed an issue in the
        // web console wins over a local override that has already been written.
        triage.reconcile(with: store.issues)
    }
}

extension View {
    /// Adds the issue rotor only when it has somewhere to go. An empty custom
    /// rotor remains selectable in VoiceOver but cannot move focus, which is
    /// worse than omitting it until an unresolved issue exists.
    @ViewBuilder
    func unresolvedIssuesRotor(
        _ issues: [ErrorIssue],
        namespace: Namespace.ID,
        scroller: ScrollViewProxy
    ) -> some View {
        if issues.isEmpty {
            self
        } else {
            accessibilityRotor(Text("Unresolved issues")) {
                ForEach(issues, id: \.id) { issue in
                    AccessibilityRotorEntry(
                        Text(issue.rotorLabel),
                        id: issue.id,
                        in: namespace,
                        prepare: { scroller.scrollTo(issue.id) }
                    )
                }
            }
        }
    }
}

struct ErrorIssueRow: View {
    let issue: ErrorIssue

    /// Exception classes that identify nothing on their own. A JavaScript
    /// project's list is mostly `Error` — four identical titles stacked, with
    /// the only distinguishing text demoted to the subtitle. When the class is
    /// one of these and a message exists, the message takes the headline and
    /// the class becomes the supporting line; both survive, swapped.
    private static let genericNames: Set<String> = [
        "Error", "Exception", "UnhandledRejection", "Unhandled Rejection",
    ]

    private var isGenericName: Bool {
        Self.genericNames.contains(issue.name)
            && !(issue.issueDescription ?? "").isEmpty
    }

    var body: some View {
        DataRow(
            glyph: "ladybug.fill",
            tint: issue.statusTint,
            title: isGenericName ? (issue.issueDescription ?? issue.name) : issue.name,
            // The class name and the message both come out of a stack trace, so
            // whichever takes the supporting line keeps code type.
            subtitle: isGenericName ? issue.name : issue.issueDescription,
            footnote: impactLine,
            isSubtitleMonospaced: true,
            // Generic issue names need their message visible to distinguish rows.
            subtitleLineLimit: 2,
            // Two lines: the counts are what this list is *ranked by*, and at
            // compact width one line beside the status pill cut them at
            // "18 occu…" — the metric and the last-seen time both lost.
            footnoteLineLimit: 2,
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
            issue.users.counted("user"),
            issue.sessions.counted("session"),
            issue.occurrences.counted("occurrence"),
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
        // `issueDescription` is server prose and arrives with its own full stop.
        return parts.joinedAsSentences()
    }
}
