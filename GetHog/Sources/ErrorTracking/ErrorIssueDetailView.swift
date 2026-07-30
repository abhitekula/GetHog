import GetHogKit
import SwiftUI

/// One error issue: what happened, where, and what to do about it.
///
/// This screen used to end at "GetHog doesn't render stack traces", which was
/// honest about a gap rather than a design — triage on a phone is the single most
/// natural thing to do with error tracking, and it stopped one tap short of
/// being useful. It now loads the newest `$exception` occurrence for the issue
/// and renders its frames (`StackTraceView`), and it can resolve, suppress,
/// reopen and assign (`ErrorTriageController`).
///
/// The frames are a *second* request, made only when this screen opens. The list
/// query returns no stack at all — nor does `GET /error_tracking/issues/:id/`,
/// measured — so the frames come from the events the issue groups, bounded to
/// the issue's own first-seen…last-seen window.
struct ErrorIssueDetailView: View {
    let issue: ErrorIssue
    let triage: ErrorTriageController

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var stack = ExceptionStackStore()

    /// The change being confirmed. Never cleared on dismissal, so the dialog's
    /// wording doesn't flicker while it animates away — same reason
    /// `FlagDetailView` keeps `requestedActivation`.
    @State private var requestedStatus: ErrorIssueStatus = .resolved
    @State private var isConfirmingStatus = false
    @State private var isConfirmingUnassign = false

    /// The issue with our own in-flight writes laid over it.
    private var live: ErrorIssue { triage.effective(issue) }

    private var webURL: URL? { model.webURL(path: "error_tracking/\(issue.id)") }

