import Foundation

public extension PostHogAPI {

    /// PostHog's dashboard template library.
    ///
    /// Static reference material, including optional artwork, that computes
    /// nothing and therefore belongs to the CRUD budget.
    ///
    /// ## Why there is no `apply`
    ///
    /// Applying a template is `POST .../dashboards/create_from_template_json/`
    /// and needs `dashboard:write`. This app deliberately does not ask for it.
    ///
    /// The single write in the whole client is toggling a feature flag, and it
    /// earns its place on three grounds this one fails on all of them:
    ///
    /// - **Reversible with the same control.** A flag flipped by mistake is
    ///   flipped back from the same row. Applying a template creates a dashboard
    ///   and multiple insights, and this app has no way to delete any of them —
    ///   the mess would have to be cleaned up somewhere else.
    /// - **Complete on a phone.** A flag toggle is one boolean. Templates are
    ///   *parameterised*: `"series": ["{DAILY_ACTIVE_USER}"]` is a
    ///   placeholder, and applying one properly means answering for every
    ///   variable it declares. Applying with the defaults silently builds a
    ///   dashboard measuring `$pageview` for a team whose product is an app.
    /// - **Reportable when it fails.** The flag toggle has a row to fail back
    ///   into and a scope preflight that names `feature_flag:write` up front.
    ///   A key without `dashboard:write` — which is most keys, because nothing
    ///   else in this app has ever needed it — would meet a 403 with nowhere
    ///   honest to put it.
    ///
    /// So the screen shows what a template builds and what it would ask for, and
    /// sends the reader to PostHog to apply it. That is a smaller feature and a
    /// true one.
    static func dashboardTemplates(projectID: Int, limit: Int = 50) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/dashboard_templates/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}
