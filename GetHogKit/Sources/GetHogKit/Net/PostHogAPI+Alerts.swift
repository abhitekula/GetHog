import Foundation

/// Writes to PostHog's own insight alerts.
///
/// **Never executed by deterministic tests.** This is derived from PostHog's
/// `AlertSerializer` and `AlertViewSet`
/// (`products/alerts/backend/api/alert.py`). Automated coverage establishes the
/// request shape with synthetic values and does not retain tenant responses.
///
/// ## The request budget, which is the argument for building it
///
/// Every call below is `.crud`, and there are only ever three of them per alert
/// in its whole life: **one to create, one to snooze, one to enable or disable.**
/// After that the cost is zero — PostHog evaluates the alert on PostHog's
/// schedule and mails `subscribed_users`. Set against the local metric-alert
/// feature this app already ships, which pays four requests every two hours for
/// as long as the watch exists, a server-evaluated alert is *strictly cheaper*.
/// That is the whole case: this is not a feature bought with budget, it is one
/// that gives budget back.
///
/// The alert **list** costs nothing new either — `AutomationRoot` already makes
/// it. `alerts(projectID:insightID:)` narrows the same endpoint to one insight so
/// the insight screen does not have to page the project's alerts to find two.
///
/// ## Scopes and walls
///
/// `AlertViewSet.scope_object = "alert"`, so reads need `alert:read` and every
/// write below needs `alert:write`; `test-delivery` declares `alert:write`
/// explicitly. Two further gates are enforced inside the serializer and neither
/// is about the key:
///
/// * `_require_insight_viewer_access` — viewer access to the linked insight.
///   Raises a `ValidationError`, so it arrives as a **400**, not a 403.
/// * `_enforce_alert_feature_flags` — refuses a `MetricsQuery` insight unless the
///   organisation has the `metrics` flag. Also a 400.
///
/// Both are stated because they are the two walls whose HTTP status does not
/// match their cause, which is the shape this project's README collects. Neither
/// has been provoked from here.
///
/// ## What is *not* built
///
/// `POST /alerts/:id/test-delivery/` sends a real e-mail to every subscriber and
/// fires every configured destination. It is not offered. A phone control whose
/// blast radius is "mail my colleagues" needs to name the recipients in its
/// confirmation dialog, and the recipient list this app has is
/// `UserBasicSerializer` names off the alert row — which is present on a
/// populated `GET /alerts/` and has never been seen here, because the project has
/// none. Building a dialog around a field no response has ever carried is exactly
/// the guess this codebase treats as a defect. `DELETE /alerts/:id/` is absent
/// for the ordinary reason: this client does not delete.
public extension PostHogAPI {

    /// The project's alerts, optionally narrowed to one insight.
    ///
    /// `insight_id` is a documented list filter on the viewset
    /// (`safely_get_queryset` reads both `insight` and `insight_id`; the schema
    /// documents the latter). Narrowing server-side rather than filtering a
    /// full page client-side matters here because `limit` truncates *before* the
    /// filter would: an insight's third alert can sit past the first page, and a
    /// screen that filtered locally would say the insight has two.
    static func alerts(projectID: Int, insightID: Int?, limit: Int = 100) -> Endpoint {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let insightID {
            query.append(URLQueryItem(name: "insight_id", value: String(insightID)))
        }
        return Endpoint(
            path: "/api/projects/\(projectID)/alerts/",
            query: query,
            category: .crud
        )
    }

    /// Creates an alert on an insight.
    ///
    /// `POST /api/projects/:id/alerts/`. Returns `nil` rather than a request
    /// whenever `AlertDraft` cannot produce a body it can stand behind — an empty
    /// subscriber list, a blank or over-long name — for the same reason
    /// `setFlagRollout` does: the user is told before a request is spent.
    ///
    /// **There is no client-side alert cap, and the one the docs describe is not
    /// enforced where it is described.** PostHog's public docs say *"Free tier
    /// organizations can create up to 5 alerts total"*. The serializer's `create`
    /// calls `check_count_limit(key=LimitKey.MAX_ALERTS_PER_TEAM, …)`, whose own
    /// docstring reads *"Notification-only: this never raises `LimitExceeded` and
    /// never blocks the caller"*, and whose catalogue entry for that key is a flat
    /// `default=200` with no per-plan override. So the two disagree, the code path
    /// that was read does not block, and this builder does not pre-empt a refusal
    /// it cannot predict. If a create is refused for a plan reason the response
    /// says so and `WriteFailure` prints PostHog's own sentence. **Neither claim
    /// is asserted from tenant data**; tests cover only synthetic responses.
    static func createAlert(projectID: Int, draft: AlertDraft) -> Endpoint? {
        guard let payload = draft.jsonValue,
              let body = try? JSONEncoder().encode(payload)
        else { return nil }

        return Endpoint(
            path: "/api/projects/\(projectID)/alerts/",
            method: "POST",
            body: body,
            category: .crud
        )
    }

    /// Snoozes an alert, or clears an existing snooze.
    ///
    /// `PATCH /api/projects/:id/alerts/:id/` carrying only `snoozed_until`.
    ///
    /// The value is a **relative** string — `"4h"`, `"1d"` — because the field is
    /// a `RelativeDateTimeField` and `update` parses it with
    /// `relative_date_parse(…, increase=True, always_truncate=True)`. `nil`
    /// unsnoozes: the serializer distinguishes "key absent" from "key present and
    /// null" with a `serializers.empty` sentinel, and only the second calls
    /// `apply_unsnooze`. So an unsnooze **must** send an explicit JSON null, and
    /// dropping the key — the obvious way to express "no snooze" — would answer
    /// 200 and change nothing. Same family as the `validate_filters` trap
    /// `FlagRollout` documents.
    ///
    /// See `AlertSnooze` for why the durations are named for where they land
    /// rather than for how long they look.
    static func setAlertSnoozed(
        projectID: Int,
        alertID: String,
        until snooze: AlertSnooze?
    ) -> Endpoint? {
        let payload = JSONValue.object([
            "snoozed_until": snooze.map { .string($0.rawValue) } ?? .null
        ])
        guard let body = try? JSONEncoder().encode(payload) else { return nil }

        return Endpoint(
            path: "/api/projects/\(projectID)/alerts/\(alertID)/",
            method: "PATCH",
            body: body,
            category: .crud
        )
    }

    /// Starts or stops evaluation of an alert.
    ///
    /// `PATCH /api/projects/:id/alerts/:id/` carrying only `enabled`. Distinct
    /// from a snooze in what it means to the reader and to the server: a snooze
    /// expires by itself and the alert resumes, a disable does not. The serializer
    /// routes them through different state-machine transitions (`apply_enable` /
    /// `apply_disable` against `apply_snooze` / `apply_unsnooze`), so they are two
    /// calls here rather than one with a flag.
    static func setAlertEnabled(
        projectID: Int,
        alertID: String,
        enabled: Bool
    ) -> Endpoint? {
        let payload = JSONValue.object(["enabled": .bool(enabled)])
        guard let body = try? JSONEncoder().encode(payload) else { return nil }

        return Endpoint(
            path: "/api/projects/\(projectID)/alerts/\(alertID)/",
            method: "PATCH",
            body: body,
            category: .crud
        )
    }
}
