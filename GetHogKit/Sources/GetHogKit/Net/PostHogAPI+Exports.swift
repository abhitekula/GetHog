import Foundation

/// Rendered session-recording videos.
///
/// Despite the resource name, this is not the chart-export API: it lists video
/// renders queued from the replay player. See `RecordingExport`.
///
/// Read-only here. Queuing a render is a write this app does not offer.
public extension PostHogAPI {

    /// The render library. A plain listing that computes nothing, so it bills
    /// against `.crud` rather than the shared analytics budget.
    static func exports(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/exports/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// The video itself.
    ///
    /// This answers **302**, not 200: the body lives in object storage and
    /// PostHog redirects to a presigned URL carrying
    /// `response-content-type=video/mp4`. Two consequences:
    ///
    /// 1. `URLSession` follows the redirect for you, so `PostHogClient.data(for:)`
    ///    returns the mp4 bytes — buffering an entire video in memory. For
    ///    anything but a thumbnail, prefer handing this to a download task.
    /// 2. The presigned URL authenticates itself. A PostHog `Authorization`
    ///    header replayed onto the storage host is at best ignored and at worst
    ///    rejected as a second credential, so a redirect-following client must
    ///    drop it.
    ///
    /// Only worth calling when `RecordingExport.state(asOf:)` is `.ready` —
    /// an expired export's link is dead, and a pending one has no file at all.
    static func exportContent(projectID: Int, exportID: Int) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/exports/\(exportID)/content/",
            category: .crud
        )
    }
}
