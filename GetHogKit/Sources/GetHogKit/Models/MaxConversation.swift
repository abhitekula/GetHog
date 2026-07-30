import Foundation

// Max AI threads, from `GET /conversations/`.
//
// GetHog reads these and never writes them: sending a message would start an
// agent run against the user's account and their AI usage budget, which is not
// something a read-only viewer should be able to do by accident.

/// Whether a thread is idle or Max is still working on it.
public enum MaxConversationStatus: Sendable, Hashable {
    case idle
    case inProgress
    case canceling
    case unknown

    public var title: String {
        switch self {
        case .idle: "Idle"
        case .inProgress: "Working"
        case .canceling: "Cancelling"
        case .unknown: "Unknown"
        }
    }

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "idle": self = .idle
        case "in_progress": self = .inProgress
        case "canceling", "cancelling": self = .canceling
        default: self = .unknown
        }
    }
}

/// Which Max surface produced the thread.
public enum MaxConversationKind: Sendable, Hashable {
    case assistant
    case deepResearch
    case slack
    case other

    public var title: String {
        switch self {
        case .assistant: "Max"
        case .deepResearch: "Deep research"
        case .slack: "Slack"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .assistant: "sparkles"
        case .deepResearch: "magnifyingglass"
        case .slack: "number.square"
        case .other: "bubble.left"
        }
    }

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "assistant": self = .assistant
        case "deep_research": self = .deepResearch
        case "slack": self = .slack
        default: self = .other
        }
    }
}

/// One Max thread's metadata. The list serializer stops here — messages arrive
/// only on retrieve.
public struct MaxConversation: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let topic: String?
    public let status: MaxConversationStatus
    public let kind: MaxConversationKind
    public let isInternal: Bool
    public let createdAt: Date?
    public let updatedAt: Date?
    public let authorName: String?
    public let slackWorkspace: String?

    enum CodingKeys: String, CodingKey {
        case id, title, topic, status, type, user
        case isInternal = "is_internal"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case slackWorkspaceDomain = "slack_workspace_domain"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // The viewset filters out untitled threads, so a blank title here means
        // something changed server-side rather than a thread in progress.
        title = (try c.decodeIfPresent(String.self, forKey: .title))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled conversation"
        topic = (try c.decodeIfPresent(String.self, forKey: .topic))
            .flatMap { $0.isEmpty ? nil : $0 }
        status = MaxConversationStatus(raw: try c.decodeIfPresent(String.self, forKey: .status))
        kind = MaxConversationKind(raw: try c.decodeIfPresent(String.self, forKey: .type))
        isInternal = try c.decodeIfPresent(Bool.self, forKey: .isInternal) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(PostHogDate.parse)
        authorName = c.decodeUserName(forKey: .user)
        slackWorkspace = (try c.decodeIfPresent(String.self, forKey: .slackWorkspaceDomain))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Last activity, which is what a reader means by "when".
    public var lastActivityAt: Date? { updatedAt ?? createdAt }

    /// Newest first. The API already orders by `-updated_at`, but a client that
    /// merges pages or filters must not depend on that holding.
    public static func newestFirst(_ conversations: [MaxConversation]) -> [MaxConversation] {
        conversations.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }
}

// MARK: - Thread

/// Who or what produced a message.
///
/// Max's message union grows with every agent feature, so anything unrecognised
/// keeps its raw discriminator rather than being folded into "assistant" — a
/// mislabelled speaker is worse than an honest "other".
public enum MaxMessageRole: Sendable, Hashable {
    case person
    case assistant
    case reasoning
    case visualization
    case failure
    case tool
    case other(String)

    public var title: String {
        switch self {
        case .person: "You"
        case .assistant: "Max"
        case .reasoning: "Max is thinking"
        case .visualization: "Chart"
        case .failure: "Max hit an error"
        case .tool: "Tool"
        case .other(let raw): raw
        }
    }

    public init(raw: String?) {
        switch raw {
        case "human": self = .person
        case "ai": self = .assistant
        case "ai/reasoning": self = .reasoning
        case "ai/viz", "ai/multi_visualization": self = .visualization
        case "ai/failure": self = .failure
        case "tool": self = .tool
        case let other?: self = .other(other)
        case nil: self = .other("unknown")
        }
    }
}

/// One rendered message from a thread.
public struct MaxMessage: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let role: MaxMessageRole
    /// Prose, when the message has any. Nil for messages whose payload is a
    /// query or a chart rather than text.
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case id, type, content
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Not every message shape carries an id; one is minted so the thread can
        // still be rendered by a ForEach.
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        role = MaxMessageRole(raw: try c.decodeIfPresent(String.self, forKey: .type))
        // `content` is a string on conversational messages and absent on the
        // structured ones. Decoded leniently so a new message shape cannot throw
        // and lose the whole thread.
        text = ((try? c.decodeIfPresent(String.self, forKey: .content)) ?? nil)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Whether this message can be shown as text at all.
    public var isRenderable: Bool { text != nil }
}

/// The retrieve payload: the same conversation fields plus the thread itself.
public struct MaxConversationThread: Sendable, Decodable {
    public let conversation: MaxConversation
    public let messages: [MaxMessage]
    /// PostHog's own admission that the stored thread contains something its
    /// current renderer cannot show.
    public let hasUnsupportedContent: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case hasUnsupportedContent = "has_unsupported_content"
    }

    public init(from decoder: any Decoder) throws {
        conversation = try MaxConversation(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = ((try? c.decodeIfPresent([MaxMessage].self, forKey: .messages)) ?? nil) ?? []
        hasUnsupportedContent = try c
            .decodeIfPresent(Bool.self, forKey: .hasUnsupportedContent) ?? false
    }
}
