import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PostHogError.transport("Non-HTTP response")
            }
            return (data, http)
        } catch let error as PostHogError {
            throw error
        } catch {
            throw PostHogError.transport(error.localizedDescription)
        }
    }
}

public struct Endpoint: Sendable {
    public var path: String
    public var method: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var category: RateLimitGovernor.Category

    public init(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        category: RateLimitGovernor.Category
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.body = body
        self.category = category
    }
}

public actor PostHogClient {
    private let auth: any AuthProvider
    private let transport: any HTTPTransport
    private let governor: RateLimitGovernor
    private let decoder = JSONDecoder()

    public init(
        auth: any AuthProvider,
        transport: any HTTPTransport = URLSessionTransport(),
        governor: RateLimitGovernor = RateLimitGovernor()
    ) {
        self.auth = auth
        self.transport = transport
        self.governor = governor
    }

    /// Immutable configuration, so it is safe to read without actor hops —
    /// callers need the host to build web-console links from the main actor.
    public nonisolated var region: PostHogRegion { auth.region }
    public nonisolated var host: URL { auth.region.host }

    /// Performs a request and decodes the response.
    public func send<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let data = try await data(for: endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PostHogError.decoding(String(describing: error))
        }
    }

    /// Performs a request and returns the raw body — used for `application/jsonl`
    /// replay snapshots, which are not JSON documents.
    public func data(for endpoint: Endpoint) async throws -> Data {
        try await governor.waitForSlot(endpoint.category)

        var components = URLComponents(
            url: auth.region.host.appending(path: endpoint.path),
            resolvingAgainstBaseURL: false
        )
        if !endpoint.query.isEmpty {
            components?.queryItems = endpoint.query
        }
        guard let url = components?.url else {
            throw PostHogError.transport("Could not build URL for \(endpoint.path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        request.setValue(try await auth.authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The snapshot endpoint honours gzip, which roughly halves replay payloads.
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if endpoint.body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await transport.send(request)

        switch response.statusCode {
        case 200..<300:
            return data

        case 401:
            try await auth.handleUnauthorized()
            throw PostHogError.unauthorized

        case 400:
            // PostHog reports missing per-resource access as a 400 rather than a
            // 403, so treating every 400 as a malformed request would show a
            // permissions problem as a client bug.
            let envelope = try? decoder.decode(PostHogErrorEnvelope.self, from: data)
            if let resource = envelope?.deniedResource {
                throw PostHogError.accessDenied(resource: resource)
            }
            throw PostHogError.http(status: 400, detail: envelope?.detail)

        case 402:
            let envelope = try? decoder.decode(PostHogErrorEnvelope.self, from: data)
            throw PostHogError.paymentRequired(envelope?.detail)

        case 403:
            let envelope = try? decoder.decode(PostHogErrorEnvelope.self, from: data)
            throw PostHogError.forbidden(
                missingScope: envelope?.missingScope,
                detail: envelope?.detail
            )

        // The one status in this switch that can mean the request *worked*.
        //
        // Under an organisation approval policy a flag write — and the two
        // experiment actions that call `set_flag_active` on the linked flag —
        // answer 409 with `{"code": "approval_required", "change_request_id": …,
        // "required_approvers": […]}` and leave the object unchanged. Before this
        // case existed the whole family fell through to `default` and reached the
        // screen as `PostHogError.http(status: 409, …)`, which every optimistic
        // caller reports as "couldn't do that" — a description that is wrong
        // about the one thing that matters, because a change request exists and
        // approvers were emailed.
        //
        // Keyed on the body's `code`, not on the status: 409 is also what the
        // flag serializer's version check raises, and that one really is a
        // conflict. An unrecognised 409 becomes `.editConflict` rather than being
        // dressed up as an approval.
        //
        // **Source-derived, never observed by deterministic tests.** Synthetic
        // envelopes cover the decoder without retaining a tenant response.
        // `ApprovalOutcome` records which parts of the body's shape are guesses.
        case 409:
            if let outcome = (try? decoder.decode(ApprovalEnvelope.self, from: data))?.outcome {
                throw PostHogError.approvalRequired(outcome)
            }
            let envelope = try? decoder.decode(PostHogErrorEnvelope.self, from: data)
            throw PostHogError.editConflict(detail: envelope?.detail)

        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init) ?? 60
            // Back the whole category off, not just this call — the budget is
            // organisation-wide and shared with the user's other integrations.
            await governor.penalize(endpoint.category, retryAfter: retryAfter)
            throw PostHogError.rateLimited(retryAfter: retryAfter)

        default:
            let envelope = try? decoder.decode(PostHogErrorEnvelope.self, from: data)
            // Observed as a 504 whose body is advice for someone at a SQL
            // console. Recognised here so it stops being an anonymous 5xx and
            // reaches the screen as a retryable timeout with its own sentence.
            if PostHogError.isQueryTimeout(detail: envelope?.detail) {
                throw PostHogError.queryTimeout(envelope?.detail)
            }
            throw PostHogError.http(status: response.statusCode, detail: envelope?.detail)
        }
    }

    public func usage() async -> [RateLimitGovernor.Category: Double] {
        await governor.usage()
    }
}
