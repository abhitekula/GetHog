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

        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init) ?? 60
            // Back the whole category off, not just this call — the budget is
            // organisation-wide and shared with the user's other integrations.
            await governor.penalize(endpoint.category, retryAfter: retryAfter)
            throw PostHogError.rateLimited(retryAfter: retryAfter)

        default:
            let envelope = try? decoder.decode(PostHogErrorEnvelope.self, from: data)
            throw PostHogError.http(status: response.statusCode, detail: envelope?.detail)
        }
    }

    public func usage() async -> [RateLimitGovernor.Category: Double] {
        await governor.usage()
    }
}
