import Foundation
import Testing

@testable import GetHogKit

/// Quota, spend, and SDK-health decoding for deterministic synthetic payloads.
///
/// The fixtures deliberately include absent limits, an unattributed spend row,
/// a summary that differs from its breakdown, and both known and unknown health
/// vocabulary so the Settings cards keep those cases distinct.
@Suite("Consumption")
struct ConsumptionTests {
    @Test("synthetic endpoint overview uses authored metrics")
    func syntheticEndpointOverviewMetrics() throws {
        let overview = try EndpointUsageOverview.decode(
            from: Fixture.data("endpoints_usage_overview.json")
        )

        #expect(overview.metrics.map(\.key) == [
            "example_orbit_requests", "example_telescope_failures", "example_starlight_cache_hits", "example_constellation_rows",
        ])
        #expect(overview.metrics.map(\.value) == [12, 5, 2, 0])
        #expect(overview.reading(endpointCount: 4) == .traffic)
    }


    // MARK: - Quota limits

    @Test("decodes the whole metered set, skipping keys that are not resources")
    func quotaDecodesEveryResource() throws {
        let quota = try QuotaLimits.decode(from: Fixture.data("quota_limits.json"))

        #expect(quota.resources.count == 18)
        // `_note` is a string, not a quota object. The map is an open set that
        // PostHog adds to, so a key it cannot read must be dropped rather than
        // fail the whole response.
        #expect(!quota.resources.contains { $0.key == "_note" })

        let signals = try #require(quota.resources.first { $0.key == "signals_credits" })
        #expect(signals.usage == 6_007)
        #expect(signals.limit == 9_007)
        #expect(signals.limited == false)
    }

    /// The case that decides whether this card can be trusted at all.
    ///
    /// `exceptions`, `recordings`, and `llm_events` carry `usage` with no
    /// `limit`. Reading absence as zero would render a fictitious overage.
    @Test("treats an absent limit as unmetered, never as zero")
    func quotaAbsentLimit() throws {
        let quota = try QuotaLimits.decode(from: Fixture.data("quota_limits.json"))
        let exceptions = try #require(quota.resources.first { $0.key == "exceptions" })

        #expect(exceptions.limit == nil)
        #expect(exceptions.fraction == nil)
        #expect(exceptions.pressure == .unmetered)
        #expect(exceptions.usage == 43)

        let description = exceptions.usageDescription(locale: Locale(identifier: "en_US"))
        #expect(!description.contains("of 0"))
        #expect(!description.contains("0%"))
        #expect(description.contains("43"))
        // The word beside the bar has to say why there is no bar.
        #expect(exceptions.stateWord == "Unmetered")
    }

    @Test("a lightly used metered resource remains distinct from unmetered")
    func quotaMeteredUsage() throws {
        let quota = try QuotaLimits.decode(from: Fixture.data("quota_limits.json"))
        let credits = try #require(quota.resources.first { $0.key == "ai_credits" })

        // A small nonzero share of a finite allowance differs from "no limit
        // exists", and the two must not collapse into the same row.
        #expect(credits.usage == 121)
        #expect(credits.limit == 31_007)
        #expect(abs(try #require(credits.fraction) - (121.0 / 31_007.0)) < 0.000_000_1)
        #expect(credits.pressure == .clear)
        #expect(credits.usageDescription(locale: Locale(identifier: "en_US")) == "121 of 31,007")
    }

    @Test("ranks the resource nearest its limit first, not the alphabet")
    func quotaRanking() throws {
        let quota = try QuotaLimits.decode(from: Fixture.data("quota_limits.json"))

        // Eighteen rows, seventeen of them at or near zero. The only question
        // worth answering away from a desk is which one is close.
        #expect(quota.resources.first?.key == "signals_credits")

        let ranked = quota.resources.map(\.key)
        let signals = try #require(ranked.firstIndex(of: "signals_credits"))
        let events = try #require(ranked.firstIndex(of: "events"))
        let exceptions = try #require(ranked.firstIndex(of: "exceptions"))

        // 66.7% beats 0.18%…
        #expect(signals < events)
        // …and anything metered beats a resource with no limit to be near.
        #expect(events < exceptions)
    }

    @Test("a blocked resource outranks one that is merely close")
    func quotaBlockedOutranksClose() throws {
        // `limited: true` is not a prediction — PostHog has already stopped
        // accepting the resource. A row at 95% is a warning; this one is an
        // outage, and no percentage may push it down the list.
        let json = """
        {"barely_used": {"limited": true, "usage": 5, "limit": 100},
         "nearly_full": {"limited": false, "usage": 95, "limit": 100}}
        """
        let quota = try QuotaLimits.decode(from: Data(json.utf8))

        #expect(quota.resources.first?.key == "barely_used")
        #expect(quota.resources.first?.pressure == .blocked)
        #expect(quota.resources.first?.stateWord == "At limit")
        #expect(quota.blockedCount == 1)

        let nearlyFull = try #require(quota.resources.last)
        #expect(nearlyFull.pressure == .critical)
        #expect(nearlyFull.stateWord == "Critical")
    }

    @Test("separates what is pressing from what is noise")
    func quotaPressingSplit() throws {
        let quota = try QuotaLimits.decode(from: Fixture.data("quota_limits.json"))

        // One resource is past half its allowance; seventeen are not, and a
        // glanceable card must not spend its height on the seventeen.
        #expect(quota.pressing.map(\.key) == ["signals_credits"])
        #expect(quota.quiet.count == 17)
        #expect(quota.headline?.key == "signals_credits")
    }

    /// A quiet project must not produce an empty card.
    @Test("names the leader even when nothing is pressing")
    func quotaHeadlineWithoutPressure() throws {
        let json = """
        {"events": {"limited": false, "usage": 10, "limit": 1000},
         "recordings": {"limited": false, "usage": 4}}
        """
        let quota = try QuotaLimits.decode(from: Data(json.utf8))

        #expect(quota.pressing.isEmpty)
        // Still the most-consumed metered resource — "nothing is close, and here
        // is what is closest" is a better answer than nothing at all.
        #expect(quota.headline?.key == "events")
    }

    @Test("titles a resource key without inventing words for it")
    func quotaTitles() throws {
        let quota = try QuotaLimits.decode(from: Fixture.data("quota_limits.json"))
        func title(_ key: String) throws -> String {
            try #require(quota.resources.first { $0.key == key }).title
        }

        // Acronyms PostHog spells in lower case are the whole reason this is not
        // just `.capitalized`, which produces "Llm events" and "Posthog code".
        #expect(try title("llm_events") == "LLM events")
        #expect(try title("ai_credits") == "AI credits")
        #expect(try title("posthog_code_credits") == "PostHog code credits")
        #expect(try title("logs_mb_ingested") == "Logs MB ingested")
        #expect(try title("events") == "Events")
    }

    @Test("survives a metered resource this client has never heard of")
    func quotaUnknownResource() throws {
        // The set is PostHog's to grow. A new product appearing here must show
        // up as a row, not drop the seventeen it arrived alongside.
        let json = #"{"antimatter_credits": {"limited": false, "usage": 39, "limit": 40}}"#
        let quota = try QuotaLimits.decode(from: Data(json.utf8))

        let resource = try #require(quota.resources.first)
        #expect(resource.key == "antimatter_credits")
        #expect(resource.title == "Antimatter credits")
        #expect(resource.pressure == .critical)
    }

    @Test("orders deterministically when two resources are equally pressed")
    func quotaStableOrder() throws {
        // `allKeys` on a JSON object arrives in no defined order, so without a
        // final tie-break the card would reshuffle itself between loads.
        let json = """
        {"zebra": {"limited": false, "usage": 1, "limit": 2},
         "alpha": {"limited": false, "usage": 1, "limit": 2}}
        """
        for _ in 0..<20 {
            let quota = try QuotaLimits.decode(from: Data(json.utf8))
            #expect(quota.resources.map(\.key) == ["alpha", "zebra"])
        }
    }

    // MARK: - LLM spend

    @Test("decodes the spend summary and its per-product breakdown")
    func spendDecoding() throws {
        let spend = try LLMSpend.decode(from: Fixture.data("llm_spend.json"))

        #expect(spend.totalCostUSD == 11.250001)
        #expect(spend.eventCount == 25)
        #expect(spend.byProduct.count == 4)
        #expect(spend.dateFrom != nil)
        #expect(spend.dateTo != nil)

        // Cost descending, because "what is this money going on" is the only
        // question the breakdown answers.
        #expect(spend.byProduct.map(\.product) == [
            "api_assistant",
            "support_summarizer",
            "documentation_helper",
            nil,
        ])
        #expect(spend.byProduct.first?.costUSD == 5)
    }

    /// A `product: null` row still represents spend and must remain visible.
    @Test("keeps the unattributed spend row rather than dropping it")
    func spendUnattributedProduct() throws {
        let spend = try LLMSpend.decode(from: Fixture.data("llm_spend.json"))
        let unattributed = try #require(spend.byProduct.first { $0.product == nil })

        #expect(unattributed.eventCount == 3)
        #expect(unattributed.title == "Unattributed")
        // Identifiable in a ForEach without an optional key blowing up.
        #expect(!unattributed.id.isEmpty)
    }

    /// The server summary and its product rows can cover different scopes. The
    /// client must therefore display the summary rather than recompute a total.
    @Test("takes the total from the server instead of re-adding the parts")
    func spendDoesNotRecomputeTheTotal() throws {
        let spend = try LLMSpend.decode(from: Fixture.data("llm_spend.json"))
        let summed = spend.byProduct.reduce(0) { $0 + $1.costUSD }

        #expect(spend.totalCostUSD != summed)
        #expect(spend.totalCostUSD == 11.250001)
        #expect(summed == 11.25)
    }

    @Test("formats spend as currency rather than as a raw double")
    func spendCurrencyFormatting() throws {
        let spend = try LLMSpend.decode(from: Fixture.data("llm_spend.json"))
        let us = Locale(identifier: "en_US")

        // A raw six-decimal value is not a price. Currency style turns it into
        // something a person can read, and it is the only arithmetic done here.
        #expect(spend.formattedTotal(locale: us) == "$11.25")
        #expect(spend.byProduct.first?.formattedCost(locale: us) == "$5.00")

        // An integer cost still renders with currency precision.
        let unattributed = try #require(spend.byProduct.first { $0.product == nil })
        #expect(unattributed.formattedCost(locale: us) == "$1.00")
    }

    @Test("reports zero spend as zero rather than as missing")
    func spendEmpty() throws {
        let json = #"{"summary": {"total_cost_usd": 0, "event_count": 0}, "by_product": {"items": []}}"#
        let spend = try LLMSpend.decode(from: Data(json.utf8))

        #expect(spend.totalCostUSD == 0)
        #expect(spend.byProduct.isEmpty)
        #expect(spend.formattedTotal(locale: Locale(identifier: "en_US")) == "$0.00")
    }

    // MARK: - SDK health

    @Test("reads the reported verdict instead of deriving one")
    func sdkHealthVerdict() throws {
        let report = try SDKHealthReport.decode(from: Fixture.data("sdk_health_report.json"))

        #expect(report.verdict == .needsAttention)
        #expect(report.verdict.title == "Needs attention")
        #expect(report.level == .danger)
        #expect(report.needsUpdatingCount == 2)
        #expect(report.sdks.count == 4)
        // `flagged` decides which rows get drawn, while the headline keeps the
        // independently supplied count.
        #expect(report.flagged.count == 2)
    }

    /// The endpoint has already applied its policy; the client should surface
    /// the supplied reason without inventing a competing diagnosis.
    @Test("surfaces the supplied SDK reason exactly")
    func sdkHealthReasonIsExactly() throws {
        let report = try SDKHealthReport.decode(from: Fixture.data("sdk_health_report.json"))
        let node = try #require(report.sdks.first { $0.name == "Example sdk name 0429" })

        #expect(node.reason == "The synthetic request was rejected for deterministic error coverage.")
        #expect(node.banners.count == 2)
        #expect(node.banners == ["Example banners 0428", "Example banners 0428-synthetic-added"])
        #expect(node.currentVersion == "Example current version 0431")
        #expect(node.latestVersion == "Example latest version 0430")
    }

    @Test("ranks the worst SDK first")
    func sdkHealthOrdering() throws {
        let report = try SDKHealthReport.decode(from: Fixture.data("sdk_health_report.json"))
        #expect(report.sdks.last?.name == "Example sdk name 0652")
        #expect(report.sdks.last?.severity == .info)
        #expect(report.sdks.last?.severity.isConcerning == false)
    }

    /// An SDK with no banner has `banners: []`. Rendering a banner block for an
    /// empty array would leave an unexplained gap under the verdict.
    @Test("handles an empty banners array")
    func sdkHealthEmptyBanners() throws {
        let report = try SDKHealthReport.decode(from: Fixture.data("sdk_health_report.json"))
        let python = try #require(report.sdks.first { $0.name == "Example sdk name 0652" })

        #expect(python.banners.isEmpty)
        #expect(python.reason == "The synthetic request was rejected for deterministic error coverage.")
        #expect(python.health == .healthy)
    }

    @Test("handles banners being absent entirely")
    func sdkHealthMissingBanners() throws {
        let json = #"{"overall_health": "healthy", "sdks": [{"sdk_name": "posthog-ios", "severity": "info"}]}"#
        let report = try SDKHealthReport.decode(from: Data(json.utf8))

        let ios = try #require(report.sdks.first)
        #expect(ios.banners == [])
        #expect(ios.reason == nil)
        #expect(report.needsUpdatingCount == 0)
    }

    /// PostHog owns this vocabulary and spells the same idea two ways already —
    /// `health` says `danger` where `severity` says `critical`. A third word is
    /// a matter of time, and it must not be silently read as "fine".
    @Test("quarantines a severity that does not exist yet")
    func sdkHealthUnknownSeverity() throws {
        let json = #"{"overall_health": "on_fire", "health": "catastrophic", "sdks": [{"sdk_name": "posthog-go", "severity": "catastrophic", "banners": []}]}"#
        let report = try SDKHealthReport.decode(from: Data(json.utf8))

        #expect(report.level == .unknown("catastrophic"))
        #expect(report.verdict == .unknown("on_fire"))
        // Shown in PostHog's word, not translated into one of ours.
        #expect(report.level.title == "Catastrophic")
        #expect(report.verdict.title == "On fire")

        let go = try #require(report.sdks.first)
        #expect(go.severity == .unknown("catastrophic"))
        // An unrecognised level counts as concerning. Guessing the other way
        // would hide exactly the case this quarantine exists for.
        #expect(go.severity.isConcerning)
        #expect(report.flagged.count == 1)
    }

    @Test("says nothing rather than something when the level is missing")
    func sdkHealthMissingLevel() throws {
        let json = #"{"overall_health": "healthy", "needs_updating_count": 0, "sdks": []}"#
        let report = try SDKHealthReport.decode(from: Data(json.utf8))

        #expect(report.verdict == .healthy)
        #expect(report.verdict.isClear)
        // `health` was not in the payload. "Not reported" is true; "Healthy"
        // would be a claim the response did not make.
        #expect(report.level.title == "Not reported")
        #expect(report.sdks.isEmpty)
    }

    /// Accept both supported container spellings so either response shape
    /// produces rows rather than an empty card.
    @Test("finds the SDK rows under either key PostHog might use")
    func sdkHealthAlternateContainerKey() throws {
        let json = #"{"overall_health": "healthy", "results": [{"sdk_name": "posthog-android", "severity": "warning"}]}"#
        let report = try SDKHealthReport.decode(from: Data(json.utf8))
        #expect(report.sdks.map(\.name) == ["posthog-android"])
    }

    // MARK: - Endpoint usage fixture

    @Test("decodes the complete synthetic endpoint-usage metric set")



    func endpointUsageFixture() throws {
        let overview = try EndpointUsageOverview.decode(
            from: Fixture.data("endpoints_usage_overview.json")
        )

        #expect(overview.metrics.map(\.key) == [
            "example_orbit_requests", "example_telescope_failures", "example_starlight_cache_hits", "example_constellation_rows",
        ])
        #expect(overview.metrics.map(\.value) == [12, 5, 2, 0])
        #expect(overview.metrics.allSatisfy { !$0.hasComparison })
        #expect(overview.reading(endpointCount: 4) == .traffic)
    }

    // MARK: - Endpoints

    @Test("builds the project-scoped quota and SDK health paths")
    func consumptionEndpoints() {
        let quota = PostHogAPI.quotaLimits(projectID: 1_001)
        #expect(quota.path == "/api/projects/1001/quota_limits/")
        #expect(quota.method == "GET")
        // A plain read that computes nothing, so it bills against the cheapest
        // of the three shared budgets.
        #expect(quota.category == .crud)

        let health = PostHogAPI.sdkHealthReport(projectID: 1_001)
        #expect(health.path == "/api/projects/1001/sdk_health/report/")
        #expect(health.category == .crud)
    }

    /// The spend endpoint is **user-scoped**, not project-scoped: it answers for
    /// `@me` across the whole organisation and takes no project id at all.
    /// `Endpoint` never knew about projects — the id is interpolated by each
    /// builder — so this needed no new shape, only a builder that omits it. The
    /// same is already true of `PostHogAPI.me()`.
    @Test("builds the spend path with no project segment")
    func spendEndpointIsUserScoped() {
        let spend = PostHogAPI.llmSpend()

        #expect(spend.path == "/api/llm_analytics/@me/spend/")
        #expect(!spend.path.contains("/projects/"))
        #expect(spend.query.contains { $0.name == "product" && $0.value == "posthog_code" })
        #expect(spend.category == .analytics)
    }

    /// The `@` is the reason to check: `URLComponents` percent-encodes it, and a
    /// request to `/%40me/` is a 404. Proven safe by `me()` already living on the
    /// same shape, and pinned here so the second user-scoped path is covered too.
    @Test("keeps the @me segment intact through URL building")
    func spendURLSurvivesTheAtSign() throws {
        let endpoint = PostHogAPI.llmSpend()
        var components = try #require(
            URLComponents(
                url: PostHogRegion.usCloud.host.appending(path: endpoint.path),
                resolvingAgainstBaseURL: false
            )
        )
        components.queryItems = endpoint.query
        let url = try #require(components.url)

        #expect(url.path(percentEncoded: false) == "/api/llm_analytics/@me/spend/")
        #expect(url.absoluteString.contains("product=posthog_code"))
    }
}
