import Foundation

/// When GetHog is allowed to wake up and refresh the widget snapshot.
///
/// It lives beside `RateLimitGovernor` and `SharedSnapshot` because it answers
/// the same question they do: how much of an *organisation-wide* request budget —
/// one shared with whatever the user's production integrations are doing — this
/// app may spend on their behalf. Unattended spending deserves the tightest
/// answer of the three, because nobody is watching it happen.
///
/// Everything here is a pure function of an instant and the last refresh, so the
/// cadence is testable without `BGTaskScheduler`, a network, or a clock.
public enum BackgroundRefreshPolicy {

    /// The floor between two unattended refreshes.
    ///
    /// Two hours, and not the fifteen minutes `BGAppRefreshTaskRequest` samples
    /// usually reach for, because of what is actually on the other end. A
    /// snapshot metric is reduced from a *dashboard tile*, whose figure PostHog
    /// has already computed and cached; polling it every quarter hour re-fetches
    /// the same number. The widget timeline that renders the result only wakes
    /// its provider hourly (see `WidgetRefresh`), so a fresher snapshot would
    /// often not even be drawn before the next one replaced it.
    ///
    /// WidgetKit's own ~40–70 reloads a day is a ceiling, not a target: each
    /// successful refresh calls `reloadAllTimelines`, which spends from that
    /// budget for *every* installed widget at once.
    public static let minimumInterval: TimeInterval = 2 * 60 * 60

    /// How early a wake may arrive and still count as due.
    ///
    /// `earliestBeginDate` is a floor the system is free to overshoot, but the
    /// launch itself can land marginally before the interval has formally
    /// elapsed. Turning such a wake away wastes the whole opportunity — the next
    /// one is hours off — for the sake of a few seconds of purity.
    public static let dueTolerance: TimeInterval = 5 * 60

    /// Requests one coalesced refresh spends: the dashboard list, the dashboard
    /// itself, and the feature flags. Deliberately *one* dashboard fetch feeding
    /// every widget metric, rather than one request per metric.
    public static let requestsPerRefresh = 3

    /// The honest worst case to show the user in Settings, where the rest of
    /// their consumption is already on display.
    public static var maximumRequestsPerDay: Int {
        Int((24 * 60 * 60) / minimumInterval) * requestsPerRefresh
    }

    /// A wake with no credential can only fail, and failures teach iOS that this
    /// app's background requests are not worth granting. Nothing is scheduled
    /// until there is something to fetch with.
    public static func shouldSchedule(hasCredential: Bool) -> Bool { hasCredential }

    /// The earliest the next wake may run.
    ///
    /// Never sooner than a full interval after the last refresh, and never in
    /// the past — an already-elapsed date asks the system to run us at the first
    /// opportunity, which is exactly right when the snapshot is genuinely old
    /// and exactly wrong when it isn't.
    public static func earliestBeginDate(lastRefreshedAt: Date?, now: Date) -> Date {
        // No history is treated as "just refreshed" rather than "overdue": the
        // budget being spent belongs to the user's organisation, so not knowing
        // buys no urgency.
        let last = lastRefreshedAt ?? now
        return max(now, last.addingTimeInterval(minimumInterval))
    }

    /// Whether a wake that has already happened should actually fetch.
    ///
    /// The coalescing guard: the app may have been in the foreground minutes
    /// ago and published a snapshot itself, in which case this wake has nothing
    /// to add and should cost nothing.
    public static func isDue(lastRefreshedAt: Date?, now: Date) -> Bool {
        guard let lastRefreshedAt else { return true }
        return now.timeIntervalSince(lastRefreshedAt) >= minimumInterval - dueTolerance
    }
}
