import Foundation

// PostHog Support, from `GET /conversations/tickets/`.
//
// **Not Max.** `GET /conversations/` — the same prefix without `/tickets/` — is
// the Max AI assistant's threads, modelled in `MaxConversation.swift`. Two
// unrelated products share the `conversations` namespace, they return completely
// different payloads, and the shorter path is the one that answers first for
// anything matching on a prefix. Every route, fixture and matcher that touches
// either must name `/conversations/tickets/` in full.
//
// Everything in this file was derived from PostHog's OpenAPI document — the
// `Ticket`, `TicketPerson`, `TicketAssignment` and `TicketMessage` components,
// and the query parameters documented on the list operation. Where the schema
// is loose the model is loose, and every enum keeps an unknown raw string.

// MARK: - Status

/// Where a ticket is in its life.
///
/// `TicketStatusEnum` documents five members. They are quarantined rather than
/// defaulted because the service can extend its vocabulary; silently folding an
/// unfamiliar status into `.open` would misrepresent what the inbox is holding.
public enum TicketStatus: Sendable, Hashable {
    case new
    case open
    case pending
    case onHold
    case resolved
    /// A member `TicketStatusEnum` did not have when this shipped.
    case unknown(String)

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "new": self = .new
        case "open": self = .open
        case "pending": self = .pending
        case "on_hold": self = .onHold
        case "resolved": self = .resolved
        case let other?: self = .unknown(other)
        case nil: self = .unknown("unknown")
        }
    }

    public var title: String {
        switch self {
        case .new: "New"
        case .open: "Open"
        case .pending: "Pending"
        case .onHold: "On hold"
        case .resolved: "Resolved"
        case .unknown(let raw): TicketVocabulary.humanise(raw)
        }
    }

    /// A shape per status, so the list is readable without colour. Every status
    /// on this screen carries a word too; the glyph is the second encoding, not
    /// a replacement for one.
    public var systemImage: String {
        switch self {
        case .new: "circle.fill"
        case .open: "envelope.open"
        case .pending: "clock"
        case .onHold: "pause.circle"
        case .resolved: "checkmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// Resolved is the only status that takes a ticket out of the queue. An
    /// unrecognised one is treated as still live, because assuming a status this
    /// client cannot read means "done" is the assumption that loses work.
    public var isResolved: Bool { self == .resolved }
}

// MARK: - Priority

/// How severe somebody judged this to be.
///
/// Four documented bands plus two kinds of absence. `priority` is
/// `oneOf [TicketPriorityEnum, BlankEnum, NullEnum]`, so both `null` and `""` are
/// documented values, and the schema spells out what they mean: "Null if unset."
/// Unset is **not** low — nobody has triaged this — and the app says "Not set"
/// rather than inventing a band.
public enum TicketPriority: Sendable, Hashable {
    case critical
    case high
    case medium
    case low
    /// `null` or `""`. Nobody assigned one.
    case unset
    /// A member `TicketPriorityEnum` did not have when this shipped.
    case unknown(String)

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "critical": self = .critical
        case "high": self = .high
        case "medium": self = .medium
        case "low": self = .low
        case nil, "": self = .unset
        case let other?: self = .unknown(other)
        }
    }

    public var title: String {
        switch self {
        case .critical: "Critical"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unset: "Not set"
        case .unknown(let raw): TicketVocabulary.humanise(raw)
        }
    }

    /// Severity as a shape, so priority is never read from tint alone.
    public var systemImage: String {
        switch self {
        case .critical: "exclamationmark.octagon"
        case .high: "exclamationmark.triangle"
        case .medium: "equal.circle"
        case .low: "arrow.down.circle"
        case .unset: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// Most severe first.
    ///
    /// `unknown` outranks `unset` deliberately: a value this client cannot read
    /// still means somebody set one, and no value at all means nobody has looked.
    /// Both sit below every documented band, because guessing where a new band
    /// belongs in a severity scale is exactly the invention this model avoids —
    /// this is a tie-break, not a claim about how bad the ticket is.
    public var rank: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .unknown: 4
        case .unset: 5
        }
    }
}

// MARK: - Channel

