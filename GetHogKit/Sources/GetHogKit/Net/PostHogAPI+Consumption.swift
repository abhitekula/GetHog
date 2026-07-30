import Foundation

/// What the project is spending, and whether its instrumentation is current.
///
/// Grouped because they are read in the same place and at the same moment — the
/// consumption story in Settings — and because both are pre-computed reads that
/// bill against the same organisation-wide budget as everything else the app
/// does. Neither is fetched on launch; see the Settings section that owns them.
public extension PostHogAPI {

    /// Every metered resource, its usage, and its limit where one exists.
    ///
    /// Answers as a bare map of resource key to `{limited, usage, limit}` with
    /// no envelope, so it decodes through `QuotaLimits` rather than `Page`.
    ///
    /// Can answer 403 when the key lacks the scope PostHog names in the
    /// response; the app repeats PostHog's own wording rather than guessing at a
    /// scope name, because a wrong one sends the user to tick the wrong box.
    static func quotaLimits(projectID: Int) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/quota_limits/",
            // A stored read that computes nothing, so it takes the cheapest of
            // the three shared budgets rather than the analytics one.
            category: .crud
        )
    }

    /// The user's LLM spend across PostHog products.
    ///
    /// **Not project-scoped.** The path is `/api/llm_analytics/@me/spend/` — it
    /// answers for the signed-in user across the whole organisation and takes no
    /// project id at all.
    ///
    /// That needed no new `Endpoint` shape. `Endpoint` has never known about
    /// projects: it holds a literal `path`, and every builder in this catalog
    /// interpolates the id itself, so a builder that omits it is just a builder
    /// with a shorter string. `PostHogAPI.me()` — `/api/users/@me/` — already
    /// proves the `@` survives URL building, which is the one part worth
    /// checking, since `URLComponents` percent-encodes it and `/%40me/` is a 404.
    ///
    /// `product` is required by the API and scopes only the tool/model/day
    /// breakdowns; `summary` and `by_product` are cross-product regardless, and
    /// they are the two this app reads.
    static func llmSpend(product: String = "posthog_code") -> Endpoint {
        Endpoint(
            path: "/api/llm_analytics/@me/spend/",
            query: [URLQueryItem(name: "product", value: product)],
            // Server-side aggregation over ClickHouse, cached for five minutes.
            // Cheaper than a `/query/` call but not free, so it pays from the
            // analytics budget rather than the CRUD one.
            category: .analytics
        )
    }

    /// PostHog's own verdict on the project's SDK versions.
    ///
    /// Returns the assessment, not the raw versions: `overall_health`, a
    /// severity per SDK, and the written `reason` and `banners` behind them. The
    /// rules that produced it — grace periods, minor-count thresholds, age and
    /// traffic shares — run server-side and are not reproduced here.
    static func sdkHealthReport(projectID: Int) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/sdk_health/report/",
            category: .crud
        )
    }
}
