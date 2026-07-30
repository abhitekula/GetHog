import GetHogKit
import SwiftUI

/// Loading for the two consumption cards in Settings.
///
/// Split from the views because both cards have the same awkward property: they
/// are the only requests in the app that must **not** fire when their screen
/// appears. Settings is opened to change a project or read a key far more often
/// than to read a quota, and PostHog's rate limits are counted per organisation
/// — so a request made on every appearance is one the user's production
/// integrations can no longer make, spent on a card nobody scrolled to.
///
/// Both stores are therefore driven by a `.task` on the *row*, not on the
/// screen. `List` realises rows lazily, so the task runs the first time the
/// section is actually on screen and not before, and `loadedFor`/`hasLoaded`
/// stop a scroll back and forth from paying again.

// MARK: - Quota and spend

@MainActor
@Observable
final class QuotaStore {
    private(set) var quota: QuotaLimits?
    private(set) var spend: LLMSpend?
    private(set) var quotaFailure: LoadFailure?
    private(set) var spendFailure: LoadFailure?
    private(set) var isLoading = false
    private(set) var loadedAt: Date?

    /// Quota is per project, so switching project invalidates it.
    private var loadedFor: Int?
    /// Spend is **not**: `/api/llm_analytics/@me/spend/` answers for the user
    /// across the whole organisation, so it survives a project switch and is not
    /// re-requested for one.
    private var hasLoadedSpend = false

    func loadIfNeeded(client: PostHogClient?, projectID: Int?) async {
        guard let client, let projectID else { return }
        let needsQuota = loadedFor != projectID
        let needsSpend = !hasLoadedSpend
        guard needsQuota || needsSpend else { return }
        await load(client: client, projectID: projectID, quota: needsQuota, spend: needsSpend)
    }

    /// Explicit retry after a failure, which is the only path that re-requests
    /// something already loaded.
    func reload(client: PostHogClient?, projectID: Int?) async {
        guard let client, let projectID else { return }
        await load(client: client, projectID: projectID, quota: true, spend: true)
    }

    private func load(client: PostHogClient, projectID: Int, quota: Bool, spend: Bool) async {
        isLoading = true
        defer { isLoading = false }

        // Sequential, and deliberately so. `async let` starts its work the
        // moment it is written, so the obvious two-line concurrent version
        // spends the spend request even on a project switch, where only the
        // quota half is stale — which is the exact waste this store exists to
        // avoid. Two reads back to back cost a few hundred milliseconds on a
        // screen nobody is watching a spinner on.
        if quota {
            do {
                self.quota = try await client.send(PostHogAPI.quotaLimits(projectID: projectID))
                quotaFailure = nil
                loadedFor = projectID
            } catch {
                quotaFailure = Self.describe(error, loading: "quota")
            }
        }
        if spend {
            do {
                self.spend = try await client.send(PostHogAPI.llmSpend())
                spendFailure = nil
                hasLoadedSpend = true
            } catch {
                spendFailure = Self.describe(error, loading: "AI spend")
            }
        }
        loadedAt = Date()
    }

    /// A refused request, described without guessing at the fix.
    ///
    /// Both endpoints answer 403 when the key lacks a scope, and PostHog names
    /// the scope in its own message — `PostHogErrorEnvelope.missingScope` lifts
    /// it out. When PostHog does not name one, this says so rather than
    /// substituting a plausible scope: sending someone to tick the wrong box in
    /// their key settings costs them a round trip and leaves the card broken.
    ///
    /// 402 is a live possibility here too — LLM analytics is not on every plan —
    /// and `PostHogError.paymentRequired` already carries PostHog's own sentence.
    static func describe(_ error: any Error, loading subject: String) -> LoadFailure {
        guard case .forbidden(let scope, let detail) = error as? PostHogError else {
            return LoadFailure(error, loading: subject)
        }
        if let scope {
            return LoadFailure(
                summary: "Your API key is missing the \(scope) scope, so PostHog won't report \(subject). Add it to the key in PostHog, then re-check permissions above.",
                detail: detail
            )
        }
        return LoadFailure(
            summary: "PostHog refused this key's request for \(subject) and didn't name the scope it wanted.",
            detail: detail
        )
    }
}

// MARK: - SDK health

@MainActor
@Observable
final class SDKHealthStore {
    private(set) var report: SDKHealthReport?
    private(set) var failure: LoadFailure?
    private(set) var isLoading = false
    private(set) var loadedAt: Date?

    private var loadedFor: Int?

    func loadIfNeeded(client: PostHogClient?, projectID: Int?) async {
        guard let client, let projectID, loadedFor != projectID else { return }
        await load(client: client, projectID: projectID)
    }

    func reload(client: PostHogClient?, projectID: Int?) async {
        guard let client, let projectID else { return }
        await load(client: client, projectID: projectID)
    }

    private func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await client.send(PostHogAPI.sdkHealthReport(projectID: projectID))
            failure = nil
            loadedFor = projectID
        } catch {
            failure = QuotaStore.describe(error, loading: "SDK health")
        }
        loadedAt = Date()
    }
}
