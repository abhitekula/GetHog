import Foundation

/// What the token endpoint answered. Tolerant by design: PostHog may add
/// fields (it already returns `scoped_teams`, `scoped_organizations`, and
/// region info beside the RFC set), and a new field must never break sign-in.
public struct OAuthTokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    /// Seconds the access token lives. Absent in theory; the provider treats
    /// a missing value as one hour rather than as immortal. Observed at
    /// 604800 (seven days) on the region-agnostic endpoint.
    public let expiresIn: TimeInterval?
    public let scope: String?
    public let scopedTeams: [Int]?
    public let scopedOrganizations: [String]?
    /// Where this grant authenticates. Observed live on the token response
    /// (`"us"` / `"https://us.posthog.com"`); preferred over probing because
    /// it costs no request. Either may be absent on older responses, in which
    /// case the caller falls back to probing each Cloud region.
    public let posthogRegion: String?
    public let posthogBaseURL: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case scopedTeams = "scoped_teams"
        case scopedOrganizations = "scoped_organizations"
        case posthogRegion = "posthog_region"
        case posthogBaseURL = "posthog_base_url"
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: TimeInterval? = nil,
        scope: String? = nil,
        scopedTeams: [Int]? = nil,
        scopedOrganizations: [String]? = nil,
        posthogRegion: String? = nil,
        posthogBaseURL: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.scopedTeams = scopedTeams
        self.scopedOrganizations = scopedOrganizations
        self.posthogRegion = posthogRegion
        self.posthogBaseURL = posthogBaseURL
    }

    /// The Cloud region this grant belongs to, when the response says so.
    /// Region code first (`"us"`, `"eu"`, case-insensitive), then the base
    /// URL's host — both observed live, either alone sufficient.
    public var resolvedRegion: PostHogRegion? {
        switch posthogRegion?.lowercased() {
        case "us": return .usCloud
        case "eu": return .euCloud
        default: break
        }
        guard let host = posthogBaseURL.flatMap(URL.init(string:))?.host?.lowercased() else {
            return nil
        }
        if host.contains("eu.posthog.com") { return .euCloud }
        if host.contains("us.posthog.com") { return .usCloud }
        return nil
    }
}

/// The OAuth error envelope: `{"error": "invalid_grant", …}`, not PostHog's
/// usual `{type, code, detail}` shape, so it gets its own decoder rather than
/// sharing `PostHogErrorEnvelope`.
struct OAuthErrorEnvelope: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Speaks `application/x-www-form-urlencoded` to the token and revocation
/// endpoints. Carries no session: the provider owns storage, this owns the
/// wire shape, so tests can pin one without the other.
public struct OAuthTokenClient: Sendable {
    private let directory: OAuthDirectory
    private let transport: any HTTPTransport

    public init(directory: OAuthDirectory, transport: any HTTPTransport = URLSessionTransport()) {
        self.directory = directory
        self.transport = transport
    }

    /// Trades the browser's authorization code for the first token pair.
    public func exchange(
        code: String,
        verifier: String
    ) async throws -> OAuthTokenResponse {
        try await postForm([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", directory.redirectURI),
            ("client_id", directory.clientID),
            ("code_verifier", verifier),
        ])
    }

    /// Trades a refresh token for the next pair. A rotated refresh token
    /// replaces the old one; an unrotated response keeps it.
    public func refresh(_ refreshToken: String) async throws -> OAuthTokenResponse {
        try await postForm([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    /// Best-effort by contract: callers (sign-out) proceed with local teardown
    /// whether or not the server acknowledged the revocation.
    public func revoke(_ token: String) async throws {
        var request = URLRequest(url: directory.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formBody([("token", token)])
        let (data, response) = try await transport.send(request)
        guard 200..<300 ~= response.statusCode else {
            throw Self.error(status: response.statusCode, data: data)
        }
    }

    private func postForm(_ fields: [(String, String)]) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: directory.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await transport.send(request)
        guard 200..<300 ~= response.statusCode else {
            throw Self.error(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw PostHogError.decoding(String(describing: error))
        }
    }

    /// Maps token-endpoint failures onto the app's error language. The one
    /// case that matters is `invalid_grant`: a dead code, a rotated-away
    /// refresh token, a revoked grant — all mean this credential will never
    /// authenticate again, which is exactly `PostHogError.unauthorized`, the
    /// case every session-teardown path already keys on.
    static func error(status: Int, data: Data) -> PostHogError {
        let envelope = try? JSONDecoder().decode(OAuthErrorEnvelope.self, from: data)
        if envelope?.error == "invalid_grant" {
            return .unauthorized
        }
        let detail = envelope?.errorDescription ?? envelope?.error
        return .http(status: status, detail: detail)
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        Data(
            fields.map { name, value in
                "\(formEscape(name))=\(formEscape(value))"
            }
            .joined(separator: "&")
            .utf8
        )
    }

    /// `urlQueryAllowed` is the wrong set for a form body — it leaves `+`,
    /// `&`, and `=` legal, which is exactly what must be escaped. Inverted
    /// instead: escape everything but the RFC 3986 unreserved set.
    static func formEscape(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
