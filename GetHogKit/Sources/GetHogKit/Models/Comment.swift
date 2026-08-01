import Foundation

/// What a comment is for.
///
/// PostHog's serializer may add values such as `emoji_reaction`, so an
/// unrecognised type is quarantined rather than
/// dropped: it is still something a colleague wrote, and hiding it makes a
/// thread read as though replies are missing.
public enum CommentType: Sendable, Hashable {
    case conversation
    case review
    case unknown(String)

    init(raw: String?) {
        switch raw {
        case "conversation": self = .conversation
        case "review": self = .review
        case let other: self = .unknown(other ?? "conversation")
        }
    }

    public var title: String {
        switch self {
        case .conversation: return "Comment"
        case .review: return "Review"
        case .unknown(let raw):
            let words = raw.replacingOccurrences(of: "_", with: " ")
            guard let first = words.first else { return raw }
            return first.uppercased() + words.dropFirst()
        }
    }
}

/// The object a comment is attached to.
///
/// Comments are keyed by `scope` + `item_id`, which is the whole reason this app
/// has no Comments tab: a comment is an annotation *on* an insight or a
/// recording, and a list of them detached from what they annotate is a list of
/// sentences about nothing.
public enum CommentScope: String, Sendable, Hashable, CaseIterable {
    case insight
    case dashboard
    case recording
    case notebook
    case featureFlag = "feature_flag"
    case experiment
    case errorTrackingIssue = "error_tracking_issue"
}

/// A comment on a PostHog object.
///
/// Reading works with the personal API key this app already holds. Posting needs
/// `comment:write` and is not offered — see `PostHogAPI+Comments`.
public struct Comment: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let content: String
    /// `nil` when `created_by` is null, which is not an error: a comment filed
    /// by an automation has no user behind it.
    public let authorName: String?
    public let scope: String
    public let itemID: String?
    public let type: CommentType
    public let version: Int?
    public let createdAt: Date?
    public let deleted: Bool
    /// Documented as *"Cannot be set on replies or emoji reactions. Immutable
    /// after creation"* — so this is a property of the comment, not a state.
    /// Completion is what varies, and what a row has to show.
    public let isTask: Bool
    public let completedBy: String?
    public let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, content, scope, type, version, deleted
        case createdBy = "created_by"
        case itemID = "item_id"
        case createdAt = "created_at"
        case isTask = "is_task"
        case completedBy = "completed_by"
        case completedAt = "completed_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        // `rich_content` carries the same text as a ProseMirror tree. The plain
        // string is what a row can render, and `Notebook` already established
        // that carrying the tree buys nothing a phone can use.
        authorName = c.decodeUserName(forKey: .createdBy)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        // A uuid string on recordings, but a bare number on insights and
        // dashboards — where the id genuinely is an integer. Accepting only one
        // of the two loses every comment on half the objects this app can show.
        if let string = (try? c.decodeIfPresent(String.self, forKey: .itemID)) ?? nil {
            itemID = string
        } else if let number = (try? c.decodeIfPresent(Int.self, forKey: .itemID)) ?? nil {
            itemID = String(number)
        } else {
            itemID = nil
        }
        type = CommentType(raw: try c.decodeIfPresent(String.self, forKey: .type))
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        isTask = try c.decodeIfPresent(Bool.self, forKey: .isTask) ?? false
        completedBy = c.decodeUserName(forKey: .completedBy)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
            .flatMap(PostHogDate.parse)
    }

    /// A task is done when it has been completed, never merely because it is a
    /// task. `is_task` is immutable; `completed_at` is the part that changes.
    public var isCompleted: Bool { completedAt != nil }

    /// Who to show. A null author is named for what it is rather than left
    /// blank — a blank byline reads as a rendering bug — and never given an
    /// invented name that could be mistaken for a colleague.
    public var displayAuthor: String { authorName ?? "PostHog" }

    /// Oldest first, the way a thread is read.
    ///
    /// The API returns comments newest-first, so rendering the response order
    /// puts a reply above the thing it replies to.
    public static func oldestFirst(_ a: Comment, _ b: Comment) -> Bool {
        switch (a.createdAt, b.createdAt) {
        case (let x?, let y?): x < y
        // An undated comment sorts last rather than to the top of the thread:
        // its position is unknown, and guessing "oldest" would rewrite the
        // conversation.
        case (nil, _?): false
        case (_?, nil): true
        case (nil, nil): a.id < b.id
        }
    }
}

/// The response from `GET .../comments/count/`.
///
/// A separate sub-resource because the list endpoint is cursor-paginated and
/// carries no `count` of its own — `results.count` is a page size, not a total.
public struct CommentCount: Sendable, Decodable, Hashable {
    public let count: Int

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case count
    }
}
