import Foundation
import GetHogKit

/// Turns a render's `/content/` endpoint into a URL `AVPlayer` can stream, without
/// letting the PostHog credential reach the host that ends up serving the video.
///
/// `GET /exports/{id}/content/` answers **302**, not 200: the file lives in object
/// storage and PostHog redirects to a presigned URL carrying
/// `response-content-type=video/mp4`. That redirect is the whole reason this type
/// exists rather than a call to `PostHogClient.data(for:)` — see `RedirectRefusal`.

// MARK: - Result

/// A presigned storage URL, and the moment it stops being accepted.
struct ResolvedRenderURL: Sendable, Equatable {
    let url: URL
    /// Read off the URL's own signature parameters. Nil when the link carries no
    /// expiry in a form this app recognises.
    let expiresAt: Date?

    /// Whether this link is still worth handing to a player.
    ///
    /// Observed links carry `X-Amz-Expires=3600`, so one resolved before a coffee
    /// break is dead by the time playback is resumed — and a dead presigned URL
    /// fails inside `AVPlayer` as an opaque media error, not as an HTTP status
    /// anything here could explain. The margin covers a link that would expire
    /// mid-stream rather than mid-tap.
    ///
    /// An unrecognised expiry counts as unusable: re-resolving costs one
    /// redirect, and guessing wrong costs the user a broken video.
    func isUsable(asOf date: Date, margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return date.addingTimeInterval(margin) < expiresAt
    }
}

// MARK: - Failures

/// Why a render could not be turned into a playable URL.
///
/// Separated by remedy rather than by status, in the same spirit as
/// `ResourceAccessState`: a retry helps for exactly one of these.
enum RenderURLError: Error, Equatable, LocalizedError {
    /// PostHog answered with the file itself instead of a redirect.
    ///
    /// Not an outage — a self-hosted instance serving object storage inline
    /// would look like this. There is nothing to hand a player: streaming it
    /// would mean attaching the personal API key to every range request
    /// `AVPlayer` makes, which is the one thing this file exists to prevent.
    case servedDirectly(status: Int)
    case noLocation
    case malformedLocation(String)
    case http(status: Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .servedDirectly:
            "This PostHog instance serves the video directly instead of "
                + "redirecting to storage, so GetHog can't stream it without "
                + "attaching your API key to the video request."
        case .noLocation:
            "PostHog redirected without saying where to."
        case .malformedLocation(let raw):
            "PostHog redirected to something that isn't a URL: \(raw)"
        case .http(let status):
            status == 404
                ? "PostHog no longer has a file for this render."
                : "PostHog returned an error (\(status)) for this render."
        case .transport(let message):
            "Couldn't reach PostHog: \(message)"
        }
    }
}

// MARK: - Redirect policy

/// Refuses every redirect the session is offered.
///
/// `URLSession` follows a 302 automatically **and replays the original request's
/// headers onto the new one, `Authorization` included**. Here the new host is
/// third-party object storage, and the header is a PostHog personal API key — a
/// bearer credential for the user's entire account, in an organisation whose rate
/// limits and integrations it also unlocks. Handing it to a host that never asked
/// for it, and that authenticates itself with the signature already in the query
/// string, is a credential leak with no upside.
///
/// Stopping at the 302 and reading `Location` is what keeps the key on PostHog's
/// host. It also means the mp4 is never downloaded here — the redirect body is
/// empty, and `AVPlayer` fetches the file itself with range requests instead of
/// this app buffering 24 MB of video into memory to hand it over.
///
/// This must not be "simplified" into a plain `URLSession.shared.data(for:)`.
/// That version is shorter, it works, and it leaks the credential.
/// Internal rather than private so the test target can call it directly and
/// assert that it refuses — the guarantee is worth pinning, not just writing down.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: - Resolver

struct RenderURLResolver: Sendable {
    private let session: URLSession

    /// The app's resolving session.
    ///
    /// Its delegate is the redirect policy, so *nothing* sent through it can
    /// follow a redirect by accident. Ephemeral because a presigned URL is a
    /// credential in its own right and has no business in a disk cache.
    static let sharedSession: URLSession = URLSession(
        configuration: .ephemeral,
        delegate: RedirectRefusal(),
        delegateQueue: nil
    )

    init(session: URLSession = RenderURLResolver.sharedSession) {
        self.session = session
    }

    /// One request, issued only when someone actually presses play.
    ///
    /// The rate-limit budget is organisation-wide, and a presigned link is dead
    /// within the hour, so resolving at list time would spend 56 requests to
    /// produce 56 URLs that expire before anyone watches one.
    ///
    /// This is the one request in the app that does not pass `RateLimitGovernor`,
    /// because it cannot go through `PostHogClient` at all — the governor is not
    /// reachable from outside it, and routing this through `data(for:)` would
    /// follow the redirect, which is the thing being prevented. It buys a
    /// redirect rather than a query, and only ever one per deliberate press.
    func resolve(
        credential: StoredCredential,
        projectID: Int,
        exportID: Int
    ) async throws -> ResolvedRenderURL {
        // Built from the endpoint catalog rather than a string here, so the path
        // stays in the one place every other PostHog URL is decided.
        let endpoint = PostHogAPI.exportContent(projectID: projectID, exportID: exportID)
        let url = credential.region.host.appending(path: endpoint.path)

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        // Bearer for PostHog's host and no other. `RedirectRefusal` is what
        // guarantees "no other".
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")

        let response: HTTPURLResponse
        do {
            let (_, urlResponse) = try await session.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse else {
                throw RenderURLError.transport("Non-HTTP response")
            }
            response = http
        } catch let error as RenderURLError {
            throw error
        } catch {
            throw RenderURLError.transport(error.localizedDescription)
        }

        return try Self.resolved(from: response, requestedAt: url)
    }

    // MARK: Pure parts

    /// The half of `resolve` that has no network in it, so it can be tested
    /// against a response rather than against a server.
    static func resolved(from response: HTTPURLResponse, requestedAt: URL) throws -> ResolvedRenderURL {
        switch response.statusCode {
        case 300..<400:
            guard let location = response.value(forHTTPHeaderField: "Location"), !location.isEmpty
            else { throw RenderURLError.noLocation }
            // Relative-resolved against the request: the spec permits a relative
            // `Location`, and a self-hosted instance proxying its own storage is
            // exactly where one would show up.
            guard let resolved = URL(string: location, relativeTo: response.url ?? requestedAt)?
                .absoluteURL
            else { throw RenderURLError.malformedLocation(location) }
            return ResolvedRenderURL(url: resolved, expiresAt: presignedExpiry(of: resolved))

        case 200..<300:
            throw RenderURLError.servedDirectly(status: response.statusCode)

        default:
            throw RenderURLError.http(status: response.statusCode)
        }
    }

    /// When a presigned link's signature stops being accepted.
    ///
    /// Read from the URL rather than assumed, because the window is the storage
    /// provider's choice and not ours: PostHog Cloud signs for an hour, and a
    /// self-hosted MinIO or GCS bucket may sign for anything at all. Both the S3
    /// and Google spellings are accepted for that reason.
    static func presignedExpiry(of url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        for prefix in ["X-Amz", "X-Goog"] {
            guard let seconds = value("\(prefix)-Expires").flatMap(TimeInterval.init),
                  let signedAt = value("\(prefix)-Date").flatMap(signatureDate)
            else { continue }
            return signedAt.addingTimeInterval(seconds)
        }
        return nil
    }

    /// SigV4 stamps `20260730T043618Z` — ISO 8601 basic format, which
    /// `ISO8601DateFormatter` does not read.
    private static func signatureDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: raw)
    }
}
