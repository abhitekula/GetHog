import Foundation

// The two data-management resources a phone can usefully read: actions (saved
// event definitions) and annotations (dated notes drawn on charts).
//
// These decoders follow PostHog's documented response shape. Everything optional
// is treated as genuinely optional.

// MARK: - Author

/// The trimmed `created_by` object both resources embed.
private struct CreatedBy: Decodable {
    let firstName: String?
    let lastName: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
    }

    /// Prefers a name, falls back to the email, and never renders as the empty
    /// string — PostHog stores `""` for a user who never filled a name in.
    var displayName: String? {
        let parts = [firstName, lastName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return email.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Actions

/// One matcher inside an action. Steps are OR-ed: any step firing fires the
/// action.
public struct ActionStep: Sendable, Decodable, Hashable {
    public let event: String?
    public let selector: String?
    public let tagName: String?
    public let text: String?
    public let textMatching: String?
    public let href: String?
    public let hrefMatching: String?
    public let url: String?
    public let urlMatching: String?

    /// Property filters are a nested, deeply variant schema. The count is all a
    /// list row can usefully show, and decoding the shapes would buy nothing.
    public let propertyCount: Int

    enum CodingKeys: String, CodingKey {
        case event, selector, text, href, url, properties
        case tagName = "tag_name"
        case textMatching = "text_matching"
        case hrefMatching = "href_matching"
        case urlMatching = "url_matching"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            guard let value = try? c.decodeIfPresent(String.self, forKey: key),
                  !value.isEmpty
            else { return nil }
            return value
        }
        event = string(.event)
        selector = string(.selector)
        tagName = string(.tagName)
        text = string(.text)
        textMatching = string(.textMatching)
        href = string(.href)
        hrefMatching = string(.hrefMatching)
        url = string(.url)
        urlMatching = string(.urlMatching)
        propertyCount = ((try? c.decodeIfPresent([JSONValue].self, forKey: .properties)) ?? [])
            .count
    }

    /// One line describing what this step matches.
    public var summary: String {
        var parts: [String] = [event ?? "Any event"]

        if let selector {
            parts.append("matches \(selector)")
        } else if let tagName {
            parts.append("matches <\(tagName)>")
        }
        if let text {
            parts.append(textMatching == "regex" ? "text matches /\(text)/" : "text is “\(text)”")
        }
        if let href {
            parts.append(hrefMatching == "regex" ? "links matching /\(href)/" : "links to \(href)")
        }
        if let url {
            // `url_matching` defaults to `contains` on PostHog's side, so an
            // absent value is not "exact" and must not be described as such.
            switch urlMatching {
            case "regex": parts.append("URL matches /\(url)/")
            case "exact": parts.append("URL is \(url)")
            default: parts.append("URL contains \(url)")
            }
        }
        if propertyCount > 0 {
            parts.append("\(propertyCount) property filter\(propertyCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

/// A saved event definition: several matchers that count as one event.
public struct PostHogAction: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let steps: [ActionStep]
    public let tags: [String]
    public let isCalculating: Bool
    public let lastCalculatedAt: Date?
    public let createdAt: Date?
    public let pinnedAt: Date?
    public let isDeleted: Bool
    public let createdByName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, steps, tags, deleted
        case isCalculating = "is_calculating"
        case lastCalculatedAt = "last_calculated_at"
        case createdAt = "created_at"
        case createdBy = "created_by"
        case pinnedAt = "pinned_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        // Nullable in the schema even though the web UI insists on one.
        name = try c.decodeIfPresent(String.self, forKey: .name).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Untitled action"
        description = try c.decodeIfPresent(String.self, forKey: .description).flatMap {
            $0.isEmpty ? nil : $0
        }
        steps = (try? c.decodeIfPresent([ActionStep].self, forKey: .steps)) ?? []
        // Free-form: PostHog accepts any JSON in `tags`, so anything that isn't
        // a string is dropped rather than failing the row.
        tags = ((try? c.decodeIfPresent([JSONValue].self, forKey: .tags)) ?? [])
            .compactMap(\.stringValue)
        isCalculating = try c.decodeIfPresent(Bool.self, forKey: .isCalculating) ?? false
        lastCalculatedAt = try c.decodeIfPresent(String.self, forKey: .lastCalculatedAt)
            .flatMap(PostHogDate.parse)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        pinnedAt = try c.decodeIfPresent(String.self, forKey: .pinnedAt).flatMap(PostHogDate.parse)
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        createdByName = (try? c.decodeIfPresent(CreatedBy.self, forKey: .createdBy))?.displayName
    }

    public var isPinned: Bool { pinnedAt != nil }

    /// What the steps add up to, said in terms of the consequence.
    public var stepSummary: String {
        switch steps.count {
        case 0: "No steps — this action never matches"
        case 1: "1 step"
        default: "\(steps.count) steps, matched if any one fires"
        }
    }

    /// Distinct events this action can fire on, for a compact row subtitle.
    public var matchedEvents: [String] {
        var seen = Set<String>()
        return steps.compactMap { step in
            guard let event = step.event, seen.insert(event).inserted else { return nil }
            return event
        }
    }
}

// MARK: - Annotations

/// Who — or what — created an annotation.
public enum AnnotationCreationType: String, Sendable, Hashable {
    case user = "USR"
    case gitIntegration = "GIT"
    case other

    /// PostHog's codes are three opaque letters. Collapsing them loses the
    /// difference between a note a colleague wrote and a marker a deploy hook
    /// stamped, which is exactly what a reader is trying to tell apart.
    public init(raw: String?) {
        self = raw.flatMap { AnnotationCreationType(rawValue: $0) } ?? .other
    }

    public var title: String {
        switch self {
        case .user: "Added by a person"
        case .gitIntegration: "From a git integration"
        case .other: "Unknown origin"
        }
    }

    public var shortTitle: String {
        switch self {
        case .user: "Manual"
        case .gitIntegration: "Git"
        case .other: "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .user: "person"
        case .gitIntegration: "arrow.triangle.branch"
        case .other: "questionmark.circle"
        }
    }
}

/// Where an annotation shows up.
public enum AnnotationScope: String, Sendable, Hashable {
    /// PostHog's wire value is `dashboard_item`, which means an **insight** —
    /// not "an item on a dashboard". Passing the raw string to the UI mislabels
    /// every insight-scoped note.
    case insight = "dashboard_item"
    case dashboard
    case project
    case organization
    /// Legacy. This used to carry a comment saying PostHog rejects it on write;
    /// the schema says otherwise, so the comment is gone rather than left
    /// asserting something nothing here has established. `AnnotationScopeEnum`
    /// in PostHog's OpenAPI document (fetched 2026-07-30) is exactly
    /// `["dashboard_item", "dashboard", "project", "organization",
    /// "recording"]`, and that same schema is the `POST` request body — so as
    /// far as the document is concerned it is writable. It is simply not
    /// something a person writes from a phone, so `AnnotationTarget` does not
    /// offer it. Old rows still decode through here.
    case recording
    /// Anything PostHog adds later. Decoding an unknown scope as `.other` is
    /// what stops one new value from throwing away the whole page.
    case other

    public init(raw: String?) {
        self = raw.flatMap { AnnotationScope(rawValue: $0) } ?? .other
    }

    public var title: String {
        switch self {
        case .insight: "Insight"
        case .dashboard: "Dashboard"
        case .project: "Project"
        case .organization: "Organization"
        case .recording: "Recording"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .insight: "chart.xyaxis.line"
        case .dashboard: "square.grid.2x2"
        case .project: "folder"
        case .organization: "building.2"
        case .recording: "play.rectangle"
        case .other: "questionmark.circle"
        }
    }
}

/// A dated note drawn on charts — a release, an incident, a campaign start.
public struct Annotation: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let content: String?
    public let dateMarker: Date?
    public let creationType: AnnotationCreationType
    public let scope: AnnotationScope
    public let emoji: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let createdByName: String?
    public let insightShortID: String?
    public let insightName: String?
    public let dashboardName: String?
    public let isDeleted: Bool
    public let isHidden: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, scope, emoji, deleted
        case dateMarker = "date_marker"
        case creationType = "creation_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
        case insightShortID = "insight_short_id"
        case insightName = "insight_name"
        case insightDerivedName = "insight_derived_name"
        case dashboardName = "dashboard_name"
        case hiddenInUserInterface = "hidden_in_user_interface"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        content = try c.decodeIfPresent(String.self, forKey: .content).flatMap {
            $0.isEmpty ? nil : $0
        }
        dateMarker = try c.decodeIfPresent(String.self, forKey: .dateMarker)
            .flatMap(PostHogDate.parse)
        creationType = AnnotationCreationType(
            raw: try c.decodeIfPresent(String.self, forKey: .creationType)
        )
        scope = AnnotationScope(raw: try c.decodeIfPresent(String.self, forKey: .scope))
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji).flatMap {
            $0.isEmpty ? nil : $0
        }
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(PostHogDate.parse)
        createdByName = (try? c.decodeIfPresent(CreatedBy.self, forKey: .createdBy))?.displayName
        insightShortID = try c.decodeIfPresent(String.self, forKey: .insightShortID)
        // An unsaved insight has no name of its own, only PostHog's derived one.
        insightName = try c.decodeIfPresent(String.self, forKey: .insightName)
            ?? c.decodeIfPresent(String.self, forKey: .insightDerivedName)
        dashboardName = try c.decodeIfPresent(String.self, forKey: .dashboardName)
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        // Null means "shown"; only an explicit true hides it.
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .hiddenInUserInterface) ?? false
    }

    /// Builds a row the API has not returned yet.
    ///
    /// Exists for exactly one caller: `AnnotationComposer` needs a row to put on
    /// screen the instant the user confirms, before the `POST` has been answered.
    /// The alternative — a second "pending annotation" type the list also knows
    /// how to draw — would mean two code paths rendering the same thing, and the
    /// pending one would be the path nobody ever looks at.
    ///
    /// `id` is the caller's problem and is deliberately not defaulted: PostHog
    /// assigns the real one, and the placeholder has to be something that cannot
    /// collide with it. `AnnotationComposer` uses a negative id for that reason —
    /// PostHog's are positive, so a rollback can find its own row and no real
    /// annotation can ever be mistaken for a pending one.
    public init(
        id: Int,
        content: String?,
        dateMarker: Date?,
        creationType: AnnotationCreationType = .user,
        scope: AnnotationScope,
        emoji: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        createdByName: String? = nil,
        insightShortID: String? = nil,
        insightName: String? = nil,
        dashboardName: String? = nil,
        isDeleted: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.content = content
        self.dateMarker = dateMarker
        self.creationType = creationType
        self.scope = scope
        self.emoji = emoji
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdByName = createdByName
        self.insightShortID = insightShortID
        self.insightName = insightName
        self.dashboardName = dashboardName
        self.isDeleted = isDeleted
        self.isHidden = isHidden
    }

    /// The date the annotation claims to mark, falling back to when it was
    /// written. Never fabricated — an annotation with neither stays undated.
    public var effectiveDate: Date? { dateMarker ?? createdAt }

    public var displayContent: String { content ?? "(no text)" }

    /// What this annotation is attached to, when it is attached to anything.
    public var attachment: String? {
        switch scope {
        case .insight: insightName.map { "On insight \($0)" } ?? "On an insight"
        case .dashboard: dashboardName.map { "On dashboard \($0)" } ?? "On a dashboard"
        default: nil
        }
    }

    /// Annotations bucketed by the day they mark, newest day first and newest
    /// within a day first.
    ///
    /// Undated rows land in a trailing `day == nil` group rather than being
    /// dropped: a note that failed to record its date is still a note.
    public static func groupedByDay(
        _ annotations: [Annotation],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [AnnotationDay] {
        let buckets = Dictionary(grouping: annotations) { annotation in
            annotation.effectiveDate.map { calendar.startOfDay(for: $0) }
        }

        return buckets
            .map { day, items in
                AnnotationDay(
                    day: day,
                    annotations: items.sorted {
                        ($0.effectiveDate ?? .distantPast, $0.id)
                            > ($1.effectiveDate ?? .distantPast, $1.id)
                    }
                )
            }
            .sorted { ($0.day ?? .distantPast) > ($1.day ?? .distantPast) }
    }
}

/// One day's worth of annotations. `day` is nil for rows the API gave no date.
public struct AnnotationDay: Sendable, Hashable, Identifiable {
    public let day: Date?
    public let annotations: [Annotation]

    public var id: Date? { day }

    public init(day: Date?, annotations: [Annotation]) {
        self.day = day
        self.annotations = annotations
    }
}
