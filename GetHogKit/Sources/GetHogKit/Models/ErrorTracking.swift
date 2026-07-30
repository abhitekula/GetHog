import Foundation

public struct ErrorTrackingResponse: Sendable, Decodable {
    public let issues: [ErrorIssue]

    enum CodingKeys: String, CodingKey { case results }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = (try? c.decodeIfPresent([ErrorIssue].self, forKey: .results)) ?? []
    }

    public static func decode(from data: Data) throws -> ErrorTrackingResponse {
        try JSONDecoder().decode(ErrorTrackingResponse.self, from: data)
    }
}

public struct ErrorIssue: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let issueDescription: String?
    public let status: String
    public let library: String?
    public let function: String?
    /// The file the error was last raised in, when PostHog resolved one.
    /// Observed as `/_next/static/chunks/6561-….js` for an unresolved bundle and
    /// as `webpack://_N_E/…/server-action-reducer.ts` for a resolved one.
    public let source: String?
    public let firstSeen: Date?
    public let lastSeen: Date?
    public let assignee: ErrorIssueAssignee?

    private let aggregations: Aggregations?

    struct Aggregations: Sendable, Decodable, Hashable {
        let occurrences: Double?
        let sessions: Double?
        let users: Double?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, status, library, function, source, aggregations, assignee
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown error"
        issueDescription = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        library = try c.decodeIfPresent(String.self, forKey: .library)
        function = try c.decodeIfPresent(String.self, forKey: .function)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        firstSeen = try c.decodeIfPresent(String.self, forKey: .firstSeen).flatMap(PostHogDate.parse)
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen).flatMap(PostHogDate.parse)
        aggregations = try? c.decodeIfPresent(Aggregations.self, forKey: .aggregations)
        assignee = try? c.decodeIfPresent(ErrorIssueAssignee.self, forKey: .assignee)
    }

    // Counts live under `aggregations`; the identically-named top-level columns
    // are present but null.
    public var occurrences: Double { aggregations?.occurrences ?? 0 }
    public var sessions: Double { aggregations?.sessions ?? 0 }
    public var users: Double { aggregations?.users ?? 0 }

    public var isResolved: Bool { status == "resolved" }
    public var isSuppressed: Bool { status == "suppressed" }

    /// The issue's status as a value the app can *write back*.
    ///
    /// `nil` for `archived` and `pending_release`, which PostHog still returns on
    /// read but rejects on write — see `ErrorIssueStatus`.
    public var writableStatus: ErrorIssueStatus? { ErrorIssueStatus(rawValue: status) }

    /// The issue's status as PostHog reports it, including the two deprecated
    /// values. `nil` only for a status this build has never heard of.
    public var readStatus: ErrorIssueReadStatus? { ErrorIssueReadStatus(rawValue: status) }

    /// Returns a copy with a different status, for optimistic display while a
    /// write is in flight. Nothing here talks to the API.
    public func withStatus(_ status: ErrorIssueStatus) -> ErrorIssue {
        ErrorIssue(copying: self, status: status.rawValue, assignee: assignee)
    }

    /// Returns a copy with a different assignee, for the same reason.
    public func withAssignee(_ assignee: ErrorIssueAssignee?) -> ErrorIssue {
        ErrorIssue(copying: self, status: status, assignee: assignee)
    }

    private init(copying other: ErrorIssue, status: String, assignee: ErrorIssueAssignee?) {
        id = other.id
        name = other.name
        issueDescription = other.issueDescription
        self.status = status
        library = other.library
        function = other.function
        source = other.source
        firstSeen = other.firstSeen
        lastSeen = other.lastSeen
        self.assignee = assignee
        aggregations = other.aggregations
    }

    /// Test and preview seam. Not used by the decoding path.
    public init(
        id: String,
        name: String,
        issueDescription: String? = nil,
        status: String = "active",
        library: String? = nil,
        function: String? = nil,
        source: String? = nil,
        firstSeen: Date? = nil,
        lastSeen: Date? = nil,
        assignee: ErrorIssueAssignee? = nil
    ) {
        self.id = id
        self.name = name
        self.issueDescription = issueDescription
        self.status = status
        self.library = library
        self.function = function
        self.source = source
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.assignee = assignee
        aggregations = nil
    }
}

/// The three statuses PostHog accepts on a **write**.
///
/// Deliberately narrower than what it returns, and the gap is the point.
///
/// PostHog reports **five** statuses. `ErrorTrackingIssueStatus` in the live
/// OpenAPI document (`GET https://us.posthog.com/api/schema/?format=json`,
/// fetched 2026-07-30) lists `archived`, `active`, `resolved`, `pending_release`,
/// `suppressed`, and PostHog's own dashboard-widget documentation offers the same
/// five as filters. But the **write** enum, `ErrorTrackingIssueWriteStatusEnum`,
/// lists three, and the PATCH body's own description says why: *"Issue status to
/// set. Deprecated archived and pending_release values are rejected."*
///
/// So this type is the writable set and `ErrorIssueReadStatus` is the reported
/// set. Collapsing them would let the app build a request PostHog documents that
/// it refuses, and offer the user a button that cannot work.
public enum ErrorIssueStatus: String, Sendable, CaseIterable, Hashable, Codable {
    case active
    case resolved
    case suppressed