/// Where the ticket came in from.
///
/// `ChannelSourceEnum` documents five. Quarantined for the same reason as the
/// other two, and with more cause: adding a channel is how this product grows,
/// and a ticket shown as arriving from the wrong place sends the reply to the
/// wrong place too.
public enum TicketChannel: Sendable, Hashable {
    case widget
    case email
    case slack
    case teams
    case github
    case unknown(String)

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "widget": self = .widget
        case "email": self = .email
        case "slack": self = .slack
        case "teams": self = .teams
        case "github": self = .github
        case let other?: self = .unknown(other)
        case nil: self = .unknown("unknown")
        }
    }

    public var title: String {
        switch self {
        case .widget: "Widget"
        case .email: "Email"
        case .slack: "Slack"
        // The schema's own display name, which is longer than the slug.
        case .teams: "Microsoft Teams"
        case .github: "GitHub"
        case .unknown(let raw): TicketVocabulary.humanise(raw)
        }
    }

    public var systemImage: String {
        switch self {
        // Not `bubble.left.and.bubble.right`: that is the Max tab's own symbol,
        // and the two products are already confusable enough.
        case .widget: "message"
        case .email: "envelope"
        case .slack: "number.square"
        case .teams: "person.2"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .unknown: "questionmark.circle"
        }
    }
}

// MARK: - SLA

/// How a ticket stands against its deadline.
///
/// The thresholds are **PostHog's**, read off the `sla` query parameter this
/// endpoint accepts: "`breached` = past `sla_due_at`, `at-risk` = due within the
/// next hour, `on-track` = more than an hour remaining." Picking a different
/// window would put the app's idea of "at risk" out of step with the filter the
/// same team uses in the console, which is the one place they would compare it.
public enum TicketSLAState: Sendable, Hashable {
    case breached
    case atRisk
    case onTrack
    /// "Null means no SLA" — the schema's words. Distinct from a met deadline.
    case none

    public var title: String {
        switch self {
        case .breached: "SLA breached"
        case .atRisk: "SLA due within the hour"
        case .onTrack: "SLA on track"
        case .none: "No SLA"
        }
    }

    public var systemImage: String {
        switch self {
        case .breached: "clock.badge.exclamationmark"
        case .atRisk: "timer"
        case .onTrack: "checkmark.shield"
        case .none: "minus.circle"
        }
    }

    /// Urgency, not chronology.
    ///
    /// `onTrack` and `none` share a rank on purpose. A deadline that is still
    /// hours away is not a reason to read one ticket before another, so it says
    /// nothing more urgent than having no deadline at all; only breach and
    /// imminence are urgency. Separating them would let a quiet ticket with a
    /// deadline next week outrank an unread one with none.
    public var rank: Int {
        switch self {
        case .breached: 0
        case .atRisk: 1
        case .onTrack, .none: 2
        }
    }

    /// PostHog's own boundary for "at risk", in seconds.
    static let atRiskWindow: TimeInterval = 60 * 60
}

// MARK: - Assignment

/// Who owns the ticket — a person, or a role.
///
/// `TicketAssignment` has `id`, `user` and `role` all nullable and all
/// `required`, so an *unassigned* ticket still arrives as an object rather than
/// as `null`. `user` and `role` are typed only as
/// `{"additionalProperties": {"type": "string"}}` — a bag of strings with no
/// declared keys — so the display name is looked for under several plausible
/// ones rather than guessed at once and rendered blank if the guess was wrong.
public struct TicketAssignee: Sendable, Decodable, Hashable {
    public let id: String?
    public let kind: String?
    public let user: [String: String]
    public let role: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, type, user, role
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 }
        kind = ((try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 }
        user = ((try? c.decodeIfPresent([String: String].self, forKey: .user)) ?? nil) ?? [:]
        role = ((try? c.decodeIfPresent([String: String].self, forKey: .role)) ?? nil) ?? [:]
    }

    /// The name to show, or nil when this object is the unassigned shape.
    public var displayName: String? {
        if let name = Self.name(in: role) { return name }
        if let name = Self.name(in: user) { return name }
        return nil
    }

    /// Whether the assignment names a role rather than a person, which changes
    /// what "assigned" means to a reader: a queue has an owner, not a person.
    public var isRole: Bool { Self.name(in: role) != nil }

    private static func name(in bag: [String: String]) -> String? {
        if let name = bag["name"]?.trimmed, !name.isEmpty { return name }
        let parts = [bag["first_name"], bag["last_name"]]
            .compactMap { $0?.trimmed }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if let email = bag["email"]?.trimmed, !email.isEmpty { return email }
        return nil
    }
}

