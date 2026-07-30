import Foundation

/// `GET /api/users/@me/` — identity, the current project, and every project the
/// key can reach. One call is enough to bootstrap the whole app.
public struct MeResponse: Sendable, Decodable {
    /// The numeric user id, which is what PostHog means by a *user* assignee.
    ///
    /// Distinct from `distinctID` (an analytics identifier) and from `uuid`.
    /// Error-tracking assignment sends `{"id": [REMOVED PRIVATE DATA], "type": "user"}`, and this
    /// is the only place the app already knows that number — so "assign to me"
    /// costs no extra request.
    public let userID: Int?
    public let email: String?
    public let firstName: String?
    public let lastName: String?
    public let distinctID: String?
    public let currentProject: Project?
    public let organization: Organization?
    public let organizations: [OrganizationSummary]

    enum CodingKeys: String, CodingKey {
        case id, email, organization, organizations
        case firstName = "first_name"
        case lastName = "last_name"
        case distinctID = "distinct_id"
        case team
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try? c.decodeIfPresent(Int.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        distinctID = try c.decodeIfPresent(String.self, forKey: .distinctID)
        currentProject = try? c.decodeIfPresent(Project.self, forKey: .team)
        organization = try? c.decodeIfPresent(Organization.self, forKey: .organization)
        organizations = (try? c.decodeIfPresent([OrganizationSummary].self, forKey: .organizations)) ?? []
    }

    public static func decode(from data: Data) throws -> MeResponse {
        try JSONDecoder().decode(MeResponse.self, from: data)
    }

    /// Every project reachable with this credential.
    public var projects: [Project] { organization?.teams ?? [] }

    public var displayName: String {
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (email ?? "PostHog user") : name
    }
}

public struct Project: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let apiToken: String?
    public let timezone: String?

    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case apiToken = "api_token"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Project \(id)"
        apiToken = try c.decodeIfPresent(String.self, forKey: .apiToken)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
    }
}

public struct Organization: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let teams: [Project]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Organization"
        teams = (try? c.decodeIfPresent([Project].self, forKey: .teams)) ?? []
    }

    enum CodingKeys: String, CodingKey { case id, name, teams }
}

public struct OrganizationSummary: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Organization"
    }

    enum CodingKeys: String, CodingKey { case id, name }
}
