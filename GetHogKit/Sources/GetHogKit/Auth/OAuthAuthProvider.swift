import Foundation

/// Authenticates with a PostHog Cloud OAuth grant.
///
/// The wire format is identical to personal keys (`Authorization: Bearer`),
/// which is why this is a second `AuthProvider` rather than a client rewrite.
/// What differs is lifecycle: access tokens expire, so this provider refreshes
/// proactively before expiry and once more on a 401 before admitting the
/// credential is dead.
///
/// Refresh is single-flight: concurrent requests arriving with an expired
/// token share one token-endpoint call instead of racing rotations against
/// each other. Refreshed pairs are persisted through the same store the app
/// booted from, so widgets, background refresh, and the next foreground
/// launch all see the new access token without another browser round trip.
///
/// What this never does is interactive recovery. A dead grant (revoked,
/// rotated away, `invalid_grant`) throws `PostHogError.unauthorized` — the
/// same case a rejected personal key produces — and the session owner
/// (`AppModel`) performs the teardown and re-authorization. Extensions, which
/// cannot present a browser, surface the resulting stale state instead.
public actor OAuthAuthProvider: AuthProvider {
    public nonisolated let region: PostHogRegion

    private let directory: OAuthDirectory
    private let tokenClient: OAuthTokenClient
    private let store: any CredentialStoring
    private var credential: StoredCredential
    private var refreshTask: Task<StoredCredential, any Error>?

    /// How early a token counts as expired. Covers the round trip: a token
    /// valid for 30 more seconds is not valid for the request about to use it.
    private static let expiryLeeway: TimeInterval = 60

    /// The fallback lifetime when the server omits `expires_in`. Short rather
    /// than immortal: the failure mode of refreshing too eagerly is one extra
    /// token call, while treating an expiring token as immortal 401s the
    /// request it was meant to serve.
    private static let assumedLifetime: TimeInterval = 3600

    public init(
        credential: StoredCredential,
        directory: OAuthDirectory,
        store: any CredentialStoring,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        precondition(credential.isOAuth, "OAuthAuthProvider needs a credential carrying a refresh token")
        self.region = credential.region
        self.credential = credential
        self.directory = directory
        self.store = store
        self.tokenClient = OAuthTokenClient(directory: directory, transport: transport)
    }

    public func authorizationHeader() async throws -> String {
        "Bearer \(try await validCredential().key)"
    }

    public func handleUnauthorized() async throws {
        // The 401 may have beaten the expiry clock (revocation propagates
        // faster than `expires_in` elapses), so force one refresh before
        // declaring the grant dead. A second consecutive 401 reaches the
        // client, which throws `.unauthorized` itself.
        _ = try await refresh(force: true)
    }

    private func validCredential(now: Date = Date()) async throws -> StoredCredential {
        if let expiry = credential.accessTokenExpiry,
           now.addingTimeInterval(Self.expiryLeeway) < expiry {
            return credential
        }
        return try await refresh(force: credential.accessTokenExpiry == nil)
    }

    /// Returns the refreshed credential, sharing one in-flight refresh across
    /// concurrent callers. `force` skips the freshness check; it does not skip
    /// coalescing — two forced callers still share one token call.
    private func refresh(force: Bool) async throws -> StoredCredential {
        // `force` skips the freshness check; it never skips coalescing — a
        // forced caller still joins an in-flight refresh rather than racing
        // a second rotation against it.
        if let task = refreshTask {
            return try await task.value
        }
        let previous = credential
        let task = Task<StoredCredential, any Error> {
            try await self.performRefresh(from: previous)
        }
        refreshTask = task
        do {
            let next = try await task.value
            refreshTask = nil
            return next
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func performRefresh(from previous: StoredCredential) async throws -> StoredCredential {
        guard let refreshToken = previous.refreshToken else {
            throw PostHogError.unauthorized
        }
        let response = try await tokenClient.refresh(refreshToken)
        let next = StoredCredential(
            key: response.accessToken,
            region: previous.region,
            projectID: previous.projectID,
            authSessionID: previous.authSessionID,
            refreshToken: response.refreshToken ?? previous.refreshToken,
            accessTokenExpiry: Date().addingTimeInterval(
                response.expiresIn ?? Self.assumedLifetime
            ),
            grantedScopes: response.scope.map { $0.split(separator: " ").map(String.init) }
                ?? previous.grantedScopes
        )
        // Persist before publishing: a crash between the token call and this
        // write must not strand the store on a rotated-away refresh token
        // while the response that replaced it is lost. A store failure is
        // reported, not swallowed — running on an in-memory-only pair the
        // next launch cannot see is worse than failing this request.
        try store.save(next)
        credential = next
        return next
    }
}
