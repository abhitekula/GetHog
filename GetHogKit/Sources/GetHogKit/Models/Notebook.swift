import Foundation

// MARK: - Shared nested user

/// The `UserBasicSerializer` object PostHog embeds under `created_by`,
/// `last_modified_by`, `user` and friends.
///
/// Internal, and reduced to a display name on the way out: every screen that
/// shows one of these wants a name, and none of them want the eleven other
/// fields the serializer emits.
struct PostHogNestedUser: Decodable, Sendable, Hashable {
    let firstName: String?
    let lastName: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
    }

    /// Name if there is one, e-mail if there isn't, nothing rather than a
    /// placeholder that looks like a real person.
    var displayName: String? {
        let name = [firstName, lastName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return nil
    }
}

extension KeyedDecodingContainer {
    /// Decodes an embedded user down to its display name.
    ///
    /// Never throws: an unexpected shape under `created_by` must not take a whole
    /// page of rows down with it.
    func decodeUserName(forKey key: Key) -> String? {
        let user = (try? decodeIfPresent(PostHogNestedUser.self, forKey: key)) ?? nil
        return user?.displayName
    }
}

// MARK: - Notebook

/// A PostHog notebook.
///
/// One type covers both payloads. `GET /notebooks/` serialises with
/// `NotebookMinimalSerializer`, whose field list contains neither `content` nor
/// `text_content`; only `GET /notebooks/{short_id}/` carries the body. The body
/// fields are therefore optional by construction — a nil `textContent` on a list
/// row means "not fetched", not "empty notebook".
public struct Notebook: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let shortID: String
    public let title: String
    public let textContent: String?
    /// Whether the payload carried a ProseMirror `content` tree.
    public let hasRichContent: Bool
    public let createdAt: Date?
    public let lastModifiedAt: Date?
    public let authorName: String?
    public let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, content, deleted
        case shortID = "short_id"
        case textContent = "text_content"
        case createdAt = "created_at"
        case lastModifiedAt = "last_modified_at"
        case createdBy = "created_by"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID) ?? id
        title = (try c.decodeIfPresent(String.self, forKey: .title))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled notebook"
        // Whitespace-only text is what a notebook of query and image blocks
        // serialises to; treating it as absent keeps `isRichContentOnly` honest.
        textContent = (try c.decodeIfPresent(String.self, forKey: .textContent))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        hasRichContent = ((try? c.decodeIfPresent(JSONValue.self, forKey: .content)) ?? nil)
            .map { !$0.isNull } ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        lastModifiedAt = try c.decodeIfPresent(String.self, forKey: .lastModifiedAt)
            .flatMap(PostHogDate.parse)
        authorName = c.decodeUserName(forKey: .createdBy)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    /// A notebook whose blocks have no text equivalent — all charts, queries or
    /// images. Distinguished from an empty one so the reader is told which it is.
    public var isRichContentOnly: Bool { hasRichContent && textContent == nil }

    /// One-line excerpt for a row, or nil when no body has been fetched.
    public var snippet: String? {
        guard let textContent else { return nil }
        let collapsed = textContent
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 140
            ? collapsed.prefix(140).trimmingCharacters(in: .whitespaces) + "…"
            : collapsed
    }
}
