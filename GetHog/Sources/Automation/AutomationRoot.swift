import GetHogKit
import SwiftUI

/// The five operational resources this screen covers.
///
/// One screen rather than five tabs: these are low-frequency admin surfaces, and
/// most projects have nothing in most of them. Five near-empty tabs would cost
/// more attention than they return.
enum AutomationSection: String, CaseIterable, Identifiable, Hashable {
    case workflows
    case endpoints
    case alerts
    case subscriptions
    case exports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workflows: "Workflows"
        case .endpoints: "Endpoints"
        case .alerts: "Alerts"
        case .subscriptions: "Subscriptions"
        case .exports: "Exports"
        }
    }

    var systemImage: String {
        switch self {
        case .workflows: "arrow.triangle.branch"
        case .endpoints: "network"
        case .alerts: "bell"
        case .subscriptions: "envelope"
        case .exports: "arrow.up.doc"
        }
    }

    /// Kept short deliberately: `ContentUnavailableView` gives its title a single
    /// line and truncates rather than wrapping, so "No workflows in this project"
    /// renders as "No workflows in this p…" on a phone. The qualifier belongs in
    /// the description, which does wrap.
    var emptyTitle: String {
        switch self {
        case .workflows: "No workflows"
        case .endpoints: "No query endpoints"
        case .alerts: "No alerts"
        case .subscriptions: "No subscriptions"
        case .exports: "No batch exports"
        }
    }

    var emptyDescription: String {
        switch self {
        case .workflows:
            "Messaging and automation workflows built in PostHog will appear here."
        case .endpoints:
            "Saved queries published over HTTP will appear here."
        case .alerts:
            "Alerts watching an insight's value will appear here."
        case .subscriptions:
            "Scheduled insight and dashboard deliveries will appear here."
        case .exports:
            "Scheduled bulk exports to a warehouse or object store will appear here."
        }
    }

    /// Said on the screen, not just in a commit message: GetHog reads these.
    var footer: String? {
        switch self {
        case .alerts:
            "Viewing only. GetHog has no server to receive a notification, so alerts are read here and managed in PostHog."
        case .subscriptions:
            "Viewing only. Deliveries are sent by PostHog to the destinations below — GetHog neither sends nor receives them."
        case .endpoints:
            "Listing an endpoint does not run it."
        default:
            nil
        }
    }

}

@MainActor
@Observable
final class AutomationStore {
    var workflows: [Workflow] = []
    var endpoints: [QueryEndpoint] = []
    var alerts: [InsightAlert] = []
    var subscriptions: [InsightSubscription] = []
    var exports: [BatchExport] = []

    /// Keyed per section. Five independent resources, five independent
    /// permissions: one 403 must leave the other four on screen.
    var errors: [AutomationSection: String] = [:]
    var isLoading = false
    var loadedAt: Date?