// MARK: - Person

/// The customer, as `TicketPerson` serialises them.
///
/// Deliberately not `Person`: this is a five-field embed, not the full person
/// object the People screen reads, and treating them as one type would promise
/// properties this payload never carries.
public struct TicketPerson: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    /// Empty for an unidentified person, which PostHog serialises rather than
    /// omitting — so this is normalised to nil and callers fall back.
    public let name: String?
    public let distinctIDs: [String]
    public let properties: [String: JSONValue]
    public let createdAt: Date?
    public let isIdentified: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, properties
        case distinctIDs = "distinct_ids"
        case createdAt = "created_at"
        case isIdentified = "is_identified"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decode(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?.trimmed.nonEmpty
        distinctIDs = ((try? c.decodeIfPresent([String].self, forKey: .distinctIDs)) ?? nil) ?? []
        properties =
            ((try? c.decodeIfPresent([String: JSONValue].self, forKey: .properties)) ?? nil) ?? [:]
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil)
            .flatMap(PostHogDate.parse)
        isIdentified = ((try? c.decodeIfPresent(Bool.self, forKey: .isIdentified)) ?? nil) ?? false
    }

    public var email: String? {
        properties["email"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - AI triage

/// What PostHog's support AI made of the ticket before a human saw it.
///
/// `ai_triage` has **no declared type** in the schema — only a description,
/// which names its keys: "AI support pipeline triage and outcome (status,
/// result, ticket_type, confidence, attempts, etc.)." Those key names therefore
/// come from PostHog's own documentation of the field rather than from an
/// fixed payload contract, and every one of them is optional here because
/// "etc." is not a contract.
public struct TicketAITriage: Sendable, Decodable, Hashable {
    public let status: String?
    public let result: String?
    public let ticketType: String?
    public let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case status, result, confidence
        case ticketType = "ticket_type"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil)?.trimmed
        result = ((try? c.decodeIfPresent(String.self, forKey: .result)) ?? nil)?.trimmed
        ticketType = ((try? c.decodeIfPresent(String.self, forKey: .ticketType)) ?? nil)?.trimmed
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? nil
    }

    /// One line, or nil when the object carried nothing worth a row.
    public var summary: String? {
        let parts = [status, result, ticketType]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map(TicketVocabulary.humanise)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Ticket

/// One support ticket.
public struct SupportTicket: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let ticketNumber: Int?
    public let channel: TicketChannel
    /// The channel sub-type — `widget_embedded`, `slack_bot_mention`, and six
    /// others. Kept as its raw slug rather than promoted to an enum: nothing
    /// keys behaviour off it, it exists only to qualify the channel in a row,
    /// and an eighth value nobody has seen would cost a case for no gain.
    public let channelDetail: String?
    public let distinctID: String?
    public let status: TicketStatus
    public let priority: TicketPriority
    public let assignee: TicketAssignee?
    /// Genuinely three-valued, and the schema says why: "True when verified,
    /// false when assessed but not attested, null when unknown (e.g. created
    /// before this signal existed)." Collapsing null into false would report a
    /// ticket as failing a trust check that was never run against it.
    public let identityVerified: Bool?
    public let aiResolved: Bool
    public let escalationReason: String?
    public let aiTriage: TicketAITriage?
    public let messageCount: Int
    public let lastMessageAt: Date?
    public let lastMessageText: String?
    public let unreadTeamCount: Int
    public let unreadCustomerCount: Int
    public let sessionID: String?
    public let slaDueAt: Date?
    public let snoozedUntil: Date?
    public let slackChannelID: String?
    public let slackThreadTS: String?
    public let emailSubject: String?
    public let emailFrom: String?
    public let emailTo: String?
    /// Untyped in the schema — `{"readOnly": true}` and nothing more — so
    /// anything that is not a list of strings is dropped rather than guessed at.
    public let ccParticipants: [String]
    public let githubRepo: String?
    public let githubIssueNumber: Int?
    public let zendeskTicketID: Int?
    public let person: TicketPerson?
    /// "Customer-provided traits such as name and email", and the only identity
    /// an anonymous widget submitter has. Also untyped, so non-string values are
    /// dropped rather than rendered as their JSON.
    public let anonymousTraits: [String: String]
    /// `{"items": {}}` — an array whose element type is declared as *anything*.
    /// Strings are what a tag is; everything else is dropped.
    public let tags: [String]
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status, priority, assignee, person, tags
        case ticketNumber = "ticket_number"
        case channelSource = "channel_source"
        case channelDetail = "channel_detail"
        case distinctID = "distinct_id"
        case identityVerified = "identity_verified"
        case aiResolved = "ai_resolved"
        case escalationReason = "escalation_reason"
        case aiTriage = "ai_triage"
        case messageCount = "message_count"
        case lastMessageAt = "last_message_at"
        case lastMessageText = "last_message_text"
        case unreadTeamCount = "unread_team_count"
        case unreadCustomerCount = "unread_customer_count"
        case sessionID = "session_id"
        case slaDueAt = "sla_due_at"
        case snoozedUntil = "snoozed_until"
        case slackChannelID = "slack_channel_id"
        case slackThreadTS = "slack_thread_ts"
        case emailSubject = "email_subject"
        case emailFrom = "email_from"
        case emailTo = "email_to"
        case ccParticipants = "cc_participants"
        case githubRepo = "github_repo"
        case githubIssueNumber = "github_issue_number"
        case zendeskTicketID = "zendesk_ticket_id"
        case anonymousTraits = "anonymous_traits"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ticketNumber = (try? c.decodeIfPresent(Int.self, forKey: .ticketNumber)) ?? nil
        channel = TicketChannel(
            raw: (try? c.decodeIfPresent(String.self, forKey: .channelSource)) ?? nil
        )
        channelDetail = ((try? c.decodeIfPresent(String.self, forKey: .channelDetail)) ?? nil)?
            .nonEmpty
        distinctID = ((try? c.decodeIfPresent(String.self, forKey: .distinctID)) ?? nil)?.nonEmpty
        status = TicketStatus(raw: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil)
        priority = TicketPriority(
            raw: (try? c.decodeIfPresent(String.self, forKey: .priority)) ?? nil
        )
        assignee = (try? c.decodeIfPresent(TicketAssignee.self, forKey: .assignee)) ?? nil
        identityVerified = (try? c.decodeIfPresent(Bool.self, forKey: .identityVerified)) ?? nil
        aiResolved = ((try? c.decodeIfPresent(Bool.self, forKey: .aiResolved)) ?? nil) ?? false
        escalationReason = ((try? c.decodeIfPresent(String.self, forKey: .escalationReason)) ?? nil)?
            .nonEmpty
        aiTriage = (try? c.decodeIfPresent(TicketAITriage.self, forKey: .aiTriage)) ?? nil
        messageCount = ((try? c.decodeIfPresent(Int.self, forKey: .messageCount)) ?? nil) ?? 0
        lastMessageAt = ((try? c.decodeIfPresent(String.self, forKey: .lastMessageAt)) ?? nil)
            .flatMap(PostHogDate.parse)
        lastMessageText = ((try? c.decodeIfPresent(String.self, forKey: .lastMessageText)) ?? nil)?
            .nonEmpty
        unreadTeamCount = ((try? c.decodeIfPresent(Int.self, forKey: .unreadTeamCount)) ?? nil) ?? 0
        unreadCustomerCount =
            ((try? c.decodeIfPresent(Int.self, forKey: .unreadCustomerCount)) ?? nil) ?? 0
        sessionID = ((try? c.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil)?.nonEmpty
        slaDueAt = ((try? c.decodeIfPresent(String.self, forKey: .slaDueAt)) ?? nil)
            .flatMap(PostHogDate.parse)
        snoozedUntil = ((try? c.decodeIfPresent(String.self, forKey: .snoozedUntil)) ?? nil)
            .flatMap(PostHogDate.parse)
        slackChannelID = ((try? c.decodeIfPresent(String.self, forKey: .slackChannelID)) ?? nil)?
            .nonEmpty
        slackThreadTS = ((try? c.decodeIfPresent(String.self, forKey: .slackThreadTS)) ?? nil)?
            .nonEmpty
        emailSubject = ((try? c.decodeIfPresent(String.self, forKey: .emailSubject)) ?? nil)?
            .nonEmpty
        emailFrom = ((try? c.decodeIfPresent(String.self, forKey: .emailFrom)) ?? nil)?.nonEmpty
        emailTo = ((try? c.decodeIfPresent(String.self, forKey: .emailTo)) ?? nil)?.nonEmpty
        ccParticipants = Self.strings(c, forKey: .ccParticipants)
        githubRepo = ((try? c.decodeIfPresent(String.self, forKey: .githubRepo)) ?? nil)?.nonEmpty
        githubIssueNumber = (try? c.decodeIfPresent(Int.self, forKey: .githubIssueNumber)) ?? nil
        zendeskTicketID = (try? c.decodeIfPresent(Int.self, forKey: .zendeskTicketID)) ?? nil
        person = (try? c.decodeIfPresent(TicketPerson.self, forKey: .person)) ?? nil
        anonymousTraits =
            ((try? c.decodeIfPresent([String: String].self, forKey: .anonymousTraits)) ?? nil) ?? [:]
        tags = Self.strings(c, forKey: .tags)
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil)
            .flatMap(PostHogDate.parse)
        updatedAt = ((try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil)
            .flatMap(PostHogDate.parse)
    }

    /// Reads an array the schema declines to type. Non-strings are dropped, not
    /// stringified: `{"name": "legal"}` rendered as a tag would put a fragment of
    /// JSON on a chip.
    private static func strings(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String] {
        if let plain = (try? c.decodeIfPresent([String].self, forKey: key)) ?? nil {
            return plain.compactMap(\.nonEmpty)
        }
        guard let loose = (try? c.decodeIfPresent([JSONValue].self, forKey: key)) ?? nil else {
            return []
        }
        return loose.compactMap { value in
            guard case .string(let text) = value else { return nil }
            return text.nonEmpty
        }
    }

    // MARK: Derived state

    /// Whether the deadline has passed, is about to, or was never set.
    public func slaState(now: Date = Date()) -> TicketSLAState {
        guard let slaDueAt else { return .none }
        if slaDueAt <= now { return .breached }
        return slaDueAt.timeIntervalSince(now) <= TicketSLAState.atRiskWindow ? .atRisk : .onTrack
    }

    /// Whether somebody has explicitly deferred this ticket to a later time.
    public func isSnoozed(now: Date = Date()) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    /// Something arrived that nobody on the team has read.
    public var hasUnreadForTeam: Bool { unreadTeamCount > 0 }

    /// The customer's name, however little of one the payload carries.
    ///
    /// An anonymous widget submitter has no `person` at all, only
    /// `anonymous_traits`, so the fallbacks are not decoration — they are the
    /// only identity two of the five channels ever supply.
    public var requesterName: String? {
        person?.name
            ?? anonymousTraits["name"]?.nonEmpty
            ?? emailFrom
            ?? anonymousTraits["email"]?.nonEmpty
            ?? person?.email
    }

    /// Who to say the ticket is assigned to, or nil when nobody is.
    public var assigneeName: String? { assignee?.displayName }

    /// The line a row leads with.
    ///
    /// There is no `subject` field on a ticket: `email_subject` exists only for
    /// the email channel, so the other four channels fall back to naming the
    /// person, and a ticket with neither is named by its number rather than by
    /// an empty string.
    public var displayTitle: String {
        if let emailSubject { return emailSubject }
        if let requesterName { return requesterName }
        return reference
    }

    /// The ticket's human-facing identifier. `#` matches how the endpoint's own
    /// `search` parameter documents it ("a numeric value, optionally prefixed
    /// with `#`, matches a ticket number exactly").
    public var reference: String {
        ticketNumber.map { "Ticket #\($0)" } ?? "Ticket \(id.prefix(8))"
    }

    /// The last message, collapsed to one scannable line.
    ///
    /// `last_message_text` is raw body text — hard-wrapped email, quoted replies,
    /// Slack markdown — and a row that let it keep its newlines would be four
    /// rows tall for one of them and one row tall for the rest.
    public var snippet: String? {
        guard let lastMessageText else { return nil }
        let collapsed = lastMessageText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 160
            ? collapsed.prefix(160).trimmingCharacters(in: .whitespaces) + "…"
            : collapsed
    }

    /// When this ticket last did anything, which is what a reader means by "when".
    public var lastActivityAt: Date? { lastMessageAt ?? updatedAt ?? createdAt }

    /// The channel, qualified by its sub-type when there is one.
    public var channelSummary: String {
        guard let channelDetail else { return channel.title }
        return "\(channel.title) · \(TicketVocabulary.humanise(channelDetail))"
    }

    // MARK: Ordering

    /// Whether the ticket is asking for attention at all.
    ///
    /// Ranked ahead of every urgency signal, because both of the states below are
    /// somebody having already decided this ticket is not the next thing to read,
    /// and no amount of unread messages overrules that. Snoozed sits above
    /// resolved: a snooze expires, a resolution does not.
    func attentionRank(now: Date) -> Int {
        if status.isResolved { return 2 }
        if isSnoozed(now: now) { return 1 }
        return 0
    }

    /// Most urgent first.
    ///
    /// Four fields have a claim on "urgent" and they disagree, so they are
    /// applied in order of how *externally binding* each one is:
    ///
    /// 1. **`sla_due_at`** — the only deadline the team promised somebody else.
    ///    A breach is a promise already broken and cannot be outranked. It is
    ///    first despite being the sparsest field ("Null means no SLA"), because
    ///    when it *is* set it is the only signal with a consequence attached.
    /// 2. **`unread_team_count`** — something arrived that nobody has read.
    ///    Compared as a boolean, not as a count: a ticket with seven unread
    ///    messages is not seven times more urgent than one with a single unread
    ///    message, and ranking on the number lets one chatty thread bury a silent
    ///    critical one.
    /// 3. **`priority`** — a judgement made at some earlier point, which a later
    ///    message may already have overtaken, and which is unset on any ticket
    ///    nobody has triaged. Real, but stale by construction, so it breaks ties
    ///    rather than setting them.
    /// 4. **`last_message_at`** — recency, which is not urgency at all. It is
    ///    last because it is the field everyone reaches for first and the one
    ///    that says least: it is here to make the order deterministic and to put
    ///    the newer of two otherwise identical tickets on top.
    ///
    /// Ticket number breaks the final tie so the list cannot reshuffle between
    /// two refreshes of identical data.
    public static func mostUrgentFirst(
        _ a: SupportTicket,
        _ b: SupportTicket,
        now: Date = Date()
    ) -> Bool {
        let attention = (a.attentionRank(now: now), b.attentionRank(now: now))
        if attention.0 != attention.1 { return attention.0 < attention.1 }

        let sla = (a.slaState(now: now).rank, b.slaState(now: now).rank)
        if sla.0 != sla.1 { return sla.0 < sla.1 }

        if a.hasUnreadForTeam != b.hasUnreadForTeam { return a.hasUnreadForTeam }

        if a.priority.rank != b.priority.rank { return a.priority.rank < b.priority.rank }

        let activity = (a.lastActivityAt ?? .distantPast, b.lastActivityAt ?? .distantPast)
        if activity.0 != activity.1 { return activity.0 > activity.1 }

        return (a.ticketNumber ?? .min) > (b.ticketNumber ?? .min)
    }

    /// The list as the screen shows it.
    ///
    /// Sorted on the client because the server cannot express this: `order_by`
    /// accepts only `created_at`, `sla_due_at`, `ticket_number` and `updated_at`,
    /// so neither `priority` nor `unread_team_count` is available server-side at
    /// all. The consequence is worth being plain about — this ranks the page that
    /// was fetched, not the project.
    public static func triaged(_ tickets: [SupportTicket], now: Date = Date()) -> [SupportTicket] {
        tickets.sorted { mostUrgentFirst($0, $1, now: now) }
    }

    /// Unread messages waiting on the team, across the tickets that are still open.
    ///
    /// Resolved tickets are excluded, which is what PostHog's own
    /// `/conversations/tickets/unread_count/` documents itself as summing: "the
    /// sum of unread_team_count for all non-resolved tickets". That endpoint is
    /// deliberately **not** called — it would be a second request on a screen
    /// budgeted for one, against an organisation-wide rate limit — so this total
    /// covers the page in hand and the screen says so rather than presenting it
    /// as a project-wide figure.
    public static func unreadTeamTotal(_ tickets: [SupportTicket]) -> Int {
        tickets.filter { !$0.status.isResolved }.reduce(0) { $0 + $1.unreadTeamCount }
    }
}

// MARK: - Messages

/// Who wrote a message.
///
/// The schema documents the values as "One of: customer, support, AI" — note the
/// capitalisation, which is unlike every other enum on this endpoint and is why
/// the raw value is folded to lower case before matching.
public enum TicketMessageAuthor: Sendable, Hashable {
    case customer
    case support
    case ai
    case unknown(String)

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "customer": self = .customer
        case "support": self = .support
        case "ai": self = .ai
        case let other?: self = .unknown(other)
        case nil: self = .unknown("unknown")
        }
    }

    public var title: String {
        switch self {
        case .customer: "Customer"
        case .support: "Support"
        case .ai: "AI"
        case .unknown(let raw): TicketVocabulary.humanise(raw)
        }
    }

    public var systemImage: String {
        switch self {
        case .customer: "person"
        case .support: "person.badge.shield.checkmark"
        case .ai: "sparkles"
        case .unknown: "questionmark.circle"
        }
    }
}

