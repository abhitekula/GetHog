import Foundation

@testable import GetHogKit

/// Records outgoing requests and replays scripted responses.
actor StubTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var scripted: [(Data, HTTPURLResponse)]

    init(responses: [(Data, HTTPURLResponse)]) {
        self.scripted = responses
    }

    init(status: Int, body: String = "{}", headers: [String: String] = [:]) {
        let response = HTTPURLResponse(
            url: URL(string: "https://us.posthog.com/")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        self.init(responses: [(Data(body.utf8), response)])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !scripted.isEmpty else {
            throw PostHogError.transport("stub exhausted")
        }
        return scripted.count == 1 ? scripted[0] : scripted.removeFirst()
    }

    var lastRequest: URLRequest? { requests.last }
    var requestCount: Int { requests.count }
}
