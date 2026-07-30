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

    /// Says what the resource *is* and why a project reasonably has none of it.
    ///
    /// Empty is the normal state on all five of these — a plain "nothing here"
    /// reads as a screen that failed rather than a project that never needed the
    /// feature, and that is the wrong impression to leave.
    var emptyDescription: String {
        switch self {
        case .workflows:
            "A workflow chains messaging and automation steps behind a trigger. None have been built in this project."
        case .endpoints:
            "An endpoint publishes a saved query over HTTP so another service can call it. None are defined here, which is what the zero counts above are reporting."
        case .alerts:
            "An alert watches one insight's value and fires when it crosses a threshold. Nothing on this project is being watched."
        case .subscriptions:
            "A subscription mails or posts an insight or dashboard on a schedule. Nobody has scheduled a delivery from this project."
        case .exports:
            "A batch export copies events or persons out to a warehouse or object store on a schedule. Nothing is leaving this project in bulk."
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

    /// Usage figures for the endpoints above. Held apart from `endpoints`
    /// because they answer a different question and fail independently — a usage
    /// outage must not blank the list of what exists.
    var usage: EndpointUsageOverview?
    var usageBreakdown: [EndpointUsageBreakdownRow] = []
    var usageError: String?
    var usageDimension: EndpointUsageDimension = .endpoint

    /// Keyed per section. Five independent resources, five independent
    /// permissions: one 403 must leave the other four on screen.
    var errors: [AutomationSection: String] = [:]
    var isLoading = false
    var loadedAt: Date?

    /// What the usage numbers actually mean, given how many endpoints exist.
    ///
    /// The distinction is the whole point: this project reports zero requests
    /// because it has **no endpoints defined**, not because traffic stopped. The
    /// usage query cannot tell those apart on its own — it answers 200 with
    /// zeros either way — so the endpoint count decides.
    var usageReading: EndpointUsageReading {
        (usage ?? EndpointUsageOverview(metrics: [])).reading(endpointCount: endpoints.count)
    }

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

        // After the list, because the reading depends on how many endpoints came
        // back — and skipped entirely when that list failed, since without a
        // count a zero here cannot be interpreted at all.
        if failures[.endpoints] == nil {
            await loadUsage(client: client, projectID: projectID)
        }
    }

    func loadUsage(client: PostHogClient, projectID: Int) async {
        async let overview = client.data(
            for: PostHogAPI.endpointsUsageOverview(projectID: projectID)
        )
        async let table = client.data(
            for: PostHogAPI.endpointsUsageTable(projectID: projectID, breakdownBy: usageDimension)
        )

        do {
            usage = try await EndpointUsageOverview.decode(from: overview)
            usageError = nil
        } catch {
            usage = nil
            usageError = Self.message(for: error)
        }

        do {
            usageBreakdown = try await EndpointUsageBreakdownRow.rows(
                from: QueryResponse.decode(from: table)
            )
        } catch {
            usageBreakdown = []
        }
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
        GlassFilterBar {
            Picker("Resource", selection: $section) {
                ForEach(AutomationSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .labelStyle(.iconOnly)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            // Stays on the picker rather than on the glass bar around it: a
            // label on the container would not reach the control.
            .accessibilityLabel("Automation resource")
        }
        .padding(.vertical, Theme.Space.s)
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
                SectionLabel(text: section.title, systemImage: section.systemImage)
            } footer: {
                if let footer = section.footer {
                    Text(footer)
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.isEmpty)
    }

    @ViewBuilder
    private var sectionBody: some View {
        if let error = store.errors[section] {
            EmptyStateView(
                title: "Couldn't load \(section.title.lowercased())",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if section == .endpoints {
            // Endpoints alone carry a usage panel, which has to render even when
            // the list is empty — "no endpoints" is precisely what explains the
            // zeros, so the two belong on screen together.
            endpointsBody
        } else if store.count(for: section) == 0 && !store.isLoading {
            EmptyStateView(
                title: section.emptyTitle,
                systemImage: section.systemImage,
                message: section.emptyDescription
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            switch section {
            case .workflows:
                ForEach(store.workflows) {
                    WorkflowRowView(workflow: $0).automationRowCard()
                }
            case .endpoints:
                EmptyView()
            case .alerts:
                ForEach(store.alerts) {
                    InsightAlertRowView(alert: $0).automationRowCard()
                }
            case .subscriptions:
                ForEach(store.subscriptions) {
                    SubscriptionRowView(subscription: $0).automationRowCard()
                }
            case .exports:
                ForEach(store.exports) {
                    BatchExportRowView(export: $0).automationRowCard()
                }
            }
        }
    }

    @ViewBuilder
    private var endpointsBody: some View {
        EndpointUsagePanel(store: store) { Task { await reloadUsage() } }

        if store.endpoints.isEmpty && !store.isLoading {
            EmptyStateView(
                title: section.emptyTitle,
                systemImage: section.systemImage,
                message: section.emptyDescription
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(store.endpoints) {
                QueryEndpointRowView(endpoint: $0).automationRowCard()
            }
        }
    }

    private func reloadUsage() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.loadUsage(client: client, projectID: projectID)
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

// MARK: - Endpoint usage

/// Usage figures for the project's query endpoints.
///
/// The one thing this view exists to get right: **a zero that means "nothing is
/// configured" must not read as "traffic dropped to nothing."** They are
/// different statements and only one of them is alarming. When no endpoint is
/// defined, the metric grid is withheld entirely and replaced by the sentence
/// that explains it — a wall of eight zeros invites exactly the wrong reading,
/// and no amount of caption text next to it undoes that first impression.
struct EndpointUsagePanel: View {
    @Bindable var store: AutomationStore
    var onDimensionChange: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(
                    title: "Usage",
                    systemImage: "chart.bar",
                    subtitle: "Last 7 days"
                )

                Text(store.usageReading.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = store.usageError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.Status.critical)
                        .lineLimit(3)
                } else if store.usageReading != .noEndpointsDefined {
                    metrics
                    breakdown
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
    }

    private var metrics: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 108), spacing: Theme.Space.m)],
            alignment: .leading,
            spacing: Theme.Space.m
        ) {
            ForEach(store.usage?.metrics ?? []) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(metric.formattedValue)
                        .font(.title3.weight(.semibold).monospacedDigit())

                    // PostHog returns `previous` and the change percentage as
                    // null here, which is *absent*, not zero. Drawing a 0% delta
                    // would assert a flat trend the API never reported.
                    if metric.hasComparison, let previous = metric.previous {
                        DeltaBadge(current: metric.value ?? 0, previous: previous)
                    } else {
                        Text("No prior period")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spokenMetric(metric))
            }
        }
    }

    @ViewBuilder
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker("Break down by", selection: $store.usageDimension) {
                ForEach(EndpointUsageDimension.allCases) { dimension in
                    Text(dimension.title).tag(dimension)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.usageDimension) { onDimensionChange() }

            if store.usageBreakdown.isEmpty {
                Text("Nothing to break down by \(store.usageDimension.title.lowercased()) in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.usageBreakdown) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                        // Labels come from the response's own column names: this
                        // table's columns could not be observed live, and a
                        // guessed heading over a real number is worse than a
                        // plain one.
                        Text(
                            row.measures
                                .map { "\($0.name) \($0.value.compactFormatted)" }
                                .joined(separator: " · ")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func spokenMetric(_ metric: EndpointUsageMetric) -> String {
        var parts = ["\(metric.title), \(metric.formattedValue)"]
        if !metric.hasComparison {
            parts.append("no prior period reported")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Rows

struct WorkflowRowView: View {
    let workflow: Workflow

    var body: some View {
        DataRow(
            glyph: "arrow.triangle.branch",
            tint: workflow.status == .active ? Theme.accent : .secondary,
            title: workflow.name,
            subtitle: workflow.triggerSummary,
            footnote: workflow.description,
            accessory: .pill(workflow.status.title, automationTint(workflow.status))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(workflow.name), \(workflow.status.title), \(workflow.triggerSummary)"
        )
    }
}

struct QueryEndpointRowView: View {
    let endpoint: QueryEndpoint

    var body: some View {
        DataRow(
            glyph: "network",
            tint: Theme.accent,
            // The name is what a caller puts in a URL. It leads the row as its
            // title rather than as a monospaced second line, because it is also
            // the only label an endpoint has.
            title: endpoint.name,
            subtitle: endpoint.description ?? endpoint.queryKind,
            footnote: detailLine,
            // The fallback is the stored query node's own `kind` — a schema type
            // name, so it is set as one.
            isSubtitleMonospaced: endpoint.description == nil,
            accessory: .pill(
                endpoint.statusText,
                endpoint.isActive ? Theme.Status.good : .secondary
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(endpoint.name), \(endpoint.statusText), "
                + "\(endpoint.description ?? endpoint.queryKind ?? "query kind unknown"), "
                + detailLine
        )
    }

    /// Freshness and shape, minus the query kind — that now leads the row's
    /// second line when there is no description to put there.
    private var detailLine: String {
        var parts = [
            endpoint.lastExecutedAt
                .map { "Last run \($0.formatted(.relative(presentation: .named)))" }
                ?? "Never run"
        ]
        if endpoint.isMaterialized { parts.append("materialised") }
        return parts.joined(separator: " · ")
    }
}

struct InsightAlertRowView: View {
    let alert: InsightAlert

    var body: some View {
        DataRow(
            // A firing alert gets the badged bell and the critical tint, so the
            // one row worth acting on is findable before the pill is read.
            glyph: alert.state == .firing ? "bell.badge" : "bell",
            tint: alert.state == .firing ? Theme.Status.critical : Theme.accent,
            title: alert.displayTitle,
            subtitle: detailLine,
            footnote: alert.enabled ? nil : "Not being evaluated",
            accessory: .pill(alert.state.title, alertTint(alert.state))
        )
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
        DataRow(
            // The destination is the row's kind — an email digest and a webhook
            // post are different things to go looking for.
            glyph: subscription.target.systemImage,
            tint: subscription.enabled ? Theme.accent : .secondary,
            title: subscription.displayTitle,
            subtitle: detailLine,
            footnote: nextDeliveryText,
            accessory: .pill(
                subscription.statusText,
                subscription.enabled ? Theme.Status.good : .secondary
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(subscription.displayTitle), \(subscription.target.title), \(subscription.statusText), \(detailLine)"
        )
    }

    /// Only promised for an enabled subscription: PostHog keeps sending a next
    /// date for paused ones, and printing it would state a delivery that is not
    /// going to happen.
    private var nextDeliveryText: String? {
        guard subscription.enabled, let next = subscription.nextDeliveryDate else { return nil }
        return "Next \(next.formatted(.relative(presentation: .named)))"
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
        DataRow(
            glyph: "shippingbox",
            tint: export.lastRunHealth == .failed ? Theme.Status.critical : Theme.accent,
            title: export.name,
            subtitle: detailLine,
            footnote: runLine,
            accessory: accessory
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    /// The pill reports the run, not the schedule — an export that is nominally
    /// running but whose last run errored is not doing its job, and "Running"
    /// alone would say it is. A paused export is the exception: it has no
    /// current run to report on.
    private var accessory: RowAccessory {
        if export.paused { return .pill("Paused", .secondary) }
        switch export.lastRunHealth {
        case .healthy: return .pill("Succeeded", Theme.Status.good)
        case .failed: return .pill("Failed", Theme.Status.critical)
        case .running: return .pill("Running", Theme.accent)
        case .paused: return .pill("Cancelled", .secondary)
        // `latest_runs` was empty, which is not a run that reported nothing.
        case .unknown: return .pill("Never run", .secondary)
        }
    }

    private var runLine: String {
        if let error = export.lastRunError { return error }
        if let last = export.lastRunAt {
            return "Last run \(last.formatted(.relative(presentation: .named))) · \(export.lastRunHealth.title)"
        }
        return "Never run"
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

// MARK: - Row chrome and formatting
//
// File-private so concurrent work on other screens can't collide with the name.

private extension View {
    /// The list treatment from the dashboards screen: every row is its own card
    /// on the page ground, with the system separator suppressed because the gap
    /// between cards already does that work.
    func automationRowCard() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}

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