/// One message in a ticket thread, from `GET /conversations/tickets/{id}/messages/`.
public struct TicketMessage: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    /// Plain-text body, or nil when the message carries only rich content.
    public let text: String?
    /// Whether a TipTap document came with it. Kept as a flag rather than a tree:
    /// this app does not render TipTap, and a message that is *only* rich content
    /// has to be named rather than shown blank.
    public let hasRichContent: Bool
    public let author: TicketMessageAuthor
    public let authorName: String?
    /// "True for internal notes not visible to the customer" — the one field on
    /// this endpoint that changes who a line was written for, so it is never
    /// merged into the thread silently.
    public let isPrivate: Bool
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, content
        case richContent = "rich_content"
        case authorType = "author_type"
        case authorName = "author_name"
        case isPrivate = "is_private"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decode(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        text = ((try? c.decodeIfPresent(String.self, forKey: .content)) ?? nil)?.trimmed.nonEmpty
        hasRichContent = ((try? c.decodeIfPresent(JSONValue.self, forKey: .richContent)) ?? nil)
            .map { $0 != .null } ?? false
        author = TicketMessageAuthor(
            raw: (try? c.decodeIfPresent(String.self, forKey: .authorType)) ?? nil
        )
        authorName = ((try? c.decodeIfPresent(String.self, forKey: .authorName)) ?? nil)?.nonEmpty
        isPrivate = ((try? c.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? nil) ?? false
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil)
            .flatMap(PostHogDate.parse)
    }

    /// Whether there is anything to print. False for a message that was only an
    /// image or an embed.
    public var isRenderable: Bool { text != nil }
}

// MARK: - Shared formatting

enum TicketVocabulary {
    /// Turns a slug into a sentence: `escalated_to_legal` → "Escalated to legal".
    ///
    /// Sentence case, not title case. `.capitalized` gives "Escalated To Legal",
    /// which reads as a proper noun and is wrong for every value this is applied
    /// to — all of them are states, not names.
    static func humanise(_ raw: String) -> String {
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return raw }
        return first.uppercased() + words.dropFirst()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}
