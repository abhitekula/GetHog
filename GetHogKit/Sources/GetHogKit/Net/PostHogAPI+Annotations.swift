import Foundation

public extension PostHogAPI {

    // MARK: - Annotations (write)
    //
    // The one PostHog write that is genuinely more natural on a phone than at a
    // desk: you are rarely at your desk at the moment the thing worth annotating
    // happens. Everything else the app writes — a flag flip, an issue status — is
    // a decision you could equally have made sitting down.
    //
    // Shape, dialog and rollback all follow `setFlagActive`, the app's oldest
    // write; see `AnnotationComposer` for the confirmation and the optimistic
    // apply. Nothing in this file asks the user anything.
    //
    // **Never executed.** The paths and the body below were read out of
    // PostHog's own OpenAPI document (`GET https://us.posthog.com/api/schema/
    // ?format=json`, fetched 2026-07-30) and checked against the live *read*
    // endpoint's response. No POST in this family has been sent from this
    // machine: the only key available is read-only against a real project, and
    // confirming a create by sending one is not a test — it is a note written
    // onto somebody's charts that nothing in this app can then delete.

    /// Creates a dated note that PostHog draws on charts.
    ///
    /// `POST /api/projects/:id/annotations/`. From the document's `Annotation`
    /// schema, the writable properties are `content`, `date_marker`,
    /// `creation_type`, `dashboard_item`, `dashboard_id`, `deleted`, `scope`,
    /// `emoji` and `hidden_in_user_interface`; everything else — `id`,
    /// `created_by`, `created_at`, `updated_at`, `insight_name`,
    /// `insight_short_id`, `insight_derived_name`, `dashboard_name` — is
    /// `readOnly: true` and is the server's to fill in. Only the five fields a
    /// person actually chose are sent, so nothing here can plant a default that
    /// PostHog would otherwise have decided for itself.
    ///
    /// **The scope vocabulary is a trap and this is where it bites hardest.**
    /// `AnnotationScopeEnum` is `["dashboard_item", "dashboard", "project",
    /// "organization", "recording"]`, and the document's own description spells
    /// the first one out: `* dashboard_item - insight`. It means an **insight**,
    /// not "an item on a dashboard". Worse, the *field* that carries the
    /// insight's id is also called `dashboard_item`, while the dashboard's id
    /// goes in `dashboard_id` — so an insight-scoped annotation sends
    /// `{"scope": "dashboard_item", "dashboard_item": [REMOVED PRIVATE DATA]}` and a
    /// dashboard-scoped one sends `{"scope": "dashboard", "dashboard_id": …}`.
    /// Reading either name as English gets it backwards.
    ///
    /// `creation_type` is sent as `USR`. `CreationTypeEnum` is `["USR", "GIT"]`
    /// — user or GitHub — and a note typed on a phone is the former. Sending it
    /// explicitly rather than leaning on the server's default is what keeps a
    /// hand-written note from ever being drawn with the deploy-marker glyph the
    /// annotations list uses for `GIT`.
    ///
    /// `date_marker` is the whole point of the feature — it is the instant the
    /// annotation *marks*, which is not the instant it was written. "We deployed
    /// at 14:05" typed at 14:40 must say 14:05, so the caller passes the marker
    /// and it is never defaulted to `now` here.
    ///
    /// Needs `annotation:write` on the personal API key. A read-scoped key
    /// passes every preflight probe the app runs and fails only here.
    ///
    /// - Parameters:
    ///   - target: what the note is attached to. `.insight` and `.dashboard`
    ///     carry the id that scope requires; the others carry nothing.
    static func createAnnotation(
        projectID: Int,
        content: String,
        dateMarker: Date,
        target: AnnotationTarget = .project
    ) -> Endpoint {
        var payload: [String: Any] = [
            "content": content,
            "date_marker": PostHogDate.iso8601(dateMarker),
            "scope": target.scope.rawValue,
            "creation_type": AnnotationCreationType.user.rawValue,
        ]
        switch target {
        // Not a typo, and not the dashboard: PostHog spells the *insight* id
        // `dashboard_item`, the same word it uses for the insight *scope*.
        case .insight(let insightID): payload["dashboard_item"] = insightID
        case .dashboard(let dashboardID): payload["dashboard_id"] = dashboardID
        case .project, .organization: break
        }
        let body = try? JSONSerialization.data(withJSONObject: payload)
        return Endpoint(
            path: "/api/projects/\(projectID)/annotations/",
            method: "POST",
            body: body,
            category: .crud
        )
    }
}

/// What a new annotation is pinned to.
///
/// A scope and the id that scope needs, in one value, because they are only ever
/// correct together: `scope: "dashboard_item"` without a `dashboard_item` id is
/// an insight annotation attached to no insight. Modelling them as two
/// independent parameters would make that state expressible.
///
/// `recording` is in `AnnotationScopeEnum` and is deliberately absent here.
/// PostHog treats it as legacy — old rows still carry it, which is why
/// `AnnotationScope` decodes it — and there is no recording-scoped note a person
/// would write from this app.
public enum AnnotationTarget: Sendable, Hashable {
    /// Visible on every chart in the project. The default, and what a deploy or
    /// an incident actually means.
    case project
    /// Visible across every project in the organization.
    case organization
    /// Pinned to one insight. PostHog calls this scope `dashboard_item`.
    case insight(id: Int)
    /// Pinned to one dashboard.
    case dashboard(id: Int)

    public var scope: AnnotationScope {
        switch self {
        case .project: .project
        case .organization: .organization
        case .insight: .insight
        case .dashboard: .dashboard
        }
    }
}
