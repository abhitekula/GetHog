import Foundation

public extension PostHogAPI {

    // MARK: - Organizations

    /// Every project inside one organization.
    ///
    /// `GET /api/organizations/:organization_id/projects/`. Needed because
    /// `/api/users/@me/` hydrates the teams of **one** organization only: its
    /// `organization` object carries a full `teams` array, while its
    /// `organizations` array carries summaries — measured live against
    /// `us.posthog.com`, an entry is exactly
    /// `{id, name, slug, logo_media_id, membership_level,
    /// members_can_use_personal_api_keys, is_active, is_not_active_reason,
    /// is_pending_deletion}` and no projects at all. So a user in two
    /// organizations could reach the projects of one until this existed.
    ///
    /// Returns a `Page<Project>`. The document's item schema is
    /// `ProjectBackwardCompatBasic` — `{access_control, api_token,
    /// completed_snippet_onboarding, has_completed_onboarding_for, id,
    /// ingested_event, is_demo, name, organization, project_id, timezone,
    /// uuid}` — a superset of the four fields `Project` decodes, so the type
    /// the rest of the app already passes around is the type this returns.
    ///
    /// `.crud`, and charged once per organization rather than once per switch:
    /// `AppModel` keeps what it fetched for the session, because the set of
    /// projects in an organization does not change while somebody is looking at
    /// a chart, and the budget is organisation-wide and shared with whatever
    /// else the user has integrated.
    ///
    /// **A project-scoped personal API key cannot call this, and that is not a
    /// bug to route around.** Measured live, all three of
    /// `/api/organizations/`, `/api/organizations/:id/projects/` and
    /// `/api/projects/` answer HTTP **403** with
    ///
    ///     {"type": "authentication_error", "code": "permission_denied",
    ///      "detail": "API keys with scoped projects are only supported on
    ///                 project-based endpoints."}
    ///
    /// while `/api/users/@me/` answers 200 for the same key. So the failure is
    /// a property of the *key*, not of the request, and no amount of retrying
    /// or falling back changes it. `AppModel` says so in those words rather
    /// than showing an organization whose projects it then lists as empty —
    /// this app treats showing the wrong project's numbers as a correctness
    /// bug, and "no projects" about an organization that has several is the
    /// same class of lie.
    static func organizationProjects(organizationID: String, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/organizations/\(organizationID)/projects/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}
