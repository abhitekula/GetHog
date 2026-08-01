import AppIntents
import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// What the app tells the system about what the user did.
///
/// Two halves, and only one of them is checkable from a simulator.
///
/// The **policy** — which acts may be donated at all — is pure and is asserted
/// exhaustively below. It is the half that can be wrong in a way nobody would
/// see: a flag the user deliberately kept in-app becoming a Siri suggestion, or
/// a suggestion offered for an insight the intent behind it can only refuse.
///
/// The **donation itself** is asserted only as far as the platform will admit:
/// that `AppIntent.donate()` accepts the intent and returns an identifier rather
/// than throwing. What that identifier feeds — how Siri and Spotlight rank a
/// donation, whether a suggestion appears, and where — is not observable from a
/// test, from a simulator, or from the app. This file does not pretend
/// otherwise.
@Suite("Intent donations", .serialized)
struct IntentDonationTests {

    // MARK: - Fixtures

    private func demoDashboard() async throws -> Dashboard {
        let url = URL(string: "https://us.posthog.com/api/projects/1001/dashboards/725101/")!
        let (data, _) = try await DemoTransport().send(URLRequest(url: url))
        return try JSONDecoder().decode(Dashboard.self, from: data)
    }

    private func demoInsightList() async throws -> [Insight] {
        let url = URL(string: "https://us.posthog.com/api/projects/1001/insights/?limit=100")!
        let (data, _) = try await DemoTransport().send(URLRequest(url: url))
        return try Page<Insight>.decode(from: data).results
    }

    private func flag(id: Int, active: Bool = true) throws -> FeatureFlag {
        let json = """
        {"id": \(id), "key": "checkout-v2", "name": "Checkout v2", "active": \(active),
         "deleted": false, "archived": false, "filters": {}}
        """
        return try JSONDecoder().decode(FeatureFlag.self, from: Data(json.utf8))
    }

    // MARK: - The flag opt-in

    /// The constraint that matters most here. Quick toggling is off per flag
    /// unless the user has turned it on inside the app, where the flag's rollout
    /// conditions are visible — see `FlagQuickToggle`, where the default is
    /// documented as deliberate. A donation would put that flag in front of Siri
    /// as a suggestion, which is the exact thing the opt-in exists to prevent,
    /// and `SetFeatureFlagIntent` would refuse it if tapped.
    @MainActor
    @Test("never donates a flag the user has not opted in to quick toggling")
    func flagOptInGatesDonation() throws {
        let id = 990_001
        FlagQuickToggle.setAllowed(false, flagID: id)
        #expect(!IntentDonations.mayDonateToggle(flagID: id))

        FlagQuickToggle.setAllowed(true, flagID: id)
        #expect(IntentDonations.mayDonateToggle(flagID: id))

        FlagQuickToggle.setAllowed(false, flagID: id)
    }

    /// Off for a flag nobody has ever opened, which is every flag on a fresh
    /// install. A default of "allowed" here would donate the first flag the user
    /// happened to flip.
    @MainActor
    @Test("a flag nobody has touched is not donatable")
    func unknownFlagIsNotDonatable() {
        #expect(!IntentDonations.mayDonateToggle(flagID: 42_424_242))
    }

    // MARK: - The metric gate

