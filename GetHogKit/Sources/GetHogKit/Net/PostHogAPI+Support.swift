import Foundation

/// PostHog Support — the customer conversation inbox.
///
/// **The prefix trap.** `/api/projects/{id}/conversations/` is *Max*, the AI
/// assistant's threads (see `PostHogAPI.conversations`). Support's tickets live
/// one segment deeper, at `/conversations/tickets/`. Two products, one namespace,
/// and the shorter path wins any prefix match — so a matcher, a cache key or a
/// demo route that says `/conversations/` and means Support will silently serve
/// Max's data instead. Every path here names `/conversations/tickets/` in full
/// for that reason.
///
/// All read-only, and more deliberately so than most of this app. The sub-resources
/// this file does *not* expose — `/reply/`, `/compose/`, `/ai_feedback/`,
/// `bulk_update_status/`, `bulk_update_tags/` — are the ones that would speak to a
/// customer on the user's behalf.
///
/// Scope: `ticket:read`, per the endpoint's own `security` block.
public extension PostHogAPI {

    /// The ticket inbox.
    ///
    /// `order_by=-updated_at` is the documented default, sent explicitly so the
    /// page this client re-ranks cannot change shape under it if that default
    /// ever moves. It is only ever a *pre-filter*: the ranking the screen shows
    /// is `SupportTicket.triaged`, computed on the client because `order_by`
    /// accepts just four fields — `created_at`, `sla_due_at`, `ticket_number`,
    /// `updated_at` — and neither `priority` nor `unread_team_count` is among
    /// them. There is no server-side ordering that puts the most urgent ticket
    /// first, so the honest arrangement is: ask for the most recently active
    /// page, rank it here, and say on screen that the ranking covers the page.
    ///
    /// One request per screen. The endpoint also offers a `/unread_count/`
    /// sub-resource returning a team-wide total; it is not called, because a
    /// second request on this screen buys one integer against a rate-limit
    /// budget shared with the whole organisation, and `unread_team_count` is
    /// already on every row.
    static func supportTickets(projectID: Int, limit: Int = 50) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/conversations/tickets/",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "order_by", value: "-updated_at"),
            ],
            // A plain listing that computes nothing. The `/query/` budget is the
            // scarcest of the three and belongs to the screens that need it.
            category: .crud
        )
    }

    /// One ticket's thread, "ordered chronologically (paginated)".
    ///
    /// The path accepts "the ticket's UUID or its numeric ticket number"; the
    /// UUID is used, because it is the identifier the list row already carries
    /// and the only one guaranteed present.
    static func supportTicketMessages(
        projectID: Int,
        ticketID: String,
        limit: Int = 100
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/conversations/tickets/\(ticketID)/messages/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}
