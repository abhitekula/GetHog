import GetHogKit
import GetHogUI
import SwiftUI

// PostHog Support — the customer ticket inbox.
//
// **Not the Max screen.** `ConversationsRoot` in `Sources/Max` reads
// `GET /conversations/`, which is the AI assistant's threads. This reads
// `GET /conversations/tickets/`, which is a different product that happens to
// live under the same URL prefix. They are in separate folders, under separate
// sidebar sections, and neither one's fixtures, routes or cache keys may be
// matched on `/conversations/` alone.

// MARK: - Store

@MainActor
@Observable
final class SupportTicketsStore {
    private(set) var tickets: [SupportTicket] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    private var loadedScope: ResultScope?
    private var requestAuthority = ResultRequestAuthority()

    var resultState: ResultSurfaceState {
        ResultSurfaceState.resolve(
            lastSuccess: loadedAt.map {
                ResultSuccess(
                    content: tickets.isEmpty ? .empty : .populated,
                    updatedAt: $0,
                    scope: loadedScope
                )
            },
            currentScope: requestAuthority.currentScope,
            isLoading: requestAuthority.isLoading,
            failure: error.map { LoadFailure(summary: $0) }
        )
    }

    var search = ""

    /// One request. The endpoint also has an `/unread_count/` sub-resource, and
    /// calling it would cost a second round trip against an organisation-wide
    /// budget to learn one integer that `unread_team_count` already puts on every
    /// row — so the total below is computed from the page and labelled as such.
    func load(client: PostHogClient, authority: ResourceRequestAuthority) async {
        let scope = ResultScope.request(authority: authority)
        let token = requestAuthority.begin(scope: scope)
        isLoading = true
        defer {
            if requestAuthority.finish(token) { isLoading = false }
        }
        do {
            let page: Page<SupportTicket> = try await client.send(
                PostHogAPI.supportTickets(projectID: authority.projectID)
            )
            guard requestAuthority.owns(token) else { return }
            tickets = SupportTicket.triaged(page.results)
            loadedAt = Date()
            loadedScope = scope
            error = nil
        } catch {
            guard requestAuthority.owns(token) else { return }
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Narrows what is already loaded.
    ///
    /// The endpoint does take a `search` parameter, and it is better than this
    /// one — it reaches message bodies, which the client has not fetched. It is
    /// not used because it would be a request per keystroke against a rate-limit
    /// budget shared with everything else the organisation runs.
    var visible: [SupportTicket] {
        guard !search.isEmpty else { return tickets }
        return tickets.filter { ticket in
            ticket.displayTitle.localizedCaseInsensitiveContains(search)
                || (ticket.snippet ?? "").localizedCaseInsensitiveContains(search)
                || (ticket.requesterName ?? "").localizedCaseInsensitiveContains(search)
                || ticket.reference.localizedCaseInsensitiveContains(search)
                || ticket.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var unreadTotal: Int { SupportTicket.unreadTeamTotal(tickets) }

    var openCount: Int { tickets.filter { !$0.status.isResolved }.count }

    /// What the ranking below actually covers, said in words rather than
    /// implied. One page, and the screen never pretends otherwise.
    var pageDescription: String {
        tickets.count == 1
            ? "single ticket that came back"
            : "most recently active \(tickets.count) tickets"
    }
}

// MARK: - Root

/// The support inbox, read-only.
///
/// **Read-first by decision, not by omission.** Replying is
/// `POST /conversations/tickets/{id}/reply/` and it sends a message to a
/// customer. This app holds a read key; a reply typed on a phone that failed on
/// a missing `ticket:write` scope would have nowhere to go and no way to tell
/// anyone it never arrived. The screen says so in a sentence and links to
/// PostHog, in the same shape `DashboardTemplatesRoot` uses for "apply" — a
/// stated fact rather than a greyed-out button inviting a tap that cannot work.
struct SupportRoot: View {
    static let emptyPolicy = EmptyOutcomePolicy(
        title: "No support tickets",
        systemImage: "lifepreserver",
        message: "PostHog Support turns customer conversations into tickets. "
            + "This project holds none — the inbox answered, and it was empty.",
        actionTitle: "Reload"
    )

    static let emptyGuidePolicy = EmptyStateGuidePolicy(
        title: "How tickets reach GetHog",
        systemImage: "tray"
    )

    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = SupportTicketsStore()

    private var requestAuthority: ResourceRequestAuthority? {
        guard let client = model.client,
              let projectID = model.projectID,
              let authSessionID = model.authSessionID
        else { return nil }
        return .init(projectID: projectID, region: client.region, authSessionID: authSessionID)
    }

    /// The open ticket, and deliberately **not** `@State` and not a value on the
    /// container's path.
    ///
    /// This screen is one of `AppTab.secondary`, reached through the search
    /// tab, so it is hosted by a sidebar `Tab` above the size-class boundary and
    /// by the search stack below it — see `OpenDetails`. It used to push with
    /// `NavigationLink(value:)` into whichever stack the host provided, which
    /// held nothing this screen could read back: measured with ticket #101 open,
    /// dragging the window 834 → 375 → 834pt gave `navigationBars`
    /// `["Ticket #101"]` → `["Support"]` → `["Support"]`. The stack the ticket
    /// was pushed onto belonged to the sidebar `Tab`, which stops existing below
    /// the boundary, and the push went with it.
    ///
    /// Bound to `OpenDetails` instead, the ticket outlives both hosts and
    /// `navigationDestination(item:)` puts it back on whichever stack is
    /// currently underneath.
    private var selection: Binding<SupportTicket?> {
        Binding(
            get: { openDetails[.support] as? SupportTicket },
            set: { openDetails[.support] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        searchOwnedContent
            .navigationTitle("Support")
            .navigationDestination(item: selection) { SupportTicketDetailView(ticket: $0) }
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .task(id: requestAuthority) { await load() }
    }

    @ViewBuilder
    private var searchOwnedContent: some View {
        @Bindable var store = store
        if store.resultState.ownsSearch {
            content
                .screenRefreshable { await load() }
                .searchable(text: $store.search, prompt: "Search tickets")
        } else {
            content.screenRefreshable { await load() }
        }
    }

    // MARK: States

    /// There is no `LockedCapabilityView` here on purpose. `ScopePreflight`
    /// probes five capabilities and Support is not one of them, so claiming this
    /// screen is locked would be a guess. PostHog names the missing scope —
    /// `ticket:read` — in its own 403 body, and `PostHogError.forbidden` already
    /// turns that into a sentence, so the honest path is to let the request
    /// answer and show what it said.
    @ViewBuilder
    private var content: some View {
        switch store.resultState {
        case .loading:
            ResultLoadingState(title: "Loading support tickets…")

        case .failed(let failure):
            EmptyStateView(
                title: "Couldn't load tickets",
                systemImage: "exclamationmark.triangle",
                message: failure.summary,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )

        case .empty, .populated, .refreshing, .stale:
            if store.resultState.presentation == .empty {
                emptyResult
            } else if store.visible.isEmpty && !store.isLoading {
                VStack(spacing: 0) {
                    EmptyStateView(
                        title: "No matching tickets",
                        systemImage: "magnifyingglass",
                        message: "No subject, customer, tag or ticket number in the loaded page matches "
                            + "“\(store.search)”. Message bodies aren't searched on device — "
                            + "PostHog's own search reaches those."
                    )
                    retainedResultFooter
                }
            } else {
                list
            }
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 0) {
            emptyInbox

            if store.resultState.retainedUpdate != nil {
                ResultRetainedUpdateStatus(
                    state: store.resultState,
                    subject: "support tickets",
                    retry: { Task { await load() } }
                )
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let freshness = store.resultState.completedFreshness {
                ResultFreshnessLabel(freshness: freshness)
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .appGround()
    }

    @ViewBuilder
    private var retainedResultFooter: some View {
        if store.resultState.retainedUpdate != nil {
            ResultRetainedUpdateStatus(
                state: store.resultState,
                subject: "support tickets",
                retry: { Task { await load() } }
            )
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let freshness = store.resultState.completedFreshness {
            ResultFreshnessLabel(freshness: freshness)
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The state this screen will actually be seen in.
    ///
    /// This project has zero tickets, and so does every project that has not
    /// switched Support on — which is most of them. An empty state that only
    /// said "no tickets" would leave a reader unable to tell "Support is off"
    /// from "Support is on and quiet" from "this key cannot see them", so it
    /// names the product, the five channels a ticket can arrive through, and
    /// what a row would carry when one does.
    private var emptyInbox: some View {
        PageScaffold {
            CollectionEmptyState(
                policy: Self.emptyPolicy,
                action: { Task { await load() } }
            )
            Card {
                EmptyStateGuide(policy: Self.emptyGuidePolicy) {
                    Text(
                        "A ticket is one customer's conversation, wherever it started. "
                            + "Each row would show who it is from, the last thing they said, "
                            + "how long it has been open, and how many messages nobody on the "
                            + "team has read yet."
                    )
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    // Named rather than summarised: "various channels" tells a
                    // reader nothing about whether the one they care about is
                    // among them.
                    ForEach(Self.channels, id: \.channel) { entry in
                        DataRow(
                            glyph: entry.channel.systemImage,
                            title: entry.channel.title,
                            subtitle: entry.detail,
                            subtitleLineLimit: 2,
                            accessory: .none
                        )
                    }

                    Divider()

                    CardHeader(
                        title: "Nothing is hidden by a filter",
                        systemImage: "line.3.horizontal.decrease",
                        subtitle: "This screen asks for every ticket, newest activity first"
                    )
                    Text(
                        "No status, assignee or date filter is applied. If Support is set up "
                            + "and tickets exist, they are here — and if the key were missing "
                            + "the ticket:read scope, this screen would show that error instead "
                            + "of an empty inbox."
                    )
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    replyNote
                }
            }
            .readableMeasure(Theme.Measure.prose)
        }
    }

    /// The five members of `ChannelSourceEnum`, with what each one means. Read
    /// off PostHog's schema rather than listed from memory.
    private static let channels: [(channel: TicketChannel, detail: String)] = [
        (.widget, "The in-app support widget, embedded or driven through the API"),
        (.email, "A thread with your support address, subject line and CC list intact"),
        (.slack, "A channel message, a bot mention, or an emoji reaction on one"),
        (.teams, "A Teams channel message or a mention of the bot"),
        (.github, "An issue opened on a connected repository"),
    ]

    /// Selection-driven rather than push-driven.
    ///
    /// The binding on the `List` is what makes the row tap set `selection`
    /// instead of appending to a path this screen cannot read; the
    /// `navigationDestination(item:)` in `body` is what turns that selection
    /// back into a pushed screen. Both halves are required — a selection with no
    /// display leaves a tap that only highlights the row.
    private var list: some View {
        List(selection: selection) {
            if store.resultState.retainedUpdate != nil {
                ResultRetainedUpdateStatus(
                    state: store.resultState,
                    subject: "support tickets",
                    retry: { Task { await load() } }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                DataRow(
                    glyph: store.unreadTotal > 0 ? "envelope.badge" : "envelope.open",
                    tint: store.unreadTotal > 0 ? Theme.accentWarm : Theme.accent,
                    title: store.unreadTotal == 1
                        ? "1 unread message"
                        : "\(store.unreadTotal) unread messages",
                    subtitle: "Across \(store.openCount) unresolved "
                        + (store.openCount == 1 ? "ticket" : "tickets") + " on this page",
                    accessory: .none
                )
                .listRowBackground(cardRowBackground)
                .listRowSeparator(.hidden)
            } header: {
                SectionLabel(text: "Waiting on the team", systemImage: "tray.full")
            }

            Section {
                ForEach(store.visible) { ticket in
                    NavigationLink(value: ticket) {
                        SupportTicketRow(ticket: ticket)
                    }
                    .listRowBackground(cardRowBackground)
                    .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(text: "Most urgent first", systemImage: "arrow.up.arrow.down")
            } footer: {
                // Ranking is done here, not by PostHog, and that has a limit
                // worth stating: it can only reorder what was fetched.
                Text(
                    "Ranked by SLA breach, then unread messages, then priority, then recency. "
                        + "PostHog can't sort by priority or unread count, so this ranks the "
                        + store.pageDescription + ", not the project."
                )
            }

            Section {
                replyNote
                    .listRowBackground(Color.clear)
            }

            if let freshness = store.resultState.completedFreshness {
                ResultFreshnessLabel(freshness: freshness)
                    .listRowBackground(Color.clear)
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
    }

    private var cardRowBackground: some View {
        Theme.cardBackground
            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
    }

    private var replyNote: some View {
        SupportReplyNote(url: model.webURL(path: "support/tickets"))
    }

    private func load() async {
        guard let client = model.client, let authority = requestAuthority else { return }
        await store.load(client: client, authority: authority)
    }
}

// MARK: - Reply note

/// States plainly that this app will not answer a customer, and where to.
///
/// Written as a fact rather than as a disabled control, the same way the
/// template gallery handles "apply". The specific hazard here is worse than a
/// dead button: a reply is a message to somebody outside the company, and one
/// typed on a phone that failed on a missing scope would have nowhere to report
/// that it never sent.
struct SupportReplyNote: View {
    let url: URL?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(
                    title: "Replies stay in PostHog",
                    systemImage: "arrowshape.turn.up.left",
                    subtitle: "GetHog reads this inbox; it doesn't answer it"
                )

                Text(
                    "Sending a reply needs a `ticket:write` key, and it puts a message in "
                        + "front of a customer. A reply typed here that failed on a missing "
                        + "scope would have nowhere to tell you it never arrived, so this app "
                        + "doesn't offer one."
                )
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let url {
                    Link(destination: url) {
                        Label("Open Support in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
    }
}

// MARK: - Row

struct SupportTicketRow: View {
    let ticket: SupportTicket

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            DataRow(
                glyph: ticket.channel.systemImage,
                title: ticket.displayTitle,
                subtitle: previewText,
                footnote: metaLine,
                subtitleLineLimit: 2,
                accessory: unreadAccessory
            )

            SupportBadgeStrip(ticket: ticket)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /// The unread count, and only when there is one. "0 unread" on every row is
    /// noise hiding the rows that have some — which is the whole point of
    /// surfacing this field.
    ///
    /// The fallback is `.none`, not `.chevron`. This row is always inside a
    /// `NavigationLink` in a `List`, which draws its own disclosure indicator,
    /// so the chevron here landed beside it — and lower, because `DataRow`
    /// centres its accessory on the text block while the List centres on the
    /// whole row. Only the tickets with nothing unread doubled up, which is what
    /// made it read as a layout glitch rather than a rule being broken.
    private var unreadAccessory: RowAccessory {
        ticket.hasUnreadForTeam
            ? .pill("\(ticket.unreadTeamCount) unread", Theme.accentWarm)
            : .none
    }

    private var metaLine: String {
        var parts = [ticket.reference, ticket.channelSummary]
        parts.append("\(ticket.messageCount) message\(ticket.messageCount == 1 ? "" : "s")")
        if let activity = ticket.lastActivityAt {
            parts.append(activity.formatted(.relative(presentation: .named)))
        }
        if let assignee = ticket.assigneeName {
            parts.append(assignee)
        } else {
            // Absence worth saying: an unassigned ticket is nobody's, which is a
            // different problem from a slow one.
            parts.append("Unassigned")
        }
        return parts.joined(separator: " · ")
    }

    private var previewText: String {
        ticket.snippet ?? "Latest message has no text preview"
    }

    /// One sentence for VoiceOver, leading with the states a sighted reader gets
    /// from the badges.
    private var spoken: String {
        var parts = [ticket.displayTitle, ticket.status.title, "\(ticket.priority.title) priority"]
        let sla = ticket.slaState()
        if sla == .breached || sla == .atRisk { parts.append(sla.title) }
        if ticket.isSnoozed() { parts.append("Snoozed") }
        if ticket.hasUnreadForTeam { parts.append("\(ticket.unreadTeamCount) unread") }
        parts.append(metaLine)
        parts.append(previewText)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Badges

/// Status, priority and deadline, each as **word + glyph + tint**.
///
/// Never colour alone, and never a glyph alone: two of the three scales here are
/// severity scales, where a reader who cannot separate the hues would otherwise
/// be left guessing which end of it a row sits on.
struct SupportBadgeStrip: View {
    let ticket: SupportTicket
    /// Hidden inside a list row, where the row's own combined label already
    /// speaks every one of these; read aloud on the detail screen, where nothing
    /// else does. A parameter rather than an outer `.accessibilityHidden(false)`
    /// because that does not un-hide a subtree an inner modifier already hid.
    var hidesFromAccessibility: Bool = true

    var body: some View {
        // Wraps rather than truncating: at accessibility sizes three badges do
        // not share a phone's width, and a clipped one is a state the reader
        // cannot see.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { badges }
            VStack(alignment: .leading, spacing: Theme.Space.xs) { badges }
        }
        .accessibilityHidden(hidesFromAccessibility)
    }

    @ViewBuilder
    private var badges: some View {
        SupportBadge(
            text: ticket.status.title,
            systemImage: ticket.status.systemImage,
            tint: SupportTint.status(ticket.status)
        )
        SupportBadge(
            text: ticket.priority.title,
            systemImage: ticket.priority.systemImage,
            tint: SupportTint.priority(ticket.priority)
        )
        // Only when the deadline is actually a factor. "On track" and "No SLA"
        // on every row would crowd out the two states that mean something.
        if let sla = urgentSLA {
            SupportBadge(
                text: sla.title,
                systemImage: sla.systemImage,
                tint: SupportTint.sla(sla)
            )
        }
        if ticket.isSnoozed() {
            SupportBadge(text: "Snoozed", systemImage: "moon.zzz", tint: Theme.neutralMark)
        }
    }

    private var urgentSLA: TicketSLAState? {
        let state = ticket.slaState()
        return state == .breached || state == .atRisk ? state : nil
    }
}

/// A `StatusPill` with the shape that carries the same meaning beside it.
struct SupportBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            StatusPill(text: text, tint: tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// Tints for the three scales.
///
/// Chrome colours only — `SeriesPalette` belongs to chart data, and borrowing a
/// series hue for a status would imply a relationship to some plotted series
/// that does not exist.
enum SupportTint {
    static func status(_ status: TicketStatus) -> Color {
        switch status {
        case .new: Theme.accentWarm
        case .open: Theme.accent
        case .pending: Theme.accent
        case .onHold: Theme.neutralMark
        case .resolved: Theme.Status.good
        case .unknown: Theme.neutralMark
        }
    }

    static func priority(_ priority: TicketPriority) -> Color {
        switch priority {
        case .critical: Theme.Status.critical
        case .high: Theme.accentWarm
        case .medium: Theme.accent
        case .low: Theme.neutralMark
        // Untriaged and unrecognised both read as "no claim made", which is what
        // a neutral tint says. Colouring them would assert a severity nobody set.
        case .unset, .unknown: Theme.neutralMark
        }
    }

    static func sla(_ state: TicketSLAState) -> Color {
        switch state {
        case .breached: Theme.Status.critical
        case .atRisk: Theme.accentWarm
        case .onTrack: Theme.Status.good
        case .none: Theme.neutralMark
        }
    }
}

// MARK: - Detail store

@MainActor
@Observable
final class SupportThreadStore {
    private(set) var messages: [TicketMessage] = []
    private(set) var totalMessageCount: Int?
    private(set) var isLatestMessagePreview = false
    private(set) var isLoading = false
    private(set) var error: String?

    func load(client: PostHogClient, projectID: Int, ticketID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<TicketMessage> = try await client.send(
                PostHogAPI.supportTicketMessages(projectID: projectID, ticketID: ticketID)
            )
            messages = page.results
            totalMessageCount = page.count
            isLatestMessagePreview = page.previous != nil
                && page.next == nil
                && page.results.count == 1
                && (page.count ?? 0) > 1
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Detail

/// One ticket: who, where from, and what was said.
///
/// The ticket itself comes from the list row rather than from a second request —
/// `GET /conversations/tickets/{id}/` returns the same `Ticket` component the
/// list already serialised in full, so re-fetching it would spend a request to
/// learn nothing. The thread is the one thing the list does not carry.
struct SupportTicketDetailView: View {
    let ticket: SupportTicket

    @Environment(AppModel.self) private var model
    @State private var store = SupportThreadStore()

    var body: some View {
        List {
            summary
            customer
            channel
            handling
            thread

            Section {
                // `support/tickets/{id}` is PostHog's own route for this ticket,
                // read off the console's canonical route table — deliberately
                // not a `/conversations/` path, which is the API's spelling and
                // Max's page in the console.
                SupportReplyNote(url: model.webURL(path: "support/tickets/\(ticket.id)"))
                    .listRowBackground(Color.clear)
            }
        }
        .pageSurface()
        // Every label/value pair below stops at a readable measure instead of
        // spanning the window. See `Theme.Measure.pair`.
        .measuredPairs()
        .navigationTitle(ticket.reference)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Sections

    private var summary: some View {
        Section {
            Text(ticket.displayTitle)
                .font(Theme.Typography.title)
                .textSelection(.enabled)

            SupportBadgeStrip(ticket: ticket, hidesFromAccessibility: false)

            DataRow(
                glyph: ticket.channel.systemImage,
                title: ticket.channelSummary,
                subtitle: "\(ticket.messageCount) message"
                    + (ticket.messageCount == 1 ? "" : "s")
                    + (ticket.hasUnreadForTeam ? " · \(ticket.unreadTeamCount) unread" : ""),
                footnote: ticket.lastActivityAt.map {
                    "Last activity \($0.formatted(.relative(presentation: .named)))"
                },
                accessory: .none
            )
        } header: {
            SectionLabel(text: "Ticket", systemImage: "lifepreserver")
        }
    }

    @ViewBuilder
    private var customer: some View {
        Section {
            if let name = ticket.requesterName {
                LabeledContent("Name") { Text(name) }
            }
            if let email = ticket.person?.email ?? ticket.anonymousTraits["email"] {
                LabeledContent("Email") { Text(email).textSelection(.enabled) }
            }
            if let distinctID = ticket.distinctID {
                LabeledContent("Distinct ID") {
                    Text(distinctID).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            if let person = ticket.person {
                LabeledContent("Identified") { Text(person.isIdentified ? "Yes" : "No") }
            }
            // Three-valued, and the third value is the interesting one: PostHog
            // says null means the check predates the signal, not that it failed.
            LabeledContent("Identity verified") { Text(verificationText) }

            if ticket.person == nil && ticket.anonymousTraits.isEmpty {
                SectionEmptyState(
                    text: "No person is attached to this ticket, and the customer supplied no traits.",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            }
        } header: {
            SectionLabel(text: "Customer", systemImage: "person")
        } footer: {
            if let sessionID = ticket.sessionID,
               let url = model.webURL(path: "replay/\(sessionID)") {
                // Linked out rather than played here: this app can only fetch a
                // recording it has the id *and* the metadata for, and a ticket
                // carries only the id.
                Link(destination: url) {
                    Label("Open the linked session replay", systemImage: "play.rectangle")
                        .font(.footnote.weight(.medium))
                }
            }
        }
    }

    private var verificationText: String {
        switch ticket.identityVerified {
        case true: "Yes — attested by the server"
        case false: "No — checked, not attested"
        // PostHog's own wording for the null case.
        case nil: "Unknown — created before this signal existed"
        }
    }

    @ViewBuilder
    private var channel: some View {
        Section {
            LabeledContent("Channel") { Text(ticket.channelSummary) }
            if let subject = ticket.emailSubject {
                LabeledContent("Subject") { Text(subject) }
            }
            if let from = ticket.emailFrom {
                LabeledContent("From") { Text(from).textSelection(.enabled) }
            }
            if let to = ticket.emailTo {
                LabeledContent("To") { Text(to).textSelection(.enabled) }
            }
            if !ticket.ccParticipants.isEmpty {
                LabeledContent("CC") { Text(ticket.ccParticipants.joined(separator: ", ")) }
            }
            if let channelID = ticket.slackChannelID {
                LabeledContent("Slack channel") {
                    Text(channelID).font(.footnote.monospaced())
                }
            }
            if let repo = ticket.githubRepo {
                LabeledContent("GitHub") {
                    Text(ticket.githubIssueNumber.map { "\(repo)#\($0)" } ?? repo)
                }
            }
            if let zendesk = ticket.zendeskTicketID {
                LabeledContent("Zendesk ticket") { Text("#\(zendesk)") }
            }
        } header: {
            SectionLabel(text: "Where it came from", systemImage: ticket.channel.systemImage)
        }
    }

    @ViewBuilder
    private var handling: some View {
        Section {
            LabeledContent("Status") { Text(ticket.status.title) }
            LabeledContent("Priority") { Text(ticket.priority.title) }
            LabeledContent("Assignee") {
                Text(ticket.assigneeName ?? "Unassigned")
            }
            if ticket.assignee?.isRole == true {
                LabeledContent("Assigned to") { Text("A role, not a person") }
            }
            LabeledContent("SLA") {
                Text(slaText)
            }
            if let snoozed = ticket.snoozedUntil {
                LabeledContent("Snoozed until") {
                    Text(snoozed, format: .dateTime.day().month().hour().minute())
                }
            }
            if ticket.aiResolved {
                LabeledContent("Resolved by AI") { Text("Yes") }
            }
            if let triage = ticket.aiTriage?.summary {
                LabeledContent("AI triage") { Text(triage) }
            }
            if let reason = ticket.escalationReason {
                LabeledContent("Escalated because") { Text(reason) }
            }
            if !ticket.tags.isEmpty {
                LabeledContent("Tags") { Text(ticket.tags.joined(separator: ", ")) }
            }
        } header: {
            SectionLabel(text: "Handling", systemImage: "person.badge.shield.checkmark")
        }
    }

    private var slaText: String {
        let state = ticket.slaState()
        guard let due = ticket.slaDueAt else { return state.title }
        return "\(state.title) · \(due.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder
    private var thread: some View {
        Section {
            if store.isLoading && store.messages.isEmpty {
                Text(String(repeating: "Loading this thread ", count: 6))
                    .font(.callout)
                    .skeleton(true)
            } else if let error = store.error {
                SectionEmptyState(
                    text: "Couldn't load this ticket's messages.",
                    systemImage: "exclamationmark.triangle",
                    detail: error,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
            } else if store.messages.isEmpty {
                SectionEmptyState(
                    text: "PostHog returned no messages for this ticket.",
                    systemImage: "text.bubble"
                )
            } else {
                ForEach(store.messages) { message in
                    SupportMessageRow(message: message)
                }
            }
        } header: {
            SectionLabel(text: "Thread", systemImage: "text.bubble")
        } footer: {
            if store.isLatestMessagePreview, let total = store.totalMessageCount {
                Text(
                    "Showing the latest message preview. "
                        + "\(total - store.messages.count) earlier messages aren't loaded."
                )
            } else if let total = store.totalMessageCount, total > store.messages.count {
                Text("Showing \(store.messages.count) of \(total) messages.")
            }
            if store.messages.contains(where: \.isPrivate) {
                Text("Messages marked Internal note were never sent to the customer.")
            }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, ticketID: ticket.id)
    }
}

// MARK: - Message row

struct SupportMessageRow: View {
    let message: TicketMessage

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: message.author.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Text(message.authorName ?? message.author.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Status.ink(for: tint))
                if message.isPrivate {
                    // A word, never the tint alone: whether a line went to the
                    // customer is the single most consequential thing about it.
                    StatusPill(text: "Internal note", tint: Theme.accentWarm)
                }
                Spacer(minLength: 0)
                if let created = message.createdAt {
                    Text(created, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }

            if let text = message.text {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                // Named rather than skipped. A dropped message makes a thread
                // look like nobody answered.
                Text(placeholder)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var placeholder: String {
        message.hasRichContent
            ? "An attachment or formatted block. Open the ticket in PostHog to see it."
            : "This message has no text."
    }

    private var tint: Color {
        switch message.author {
        case .customer: Theme.accentWarm
        case .support: Theme.accent
        case .ai: Theme.accent
        case .unknown: Theme.neutralMark
        }
    }

    private var spoken: String {
        var parts = [message.authorName ?? message.author.title]
        if message.isPrivate { parts.append("internal note") }
        parts.append(message.text ?? placeholder)
        return parts.joined(separator: ", ")
    }
}