    public var title: String { ErrorIssueReadStatus(rawValue: rawValue)?.title ?? rawValue }

    /// The verb for the control that moves an issue *into* this status.
    public var actionTitle: String {
        switch self {
        case .active: "Reopen"
        case .resolved: "Resolve"
        case .suppressed: "Suppress"
        }
    }

    /// What the user is agreeing to. Shown in the confirmation dialog, so it has
    /// to be the *consequence*, not a restatement of the button.
    ///
    /// Suppression is the one that is not merely a label. PostHog's own
    /// documentation: *"Suppressed — Mark issues you choose not to action.
    /// Typically used for noisy or unhelpful issues. Note that **suppressing an
    /// issue will drop any associated exceptions**."* Dropped events are also
    /// unbilled events, which makes this the only triage action in the app that
    /// changes what the project *stores* rather than how it is labelled.
    ///
    /// Resolve is the one with a surprise in the other direction, and it is a
    /// pleasant one worth stating on a phone: *"Resolved — Mark issues that are
    /// fixed. If the issue reoccurs, it's automatically reopened."* Someone
    /// resolving an issue from a train should know it will come back by itself
    /// rather than believing they have silenced it.
    public var consequence: String {
        switch self {
        case .active:
            "This issue goes back into the active list. New occurrences keep being recorded."
        case .resolved:
            "PostHog stops listing this as active. If it happens again it reopens itself, so this is not permanent."
        case .suppressed:
            "PostHog will drop new exceptions for this issue instead of storing them. You stop collecting data on it — not just the alerts — until you reopen it. Everything already recorded is kept."
        }
    }

    /// Whether the action needs the stronger confirmation and must never be
    /// reachable from a swipe.
    public var isDestructive: Bool { self == .suppressed }
}

/// Every status PostHog can *report*, including the two it will not accept back.
///
/// Exists so an issue that comes back `archived` or `pending_release` is
/// displayed as what it is rather than as raw JSON, while
/// `ErrorIssue.writableStatus` still refuses to offer it as a destination.
public enum ErrorIssueReadStatus: String, Sendable, CaseIterable, Hashable {
    case active
    case resolved
    case suppressed
    case archived
    case pendingRelease = "pending_release"

    public var title: String {
        switch self {
        case .active: "Active"
        case .resolved: "Resolved"
        case .suppressed: "Suppressed"
        case .archived: "Archived"
        case .pendingRelease: "Pending release"
        }
    }

    /// Whether GetHog can move an issue *out of* this status.
    ///
    /// The two deprecated statuses read fine and write back fine — `active` is a
    /// legal destination from anywhere — so this is `true` for all five. Kept as
    /// a property rather than assumed, because it is the question a reader of
    /// this file will ask next.
    public var isWritable: Bool { true }
}

/// Who an issue is assigned to.
///
/// PostHog assigns to a **user** (integer id) or a **role** (uuid string), so the
/// id is not one type — `ErrorTrackingIssueAssignee.id` in the OpenAPI document
/// is `anyOf: [string, integer]`. Kept as the two cases rather than as a string,
/// because the id has to go back out in a request body with its original JSON
/// type or the API sees a different assignee.
public struct ErrorIssueAssignee: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case user
        case role
    }

    public enum Identifier: Sendable, Hashable {
        case number(Int)
        case text(String)

        public var description: String {
            switch self {
            case .number(let value): String(value)
            case .text(let value): value
            }
        }

        /// The value as it must appear in a JSON body: an integer stays an
        /// integer. Sending `"[REMOVED PRIVATE DATA]"` where PostHog expects `[REMOVED PRIVATE DATA]` is the
        /// kind of mismatch that a 200 hides.
        public var jsonValue: Any {
            switch self {
            case .number(let value): value
            case .text(let value): value
            }
        }
    }

    public let identifier: Identifier
    public let kind: Kind

    public var id: String { "\(kind.rawValue):\(identifier.description)" }

    public init(identifier: Identifier, kind: Kind) {
        self.identifier = identifier
        self.kind = kind
    }

    public static func user(_ id: Int) -> ErrorIssueAssignee {
        ErrorIssueAssignee(identifier: .number(id), kind: .user)
    }

    enum CodingKeys: String, CodingKey { case id, type }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(Int.self, forKey: .id) {
            identifier = .number(value)
        } else if let value = try? c.decode(String.self, forKey: .id) {
            identifier = .text(value)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: c,
                debugDescription: "assignee id was neither an integer nor a string"
            )
        }
        kind = (try? c.decode(Kind.self, forKey: .type)) ?? .user
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch identifier {
        case .number(let value): try c.encode(value, forKey: .id)
        case .text(let value): try c.encode(value, forKey: .id)
        }
        try c.encode(kind, forKey: .type)
    }

    /// The `assignee` object as `JSONSerialization` needs it.
    public var jsonBody: [String: Any] {
        ["id": identifier.jsonValue, "type": kind.rawValue]
    }
}