    var body: some View {
        ScrollView {
            // Padded per block rather than around the stack: `StatStrip` carries
            // its own insets so the figures can scroll edge to edge.
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                    .padding(.horizontal, Theme.Space.l)
                impact
                triageSection
                    .padding(.horizontal, Theme.Space.l)
                if issue.function?.isEmpty == false || issue.library?.isEmpty == false {
                    origin
                        .padding(.horizontal, Theme.Space.l)
                }
                stackSection
                    .padding(.horizontal, Theme.Space.l)
            }
            .padding(.vertical, Theme.Space.l)
        }
        .pageSurface()
        .navigationTitle(issue.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let webURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: webURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share a link to this issue")
                }
            }
        }
        .task(id: issue.id) {
            guard let client = model.client, let projectID = model.projectID else { return }
            await stack.load(client: client, projectID: projectID, issue: issue)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isConfirmingStatus,
            titleVisibility: .visible
        ) {
            Button(
                requestedStatus.actionTitle,
                // Destructive styling on suppression only. Resolve is a label
                // change and an undo away; suppression changes what the project
                // collects. Marking both red would make neither mean anything.
                role: requestedStatus.isDestructive ? .destructive : nil
            ) {
                commit(requestedStatus)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationDetail)
        }
        .confirmationDialog(
            "Remove the assignee?",
            isPresented: $isConfirmingUnassign,
            titleVisibility: .visible
        ) {
            Button("Unassign") { assign(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nobody will own this issue until someone is assigned again.")
        }
        .sensoryFeedback(.success, trigger: triage.successCount)
        .sensoryFeedback(.error, trigger: triage.failureCount)
    }

    // MARK: - Header

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(issue.name)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    StatusPill(text: live.statusTitle, tint: live.statusTint)
                }

                if let description = issue.issueDescription, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if issue.firstSeen != nil || issue.lastSeen != nil {
                    Divider()
                    seenRow("First seen", issue.firstSeen)
                    seenRow("Last seen", issue.lastSeen)
                }
            }
        }
    }

    @ViewBuilder
    private func seenRow(_ title: String, _ date: Date?) -> some View {
        if let date {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.subheadline.monospacedDigit())
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(title) \(date.formatted(date: .abbreviated, time: .shortened)), \(date.formatted(.relative(presentation: .named)))"
            )
        }
    }

    // MARK: - Impact

    /// The three figures that decide whether this issue is worth anyone's
    /// morning. `StatStrip` scrolls them sideways rather than stacking or
    /// compressing, so a figure is never shaved down to fit.
    private var impact: some View {
        StatStrip {
            impactFigure("Users", issue.users)
            impactFigure("Sessions", issue.sessions)
            impactFigure("Occurrences", issue.occurrences)
        }
    }

    private func impactFigure(_ title: String, _ value: Double) -> some View {
        MetricTile(label: title, value: value.compactFormatted, compact: true)
            // Spoken at full precision: "12.4K" is a reading aid, not a figure,
            // and speech has no trouble with the whole number.
            .accessibilityLabel(
                "\(value.formatted(.number.precision(.fractionLength(0)))) \(title.lowercased())"
            )
    }

    // MARK: - Triage

    /// The write surface, and the only one in this feature.
    ///
    /// Buttons rather than swipe actions, on the detail screen rather than the
    /// list, for the reason `FlagDetailView` concentrates flag writes in one
    /// place: reaching a destructive control should cost a deliberate tap into
    /// the thing being changed. It matters more here than there, because
    /// suppression is the one action in the app that changes what PostHog
    /// *stores* — a swipe-to-suppress on a scrolling list is a data-loss gesture
    /// two pixels from a scroll.
    private var triageSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Triage", systemImage: "checkmark.circle")
                    Spacer(minLength: 8)
                    if triage.isBusy(issue) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving change")
                    }
                }

                statusControls
                Divider()
                assigneeControls

                if let message = triage.message {
                    TriageMessageView(message: message) { triage.dismissMessage() }
                }

                Text("Changes here are written to PostHog straight away and are visible to your whole team. You'll be asked to confirm first.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The statuses this issue can be moved *to*.
    ///
    /// Only the three PostHog accepts on a write. It reports five — an issue can
    /// come back `archived` or `pending_release` — but its own PATCH schema
    /// documents those two as rejected, so offering them would be offering a
    /// button that cannot work. An issue already in one of them still displays
    /// correctly and can still be moved out.
    @ViewBuilder
    private var statusControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Status")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Wraps at accessibility sizes and on narrow columns rather than
            // squeezing three labelled buttons into one row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { statusButtons }
                VStack(alignment: .leading, spacing: Theme.Space.s) { statusButtons }
            }
        }
    }

    @ViewBuilder
    private var statusButtons: some View {
        ForEach(ErrorIssueStatus.allCases, id: \.self) { status in
            if status.rawValue != triage.effectiveStatus(issue) {
                Button {
                    requestedStatus = status
                    isConfirmingStatus = true
                } label: {
                    Label(status.actionTitle, systemImage: symbol(for: status))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(status.isDestructive ? Theme.accentWarm : Theme.accent)
                .disabled(triage.isBusy(issue))
                .accessibilityHint(status.consequence)
            }
        }
    }

    private func symbol(for status: ErrorIssueStatus) -> String {
        switch status {
        case .active: "arrow.counterclockwise"
        case .resolved: "checkmark.circle"
        case .suppressed: "bell.slash"
        }
    }

    @ViewBuilder
    private var assigneeControls: some View {
        let assignee = triage.effectiveAssignee(issue)

        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Assignee")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(assigneeDescription(assignee))
                    .font(.subheadline)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Assignee, \(assigneeDescription(assignee))")

            HStack(spacing: Theme.Space.s) {
                if let me = model.me?.userID, assignee != .user(me) {
                    Button {
                        assign(.user(me))
                    } label: {
                        Label("Assign to me", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                    .disabled(triage.isBusy(issue))
                }

                if assignee != nil {
                    Button {
                        isConfirmingUnassign = true
                    } label: {
                        Label("Unassign", systemImage: "person.crop.circle.badge.xmark")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(triage.isBusy(issue))
                }
            }

            // The honest limit, stated where it bites rather than hidden behind
            // an empty picker. PostHog assigns to users *or* roles, and both are
            // organisation-level resources: measured against this project's key,
            // `GET /api/organizations/@current/members/` answers 403 and
            // `…/roles/` answers *"API keys with scoped projects are only
            // supported on project-based endpoints."* A project-scoped key —
            // which is what onboarding asks for — cannot enumerate either, so the
            // app offers the one target it can always name and points elsewhere
            // for the rest.
            if model.me?.userID != nil {
                Text("Assigning to a teammate or a role needs the organisation member list, which a project-scoped API key can't read. Use the web console for those.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("GetHog doesn't know your PostHog user id yet, so it can't assign this to you. Reconnect in Settings.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Names the assignee as precisely as the data allows.
    ///
    /// PostHog returns an id and a kind, never a name — `{"id": [REMOVED PRIVATE DATA], "type":
    /// "user"}` — so anyone but the signed-in user can only be identified by
    /// number. Printing a bare id as if it were a person would be worse than
    /// saying which kind of thing it is.
    private func assigneeDescription(_ assignee: ErrorIssueAssignee?) -> String {
        guard let assignee else { return "Unassigned" }
        if assignee.kind == .user, let me = model.me?.userID, assignee == .user(me) {
            return "You"
        }
        return "\(assignee.kind == .role ? "Role" : "User") \(assignee.identifier.description)"
    }

    private var confirmationTitle: String {
        switch requestedStatus {
        case .active: "Reopen this issue?"
        case .resolved: "Mark this issue resolved?"
        case .suppressed: "Suppress this issue?"
        }
    }

    private var confirmationDetail: String {
        let target = model.selectedProject.map { " in \($0.name)" } ?? ""
        return "\(requestedStatus.consequence) This applies to everyone\(target)."
    }

    private func commit(_ status: ErrorIssueStatus) {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            await triage.setStatus(status, issue: issue, client: client, projectID: projectID)
        }
    }

    private func assign(_ assignee: ErrorIssueAssignee?) {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            await triage.setAssignee(assignee, issue: issue, client: client, projectID: projectID)
        }
    }

    // MARK: - Origin

    private var origin: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Origin", systemImage: "arrow.triangle.branch")
                if let function = issue.function, !function.isEmpty {
                    detailRow("Function", function, monospaced: true)
                }
                if let library = issue.library, !library.isEmpty {
                    detailRow("Library", library, monospaced: false)
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String, monospaced: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }

    // MARK: - Stack trace

    @ViewBuilder
    private var stackSection: some View {
        if let occurrence = stack.occurrence {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                stackHeader(occurrence)
                StackTraceView(occurrence: occurrence)
                if !occurrence.steps.isEmpty {
                    ExceptionStepsView(steps: occurrence.steps)
                }
                openInPostHog
            }
        } else if stack.isLoading {
            Card {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Loading the latest occurrence…")
                        .font(.footnote)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
        } else {
            unavailableStack
        }
    }

    /// Names *which* occurrence is on screen.
    ///
    /// An issue groups many events and this is one of them — the newest. Without
    /// saying so, a reader would reasonably take the frames for the issue's
    /// definitive stack, and two occurrences of the same issue can differ.
    private func stackHeader(_ occurrence: ExceptionOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Stack trace", systemImage: "text.alignleft")
            if let timestamp = occurrence.timestamp {
                Text("The most recent occurrence, \(timestamp.formatted(.relative(presentation: .named))).")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
            } else {
                Text("The most recent occurrence of this issue.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
    }

    /// The three ways there is no trace, told apart.
    ///
    /// A failed query, a query that succeeded and found nothing, and a project
    /// this build cannot reach are different facts, and the middle one is not an
    /// error — PostHog stores exception events for a retention window, and an
    /// issue whose last occurrence has aged out still lists.
    private var unavailableStack: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Stack trace", systemImage: "text.alignleft")

                if let error = stack.error {
                    Text("Couldn't load the frames for this issue.")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") {
                        Task {
                            guard let client = model.client, let projectID = model.projectID else {
                                return
                            }
                            await stack.load(client: client, projectID: projectID, issue: issue)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
                } else {
                    Text("No stored exception event was found for this issue in its own time window. PostHog keeps issues longer than it keeps the events behind them, so an older issue can outlive its last stack trace.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                openInPostHog
            }
        }
    }

    @ViewBuilder
    private var openInPostHog: some View {
        if let webURL {
            Link(destination: webURL) {
                Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    .font(.subheadline.weight(.medium))
            }
        }
    }
}

/// Result of a triage write. Same shape as the flag screen's, for the same
/// reason: a write that failed has to say so where the control was.
private struct TriageMessageView: View {
    let message: ErrorTriageMessage
    var onDismiss: () -> Void

    private var isFailure: Bool { message.kind == .failure }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isFailure ? Theme.Status.critical : Color.secondary)
                .accessibilityHidden(true)

            Text(message.text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.vertical, 2)
    }
}