    /// `GetMetricValueIntent` answers with one spoken number, which it gets from
    /// `IntentMetric`. Donating an insight that reduces to no number would build
    /// a suggestion whose only possible outcome is the intent's own refusal.
    @Test("only donates a metric read for an insight the intent could answer")
    func metricGateMatchesTheIntent() async throws {
        let dashboard = try await demoDashboard()
        let computed = dashboard.tiles.compactMap(\.insight)
        #expect(!computed.isEmpty)

        for insight in computed {
            // The gate and the intent's own reduction are the same question, so
            // they must give the same answer for every insight in the fixture.
            #expect(
                IntentDonations.mayDonateMetricRead(insight)
                    == (IntentMetric(insight: insight, fallbackTitle: insight.title) != nil)
            )
        }
        #expect(computed.contains { IntentDonations.mayDonateMetricRead($0) })
    }

    /// Why the donation sits after `loadResults` in `SavedInsightDetailView`
    /// rather than at the row tap in `InsightsRoot`.
    ///
    /// Measured, and not what was assumed: the collection endpoint returns
    /// *some* insights carrying a cached result and some carrying none, so the
    /// answer to "could Siri say a number for this" depends on whether PostHog
    /// happened to have that one warm when the list was fetched. Asked at the
    /// row tap, the same insight would be donatable on Monday and not on
    /// Tuesday. Asked after the detail screen's own `loadResults`, it is decided
    /// against a value the user has actually been shown.
    @Test("the library listing answers the metric question inconsistently")
    func listingIsNotWhereTheGateBelongs() async throws {
        let listed = try await demoInsightList()
        #expect(!listed.isEmpty)
        #expect(listed.contains { IntentDonations.mayDonateMetricRead($0) })
        #expect(listed.contains { !IntentDonations.mayDonateMetricRead($0) })
    }

    // MARK: - The donation

    /// **What a donation actually does here, written down rather than assumed.**
    ///
    /// `AppIntent.donate()` hands the intent to `com.apple.linkd`, and in a
    /// unit-test host on the simulator that daemon is not reachable: every one
    /// of the three donations the app makes comes back as `NSCocoaErrorDomain`
    /// **4099** — "The connection to service named com.apple.linkd.transcript
    /// was invalidated from this process". Measured, three for three, for the
    /// dashboard open, the metric read and the flag write.
    ///
    /// That is the environment's limit, not the app's, and it is asserted rather
    /// than tolerated for two reasons. It proves the call is genuinely made and
    /// reaches the system boundary — a donation that was never wired up would
    /// fail differently, or not at all. And it is the exact failure
    /// `IntentDonations.donate` is built to absorb: detached, non-throwing,
    /// logged and never surfaced, because there is nothing a user could do with
    /// the news that Siri's ranking did not get updated.
    ///
    /// If this ever starts succeeding — on a device, or in a future runtime —
    /// this test is what will say so, and the right response is to record the
    /// new behaviour here rather than to delete the assertion.
    ///
    /// **Not asserted, and not assertable:** anything downstream. Whether a
    /// suggestion appears, where it ranks, and how it decays are Siri's and
    /// Spotlight's business, and neither exposes any of it — to the app, to a
    /// test, or to any API.
    @Test("every donation the app makes reaches the system, which refuses it in this host")
    func donationsReachTheSystemBoundary() async throws {
        let intents: [any AppIntent] = [
            OpenDashboardIntent(dashboard: DashboardEntity(
                id: 725_101, name: "Example dashboard", summary: nil, isPinned: true
            )),
            GetMetricValueIntent(insight: InsightEntity(
                id: 1, name: "Daily active users", kind: "TrendsQuery"
            )),
            SetFeatureFlagIntent(
                flag: FeatureFlagEntity(
                    id: 710_301, key: "example-navigation", name: "Example navigation",
                    isActive: true, allowsQuickToggle: true
                ),
                enabled: true
            ),
        ]

        for intent in intents {
            do {
                let identifier = try await intent.donate()
                // The outcome this file would rather have. Kept as a passing
                // branch so a runtime that does accept donations is not a red
                // build — but recorded, so nobody has to guess which branch ran.
                Issue.record("Donation of \(type(of: intent)) succeeded: \(identifier)")
            } catch let error as NSError {
                #expect(error.domain == NSCocoaErrorDomain)
                #expect(error.code == 4099, "unexpected donation failure: \(error)")
            }
        }
    }

    /// The app's own entry points, which must be safe to call from a tap
    /// handler: they return immediately, they never throw, and the gated ones
    /// do nothing at all when the gate says no.
    @MainActor
    @Test("the app's donation calls are fire-and-forget and never propagate a failure")
    func donationCallsAreSafe() async throws {
        let quiet = try flag(id: 990_004)
        FlagQuickToggle.setAllowed(false, flagID: quiet.id)

        let summary = try JSONDecoder().decode(
            DashboardSummary.self,
            from: Data(#"{"id": 1, "name": "D", "pinned": false}"#.utf8)
        )
        IntentDonations.dashboardOpened(summary)
        IntentDonations.flagSet(quiet, enabled: true)

        // Nothing above throws and nothing above blocks; the donations are
        // detached, and a failure is logged rather than raised. Reaching this
        // line is the assertion.
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// The parameter is what makes a donation worth making: the system learns
    /// "this person opens *this* dashboard", not "this person opens dashboards".
    @Test("a donated intent carries the object it was performed on")
    func donationCarriesItsParameter() async throws {
        let flag = try flag(id: 990_003)
        let entity = FeatureFlagEntity(flag)
        #expect(entity.id == flag.id)
        #expect(entity.key == flag.key)

        let intent = SetFeatureFlagIntent(flag: entity, enabled: false)
        #expect(intent.flag.key == "checkout-v2")
        #expect(intent.enabled == false)
    }
}
