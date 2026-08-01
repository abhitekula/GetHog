import Foundation

public extension PostHogAPI {

    // MARK: - Organizations

    /// Every project inside one organization.
    ///
    /// `GET /api/organizations/:organization_id/projects/`. Needed because
    /// `/api/users/@me/` hydrates the teams of **one** organization only: its
    /// `organization` object carries a full `teams` array, while its documented
    /// `organizations` array carries summaries without projects. So a user in
    /// two organizations needs this endpoint to reach the second one's projects.
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
    /// bug to route around.** Organization endpoints reject project-scoped keys,
    /// so the failure is a property of the key rather than a transient request
    /// failure, and no amount of retrying
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
