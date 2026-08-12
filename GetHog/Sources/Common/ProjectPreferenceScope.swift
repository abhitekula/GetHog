import Foundation
import GetHogKit

/// The namespace in which one project's local UI preferences are meaningful.
/// Authentication epochs are write authority, not preference identity.
struct ProjectPreferenceScope: Equatable, Hashable, Sendable {
    let projectID: Int
    let region: PostHogRegion

    var storageKeyComponent: String {
        let host = region.host.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? "invalid-host"
        return "\(host).\(projectID)"
    }
}
