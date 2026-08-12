import Foundation
import GetHogKit

/// The namespace in which one project's local UI preferences are meaningful.
/// Authentication epochs are write authority, not preference identity.
struct ProjectPreferenceScope: Equatable, Hashable, Sendable {
    let projectID: Int
    let region: PostHogRegion

    var storageKeyComponent: String {
        let host = normalizedHost
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? "invalid-host"
        return "\(host).\(projectID)"
    }

    private var normalizedHost: String {
        guard var components = URLComponents(url: region.host, resolvingAgainstBaseURL: false) else {
            return region.host.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path == "/" ? "" : path
        return components.url?.absoluteString ?? region.host.absoluteString
    }
}
