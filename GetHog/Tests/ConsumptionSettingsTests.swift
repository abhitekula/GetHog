import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// The two consumption cards, at the seams the kit tests cannot reach: what the
/// demo actually serves them, and what they say when PostHog refuses.
@Suite("Consumption in Settings")
struct ConsumptionSettingsTests {

    private func fixture(for path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: "https://us.posthog.com" + path)!
        if !query.isEmpty { components.queryItems = query }
        let (data, _) = try await DemoTransport().send(URLRequest(url: components.url!))
        return data
    }

    /// All three payloads are bare objects rather than `Page`s, so a missing
    /// route does not fail — it falls through to `{"count":0,…,"results":[]}`,
    /// which decodes into a quota with no resources and a health report with no
    /// verdict. That renders as "nothing to worry about", which is the one wrong
    /// answer worse than an error, and it is invisible without this test.
    @Test("the demo serves real quota, spend and SDK health rather than an empty page")
    func demoRoutesResolve() async throws {
        let quota = try QuotaLimits.decode(
            from: try await fixture(for: "/api/projects/1001/quota_limits/")
        )
        #expect(quota.resources.count == 18)
        #expect(quota.headline?.key == "signals_credits")

        let health = try SDKHealthReport.decode(
            from: try await fixture(for: "/api/projects/1001/sdk_health/report/")
        )
        #expect(health.verdict == .needsAttention)
        #expect(health.needsUpdatingCount == 2)

        // The one route with no project segment. It is matched on the resource
        // rather than on a `/api/projects/` prefix, so it is the likeliest of
        // the three to be broken by a change to the dispatcher above it.
        let spend = try LLMSpend.decode(
            from: try await fixture(
                for: "/api/llm_analytics/@me/spend/",
                query: [URLQueryItem(name: "product", value: "posthog_code")]
            )
        )
        #expect(spend.totalCostUSD > 0)
        #expect(spend.byProduct.count == 4)
    }

    /// Both endpoints 403 on a key that is missing a scope, and PostHog names
    /// the scope in its own message. Repeating that name is the difference
    /// between a fixable card and a dead one — and guessing a plausible name
    /// instead would send someone to tick the wrong box in their key settings.
    @Test("repeats the scope PostHog named instead of guessing one")
    @MainActor
    func forbiddenNamesPostHogsScope() {
        let named = QuotaStore.describe(
            PostHogError.forbidden(
                missingScope: "organization:read",
                detail: "You do not have the `organization:read` scope."
            ),
            loading: "quota"
        )
        #expect(named.summary.contains("organization:read"))
        #expect(named.summary.contains("quota"))
        // PostHog's own sentence travels alongside rather than being dropped.
        #expect(named.detail == "You do not have the `organization:read` scope.")
    }

    @Test("admits it when PostHog names no scope at all")
    @MainActor
    func forbiddenWithoutAScope() {
        let unnamed = QuotaStore.describe(
            PostHogError.forbidden(missingScope: nil, detail: "Permission denied."),
            loading: "AI spend"
        )
        // No invented scope anywhere in the sentence.
        #expect(!unnamed.summary.contains(":read"))
        #expect(unnamed.summary.contains("didn't name"))
        #expect(unnamed.detail == "Permission denied.")
    }

    /// LLM analytics is not on every plan, so 402 is a live outcome here and
    /// PostHog's own explanation is the only useful thing to show for it.
    @Test("passes a plan refusal through in PostHog's words")
    @MainActor
    func paymentRequiredKeepsPostHogsWording() {
        let failure = QuotaStore.describe(
            PostHogError.paymentRequired("LLM analytics requires a paid plan."),
            loading: "AI spend"
        )
        #expect(failure.summary == "LLM analytics requires a paid plan.")
    }
}