    var isEmpty: Bool {
        workflows.isEmpty && endpoints.isEmpty && alerts.isEmpty
            && subscriptions.isEmpty && exports.isEmpty
    }

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }

        // Issued together — five sequential round trips on a phone is a visible
        // wait — then unwrapped one at a time so a failure is confined to its
        // own section.
        async let flowPage: Page<Workflow> = client.send(
            PostHogAPI.hogFlows(projectID: projectID)
        )
        async let endpointPage: Page<QueryEndpoint> = client.send(
            PostHogAPI.queryEndpoints(projectID: projectID)
        )
        async let alertPage: Page<InsightAlert> = client.send(
            PostHogAPI.alerts(projectID: projectID)
        )
        async let subscriptionPage: Page<InsightSubscription> = client.send(
            PostHogAPI.subscriptions(projectID: projectID)
        )
        async let exportPage: Page<BatchExport> = client.send(
            PostHogAPI.batchExports(projectID: projectID)
        )

        var failures: [AutomationSection: String] = [:]

        do {
            // Live ones first, then alphabetical — a draft is not what you opened
            // this screen to check on.
            workflows = try await flowPage.results.sorted {
                ($0.status == .active ? 0 : 1, $0.name) < ($1.status == .active ? 0 : 1, $1.name)
            }
        } catch {
            failures[.workflows] = Self.message(for: error)
        }

        do {
            endpoints = try await endpointPage.results.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            failures[.endpoints] = Self.message(for: error)
        }

        do {
            // Firing first: an alert screen exists for the alert that is firing.
            alerts = try await alertPage.results.sorted {
                ($0.state == .firing ? 0 : 1, $0.displayTitle)
                    < ($1.state == .firing ? 0 : 1, $1.displayTitle)
            }
        } catch {
            failures[.alerts] = Self.message(for: error)
        }

        do {
            subscriptions = try await subscriptionPage.results
                .filter { !$0.deleted }
                .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        } catch {
            failures[.subscriptions] = Self.message(for: error)
        }

        do {
            // Trouble first, same reasoning as the warehouse screen.
            exports = try await exportPage.results.sorted {
                ($0.lastRunHealth.severity, $0.name) < ($1.lastRunHealth.severity, $1.name)
            }
        } catch {
            failures[.exports] = Self.message(for: error)
        }

        errors = failures
        if failures.count < AutomationSection.allCases.count { loadedAt = Date() }
    }

    func count(for section: AutomationSection) -> Int {
        switch section {
        case .workflows: workflows.count
        case .endpoints: endpoints.count
        case .alerts: alerts.count
        case .subscriptions: subscriptions.count
        case .exports: exports.count
        }
    }

    /// Sections whose last load failed, for the banner.
    var failedSections: [AutomationSection] {
        AutomationSection.allCases.filter { errors[$0] != nil }
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

struct AutomationRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = AutomationStore()
    @State private var section: AutomationSection = .workflows

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Automation")
                .toolbar { ProjectSwitcher() }
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
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
        } else {
            VStack(spacing: 0) {
                picker
                list
            }
            .background(Theme.pageBackground)
        }
    }

    /// Icons rather than words: five labels including "Subscriptions" truncate to
    /// nonsense at phone width. `.iconOnly` keeps each segment's title for
    /// VoiceOver, and the section header directly below always names the
    /// selected one in full, so nothing is left to the glyph alone.
    private var picker: some View {
        Picker("Resource", selection: $section) {
            ForEach(AutomationSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .labelStyle(.iconOnly)
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityLabel("Automation resource")
    }

    private var list: some View {
        List {
            if !store.failedSections.isEmpty {
                Section {
                    AutomationFailureBanner(sections: store.failedSections, store: store)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }

            Section {
                sectionBody
            } header: {
                Label(section.title, systemImage: section.systemImage)
            } footer: {
                if let footer = section.footer {
                    Text(footer)
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .skeleton(store.isLoading && store.isEmpty)
    }

    @ViewBuilder
    private var sectionBody: some View {
        if let error = store.errors[section] {
            ContentUnavailableView {
                Label("Couldn't load \(section.title.lowercased())", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.count(for: section) == 0 && !store.isLoading {
            ContentUnavailableView(
                section.emptyTitle,
                systemImage: section.systemImage,
                description: Text(section.emptyDescription)
            )
        } else {
            switch section {
            case .workflows:
                ForEach(store.workflows) { WorkflowRowView(workflow: $0) }
            case .endpoints:
                ForEach(store.endpoints) { QueryEndpointRowView(endpoint: $0) }
            case .alerts:
                ForEach(store.alerts) { InsightAlertRowView(alert: $0) }
            case .subscriptions:
                ForEach(store.subscriptions) { SubscriptionRowView(subscription: $0) }
            case .exports:
                ForEach(store.exports) { BatchExportRowView(export: $0) }
            }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Failure banner

/// Names the resources that failed, so a reader looking at four healthy lists
/// knows the fifth is missing rather than empty.
struct AutomationFailureBanner: View {
    let sections: [AutomationSection]
    let store: AutomationStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(headline, systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Status.critical)

                ForEach(sections) { section in
                    Text("\(section.title): \(store.errors[section] ?? "failed to load")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        sections.count == 1
            ? "1 resource didn't load"
            : "\(sections.count) resources didn't load"
    }
}

// MARK: - Rows

struct WorkflowRowView: View {
    let workflow: Workflow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(workflow.name).font(.body).lineLimit(2)
                Spacer(minLength: 8)
                StatusPill(text: workflow.status.title, tint: automationTint(workflow.status))
            }

            Text(workflow.triggerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let description = workflow.description {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(workflow.name), \(workflow.status.title), \(workflow.triggerSummary)"
        )
    }
}

struct QueryEndpointRowView: View {
    let endpoint: QueryEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The name is what a caller puts in a URL, so it stays monospaced.
                Text(endpoint.name).font(.subheadline.monospaced()).lineLimit(1)
                Spacer(minLength: 8)
                StatusPill(
                    text: endpoint.statusText,
                    tint: endpoint.isActive ? Theme.Status.good : .secondary
                )
            }

            if let description = endpoint.description {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            Text(detailLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.name), \(endpoint.statusText), \(detailLine)")
    }

    private var detailLine: String {
        var parts: [String] = []
        parts.append(endpoint.queryKind ?? "Query kind unknown")
        if endpoint.isMaterialized { parts.append("materialised") }
        if let last = endpoint.lastExecutedAt {
            parts.append("last run \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never run")
        }
        return parts.joined(separator: " · ")
    }
}

struct InsightAlertRowView: View {
    let alert: InsightAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(alert.displayTitle).font(.body).lineLimit(2)
                Spacer(minLength: 8)
                StatusPill(text: alert.state.title, tint: alertTint(alert.state))
            }

            Text(detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !alert.enabled {
                Text("Not being evaluated")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(alert.displayTitle), \(alert.state.title), \(detailLine)"
                + (alert.enabled ? "" : ", not being evaluated")
        )
    }

    private var detailLine: String {
        var parts: [String] = []
        if let insight = alert.insightName { parts.append("Watches \(insight)") }
        if let threshold = alert.thresholdSummary { parts.append(threshold) }
        if let value = alert.lastValue {
            parts.append("last \(value.compactFormatted)")
        }
        return parts.isEmpty ? "No threshold reported" : parts.joined(separator: " · ")
    }
}

struct SubscriptionRowView: View {
    let subscription: InsightSubscription

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(subscription.displayTitle, systemImage: subscription.target.systemImage)
                    .font(.body)
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusPill(
                    text: subscription.statusText,
                    tint: subscription.enabled ? Theme.Status.good : .secondary
                )
            }

            Text(detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let next = subscription.nextDeliveryDate, subscription.enabled {
                Text("Next \(next.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(subscription.displayTitle), \(subscription.target.title), \(subscription.statusText), \(detailLine)"
        )
    }

    private var detailLine: String {
        var parts = ["\(subscription.target.title), \(subscription.scheduleSummary)"]
        if let value = subscription.targetValue { parts.append(value) }
        return parts.joined(separator: " · ")
    }
}

struct BatchExportRowView: View {
    let export: BatchExport

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(export.name).font(.body).lineLimit(2)
                Spacer(minLength: 8)
                StatusPill(
                    text: export.statusText,
                    tint: export.paused ? .secondary : Theme.Status.good
                )
            }

            Text(detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = export.lastRunError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.Status.critical)
                    .lineLimit(2)
            } else if let last = export.lastRunAt {
                Text("Last run \(last.formatted(.relative(presentation: .named))) · \(export.lastRunHealth.title)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Never run")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var detailLine: String {
        var parts: [String] = []
        parts.append(export.destinationType ?? "Destination unknown")
        parts.append(export.scheduleSummary)
        if let model = export.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        var parts = ["\(export.name), \(export.statusText)", detailLine]
        if let error = export.lastRunError {
            parts.append("last error: \(error)")
        } else if let last = export.lastRunAt {
            parts.append("last run \(last.formatted(.relative(presentation: .named))), \(export.lastRunHealth.title)")
        } else {
            parts.append("never run")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Formatting
//
// File-private so concurrent work on other screens can't collide with the name.

/// Tint for a workflow state. Always paired with the state's own words.
private func automationTint(_ status: WorkflowStatus) -> Color {
    switch status {
    case .active: Theme.Status.good
    case .draft: .secondary
    case .archived: .secondary
    case .unknown: .secondary
    }
}

/// Tint for an alert state. Firing is the only one worth colouring.
private func alertTint(_ state: AlertState) -> Color {
    switch state {
    case .firing: Theme.Status.critical
    case .errored: Theme.Status.critical
    case .notFiring: Theme.Status.good
    case .snoozed: .secondary
    case .unknown: .secondary
    }
}
