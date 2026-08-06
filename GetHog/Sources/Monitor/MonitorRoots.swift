import GetHogKit
import SwiftUI

// MARK: - Inbox

/// Agent-filed work, newest first.
///
/// Framed as a triage queue rather than a to-do list because these tasks can be
/// filed by automated agents and signal reports as well as by people. Read-only,
/// like the rest of the app.
struct InboxRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = InboxStore()
    @State private var search = ""

    var body: some View {
        content
            .navigationTitle("Inbox")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search tasks")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.tasks.isEmpty {
            EmptyStateView(
                title: "Couldn't load the inbox",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if filtered.isEmpty && !store.isLoading {
            EmptyStateView(
                title: search.isEmpty ? "Nothing to triage" : "No matching tasks",
                systemImage: "tray",
                message: search.isEmpty
                    ? "Tasks appear here when a scout or a signal report files one."
                    : "No task matches “\(search)”."
            )
        } else {
            List {
                ForEach(filtered) { task in
                    row(task)
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                }
                if let loadedAt = store.loadedAt {
                    FreshnessLabel(date: loadedAt)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listRowSpacing(Theme.Space.xs)
            .pageSurface()
            .skeleton(store.isLoading && store.tasks.isEmpty)
        }
    }

    private func row(_ task: AgentTask) -> some View {
        DataRow(
            // Origin, not status: what filed this decides whether it is worth
            // reading, and it is the only axis that actually varies here.
            glyph: task.signalReportID != nil ? "antenna.radiowaves.left.and.right" : "binoculars",
            tint: task.signalReportID != nil ? Theme.accentWarm : Theme.accent,
            title: task.displayTitle,
            // Repository when there is one; otherwise the scout's own
            // identifier, which is the only thing distinguishing one scout run
            // from the next and is what the title was derived from.
            subtitle: task.repository ?? task.scoutName,
            footnote: footnote(task),
            isSubtitleMonospaced: true,
            accessory: runAccessory(task)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(task))
    }

    private func footnote(_ task: AgentTask) -> String? {
        var parts: [String] = []
        if let number = task.taskNumber { parts.append("#\(number)") }
        if let branch = task.latestRun?.branch { parts.append(branch) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Run state, when there is one. `latest_run` rides along in the list
    /// response, so this costs no extra request per row.
    private func runAccessory(_ task: AgentTask) -> RowAccessory {
        guard let status = task.latestRun?.status, !status.isEmpty else { return .chevron }
        let tint: Color = switch status.lowercased() {
        case "completed", "succeeded", "success": Theme.Status.good
        case "failed", "errored": Theme.Status.critical
        default: Theme.accentWarm
        }
        return .pill(status.replacingOccurrences(of: "_", with: " ").capitalized, tint)
    }

    private func spoken(_ task: AgentTask) -> String {
        var text = task.displayTitle
        text += task.signalReportID != nil ? ", filed by a signal report" : ", filed by a scout"
        if let status = task.latestRun?.status { text += ", last run \(status)" }
        return text
    }

    private var filtered: [AgentTask] {
        guard !search.isEmpty else { return store.tasks }
        return store.tasks.filter {
            // Searches what is on screen, not the raw prompt. Matching the
            // stored title would hit "You are a Signals scout agent" on every
            // scout row and return the whole list for half the words typed.
            $0.displayTitle.localizedCaseInsensitiveContains(search)
                || ($0.repository ?? "").localizedCaseInsensitiveContains(search)
                || ($0.scoutName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Signals

/// Findings from scheduled scouts, grouped by what they need.
struct SignalsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = SignalsStore()

    var body: some View {
        content
            .navigationTitle("Signals")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.reports.isEmpty {
            EmptyStateView(
                title: "Couldn't load signals",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.reports.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No reports yet",
                systemImage: "antenna.radiowaves.left.and.right",
                message: "Scouts write a report here when a scheduled run finds something."
            )
        } else {
            List {
                ForEach(store.grouped, id: \.status) { group in
                    Section {
                        ForEach(group.reports) { report in
                            row(report)
                                .listRowBackground(
                                    Theme.cardBackground
                                        .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                        .padding(.vertical, 1)
                                )
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionLabel(text: group.status.title, systemImage: symbol(group.status))
                    }
                }
            }
            .listRowSpacing(Theme.Space.xs)
            .pageSurface()
            .skeleton(store.isLoading && store.reports.isEmpty)
        }
    }

    private func row(_ report: SignalReport) -> some View {
        DataRow(
            glyph: report.implementationPRURL != nil ? "arrow.triangle.pull" : "waveform.path.ecg",
            tint: tint(report),
            title: report.title,
            // Every source, not the first: nearly half of reports come from
            // two products at once, and naming one would misattribute them.
            subtitle: report.sourceProducts
                .map { $0.replacingOccurrences(of: "_", with: " ") }
                .joined(separator: " · "),
            footnote: report.signalCount > 0
                ? "\(report.signalCount) signal\(report.signalCount == 1 ? "" : "s")"
                : nil,
            accessory: priorityAccessory(report)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(report.title), \(report.priority ?? "unprioritised"), \(report.status.title)"
        )
    }

    /// Priority is absent more often than it is present — 16 of 33 on the live
    /// API. Rendering nothing for those would read as a broken column, and
    /// sorting them last would invent a ranking PostHog never gave.
    private func priorityAccessory(_ report: SignalReport) -> RowAccessory {
        guard let priority = report.priority, !priority.isEmpty else {
            return .pill("Untriaged", .secondary)
        }
        let tint: Color = switch priority.uppercased() {
        case "P0", "P1": Theme.Status.critical
        case "P2": Theme.accentWarm
        default: Theme.accent
        }
        return .pill(priority, tint)
    }

    private func tint(_ report: SignalReport) -> Color {
        switch report.status {
        case .failed: Theme.Status.critical
        case .resolved: .secondary
        case .ready: Theme.accentWarm
        default: Theme.accent
        }
    }

    private func symbol(_ status: SignalReportStatus) -> String {
        switch status {
        case .ready: "checkmark.seal"
        case .potential: "questionmark.circle"
        case .inProgress: "clock.arrow.circlepath"
        case .resolved: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .unknown: "circle"
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Health

/// Instrumentation health — the "is my data actually arriving" screen.
struct HealthRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = HealthStore()

    var body: some View {
        content
            .navigationTitle("Health")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.issues.isEmpty {
            EmptyStateView(
                title: "Couldn't load health issues",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.issues.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "Nothing wrong",
                systemImage: "checkmark.seal",
                illustration: .allClear,
                message: "PostHog hasn't flagged any problems with this project's instrumentation."
            )
        } else {
            List {
                if !store.active.isEmpty {
                    Section {
                        ForEach(store.active) { issue in card(issue) }
                    } header: {
                        SectionLabel(text: "Active", systemImage: "exclamationmark.triangle.fill")
                    }
                }
                // Kept rather than filtered out: "this fixed itself" is
                // information, and its absence would make a screen that
                // silently emptied look broken.
                if !store.resolved.isEmpty {
                    Section {
                        ForEach(store.resolved) { issue in card(issue) }
                    } header: {
                        SectionLabel(text: "Resolved", systemImage: "checkmark.circle")
                    }
                }
                if let loadedAt = store.loadedAt {
                    FreshnessLabel(date: loadedAt)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listRowSpacing(Theme.Space.xs)
            .pageSurface()
            .skeleton(store.isLoading && store.issues.isEmpty)
        }
    }

    private func card(_ issue: HealthIssue) -> some View {
        DataRow(
            glyph: Self.glyph(issue.kind),
            tint: issue.status == .active ? tint(issue.severity) : .secondary,
            title: title(issue.kind),
            subtitle: subtitle(issue),
            footnote: issue.resolvedAt.map {
                "Resolved \($0.formatted(.relative(presentation: .named)))"
            },
            accessory: issue.status == .active
                ? .pill(severityWord(issue.severity), tint(issue.severity))
                : .none
        )
        .listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title(issue.kind)), \(severityWord(issue.severity)), "
                + "\(issue.status == .active ? "active" : "resolved")."
                + (subtitle(issue).map { " \($0)" } ?? "")
        )
    }

    /// The issue's own words, or nothing if it has none of its own.
    ///
    /// `HealthIssueDetail.summary` falls back to the capitalised raw kind when
    /// PostHog sends a payload with no text in it — which is what this project
    /// returns — so the row rendered "Ingestion warning" above "Ingestion
    /// Warning": the same label twice, in two capitalisations, reading as a
    /// rendering bug rather than as the absence it is. Dropping the echo claims
    /// no more than the response supports and costs nothing, because the title
    /// already names the issue, the pill carries the severity and the footnote
    /// carries when it resolved.
    private func subtitle(_ issue: HealthIssue) -> String? {
        let summary = issue.detail.summary
        let restatesTitle = summary.caseInsensitiveCompare(title(issue.kind)) == .orderedSame
        let restatesKind = summary.caseInsensitiveCompare(
            issue.kind.rawValue.replacingOccurrences(of: "_", with: " ")
        ) == .orderedSame
        guard !restatesTitle, !restatesKind else { return nil }
        return summary
    }

    /// Static and non-private so `SymbolNameTests` can resolve every arm of it.
    /// One of the two dead symbol names in this app was in a switch exactly like
    /// this one, and a `String` naming a glyph has no compile-time check behind
    /// it — the only thing that catches a typo is asking the system for it.
    static func glyph(_ kind: HealthIssueKind) -> String {
        switch kind {
        case .sdkOutdated: "shippingbox"
        // `arrow.down.circle.badge.exclamationmark` does not exist, so this row
        // rendered an empty grey tile beside four rows that all had a glyph.
        // Matches the Ingestion tab in `RootView`, which named the same dead
        // symbol.
        case .ingestionWarning: "bolt.trianglebadge.exclamationmark"
        case .webVitals: "gauge.with.dots.needle.33percent"
        case .authorizedURLs: "link.badge.plus"
        case .unknown: "questionmark.circle"
        }
    }

    private func title(_ kind: HealthIssueKind) -> String {
        switch kind {
        case .sdkOutdated: "SDK out of date"
        case .ingestionWarning: "Ingestion warning"
        case .webVitals: "Web Vitals regression"
        case .authorizedURLs: "Authorized URLs"
        // Named from the raw kind rather than called "Unknown issue", so a
        // problem PostHog invents next month still reads as something.
        case .unknown: "Health issue"
        }
    }

    private func severityWord(_ severity: HealthIssueSeverity) -> String {
        switch severity {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        case .unknown: "Unrated"
        }
    }

    private func tint(_ severity: HealthIssueSeverity) -> Color {
        switch severity {
        case .critical: Theme.Status.critical
        case .warning: Theme.accentWarm
        case .info: Theme.accent
        case .unknown: .secondary
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}
