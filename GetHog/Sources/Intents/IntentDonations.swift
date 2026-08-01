import AppIntents
import Foundation
import GetHogKit

// Telling the system what the user actually did, so its suggestions can follow
// them rather than staying wherever `AppShortcutsProvider` left them.
//
// The app already declared everything Siri could *offer*: `GetHogShortcuts`
// names the phrases, `PostHogEntities` makes every dashboard, insight and flag
// resolvable by name, and `SpotlightIndexer` publishes them to search. None of
// that is a record of use. An `AppShortcut` is a menu; a donation is a
// transcript. Without the transcript, "Open my GetHog dashboard" ranks the
// same dashboard on day one and day one hundred no matter which one the user
// opens every morning.
//
// Two rules govern everything below, and they are the only interesting part.
//
// **A donation is a claim that the user did the thing.** Not that a view
// appeared — `DashboardDetailView` is also rendered by a restored window, by an
// iPad's automatic selection of the first row, and by the debug launch
// environment the UI tests drive. Every call site here is an act: a row the user
// chose, a write that succeeded. Donating on render would teach Siri the app's
// launch behaviour instead of the user's habits, and the suggestion would then
// be *wrong in a way nobody could see* — which is the failure mode this
// codebase is least willing to ship.
//
// **A donation must not create a suggestion the app would refuse.** Flag
// toggling is opt-in per flag and off by default; a flag nobody opted in cannot
// be flipped from outside the app, so donating its toggle would put a tappable
// suggestion in front of the user whose only possible outcome is
// `SetFeatureFlagIntent`'s refusal dialog. `shouldDonate` below is where that is
// decided, separately from the donating, so it can be tested without the system.
enum IntentDonations {

    private static let log = IntentDependencies.log

    // MARK: - What may be donated

    /// Whether flipping this flag is something the system may suggest.
    ///
    /// The same gate `SetFeatureFlagIntent.perform()` applies before writing,
    /// asked one step earlier. Off unless the user has opened the flag in the
    /// app and turned on "Allow quick toggle" — see `FlagQuickToggle`, where
    /// the default is documented as deliberate: outside the app there is no
    /// confirmation dialog to answer, so nothing is opted in implicitly.
    ///
    /// A flag toggled *inside* the app without that opt-in is a perfectly good
    /// action and is simply not donated. The user said this flag may only be
    /// changed where its rollout conditions are on screen, and a Siri suggestion
    /// is the exact opposite of that.
    static func mayDonateToggle(flagID: Int) -> Bool {
        FlagQuickToggle.isAllowed(flagID: flagID)
    }

    /// Whether Siri could actually answer for this insight.
    ///
    /// `GetMetricValueIntent` reduces an insight to one spoken number through
    /// `IntentMetric`, which returns nil for the kinds that have no single
    /// value — a HogQL table, a paths graph with no edges, an empty series.
    /// Donating one of those would produce a suggestion that can only ever end
    /// in "GetHog can't summarise that as a single number".
    ///
    /// Asked against the insight the screen has *already computed*, which is the
    /// only place the answer is stable. Measured on the library listing, the
    /// same question is answered inconsistently — `/insights/` returns some rows
    /// carrying a cached result and some carrying none, depending on what
    /// PostHog happened to have warm — so a gate applied at the row tap would
    /// donate the same insight on Monday and refuse it on Tuesday.
    /// `IntentDonationTests` pins both halves of that.
    static func mayDonateMetricRead(_ insight: Insight) -> Bool {
        IntentMetric(insight: insight, fallbackTitle: insight.title) != nil
    }

    // MARK: - Donating

    /// The user opened a dashboard.
    ///
    /// Donated with the dashboard as the intent's parameter, so what the system
    /// learns is "this person opens *this* dashboard", not merely "this person
    /// opens dashboards" — which is the difference between a useful suggestion
    /// and a shortcut to a picker.
    static func dashboardOpened(_ dashboard: DashboardSummary) {
        donate(OpenDashboardIntent(dashboard: DashboardEntity(dashboard)), "open \(dashboard.title)")
    }

    /// The user read a metric — that is, opened a saved insight and looked at
    /// the number this app had to compute to draw it.
    ///
    /// Silently skipped for an insight `GetMetricValueIntent` could not answer
    /// for; see `mayDonateMetricRead`.
    static func metricRead(_ insight: Insight) {
        guard mayDonateMetricRead(insight) else {
            log.debug("Not donating a metric read for an insight with no single value.")
            return
        }
        donate(GetMetricValueIntent(insight: InsightEntity(insight)), "read \(insight.title)")
    }

    /// A feature flag write landed.
    ///
    /// Called only after the request has actually succeeded. Donating an
    /// optimistic toggle would teach the system an action the server rejected,
    /// and this app rolls those back on screen — the transcript has to roll back
    /// with them.
    static func flagSet(_ flag: FeatureFlag, enabled: Bool) {
        guard mayDonateToggle(flagID: flag.id) else {
            log.debug("Not donating a flag toggle: quick toggle is off for this flag.")
            return
        }
        donate(
            SetFeatureFlagIntent(flag: FeatureFlagEntity(flag), enabled: enabled),
            "\(enabled ? "enable" : "disable") \(flag.key)"
        )
    }

    /// Hands one intent to the system and forgets about it.
    ///
    /// Detached and non-throwing on purpose. A donation is a hint about the
    /// future; nothing the user is doing right now depends on it, so it must
    /// never block a tap and must never surface a failure — there is no action
    /// available to someone told that Siri's ranking did not get updated.
    private static func donate(_ intent: some AppIntent, _ what: String) {
        Task.detached(priority: .utility) {
            do {
                _ = try await intent.donate()
                log.debug("Donated an app intent.")
            } catch {
                log.error("Could not donate an app intent.")
            }
        }
    }
}
