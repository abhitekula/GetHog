import Foundation
import Observation
import GetHogKit
import UserNotifications
import os

/// Evaluates the user's metric watches against a freshly published snapshot and
/// posts whatever crossed a line.
///
/// This is the whole of the alerting "backend". PostHog's own alerts fan out
/// from a server, which is why they were recorded as blocked here — but the
/// values the user wants watched are already in the App Group container by the
/// time this runs, put there by the same background wake that feeds the widgets.
/// Nothing is fetched for an alert; nothing leaves the device.
@MainActor
enum MetricAlertDelivery {

    private static let log = Logger(subsystem: "app.gethog", category: "metric-alerts")

    /// Called after every snapshot write, foreground and background alike.
    ///
    /// The foreground case matters as much as the wake: a user who opens the app
    /// and watches a metric recover would otherwise leave the watch latched, and
    /// the *next* genuine crossing would pass in silence.
    static func evaluate(snapshot: SharedSnapshot, store: SharedSnapshotStore = .shared) async {
        let watches = store.metricWatches()
        let breaching = store.breachingWatchIDs()

        // No watches and no latch is the overwhelmingly common case, and it has
        // to cost nothing — not a file write, and not a trip to the notification
        // centre on a background wake that has seconds to spare.
        guard !watches.isEmpty || !breaching.isEmpty else { return }

        let result = MetricWatchEvaluator.evaluate(
            snapshot: snapshot, watches: watches, breaching: breaching
        )

        // Persisted before anything is delivered. If the process dies between
        // the two, the user misses one notification; the other order would leave
        // the latch open and re-notify about the same number every two hours
        // until the metric recovered.
        try? store.writeBreachingWatchIDs(result.breaching)

        guard !result.alerts.isEmpty else { return }
        await post(result.alerts)
    }

    private static func post(_ alerts: [MetricAlert]) async {
        let center = UNUserNotificationCenter.current()

        // Authorization is asked for when the user creates their first watch, so
        // by here it has either been granted or refused. A refusal is not an
        // error: the watches keep evaluating and the screen says plainly that
        // nothing will arrive until notifications are allowed.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            // Groups every notice about one watch into a single thread, so a
            // metric that crosses back and forth over weeks reads as one
            // conversation rather than as unrelated interruptions.
            content.threadIdentifier = "metric-watch.\(alert.watchID)"

            let request = UNNotificationRequest(
                // Unique per firing rather than per watch: iOS replaces a
                // request that reuses an identifier, which would silently
                // swallow the history of a metric that has crossed twice.
                identifier: "metric-watch.\(alert.watchID).\(UUID().uuidString)",
                content: content,
                // No trigger: the wake that produced this snapshot is already
                // the schedule. Anything else would deliver a number that was
                // current hours before it arrived.
                trigger: nil
            )

            do {
                try await center.add(request)
            } catch {
                log.notice("Could not post a metric alert.")
            }
        }
    }
}

/// The user's watch list, and the one moment this app asks to notify them.
///
/// Deliberately shaped like `FlagToggleController`: the view owns one of these,
/// every mutation goes through it, and the App Group file is the only source of
/// truth — the background wake reads the same file without this class existing.
@MainActor
@Observable
final class MetricWatchController {

    private(set) var watches: [MetricWatch] = []
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Set only when the system itself refused to answer, which is rare enough
    /// that a generic "something went wrong" would be useless.
    private(set) var authorizationError: String?

    private let store: SharedSnapshotStore

    init(store: SharedSnapshotStore = .shared) {
        self.store = store
        self.watches = store.metricWatches()
    }

    /// The metrics a watch can be created against.
    ///
    /// The snapshot is the source of truth for what is watchable, not the API: a
    /// picker that queried PostHog could offer an insight the background wake
    /// never reduces to a metric, and that watch could then never fire.
    var watchableMetrics: [SharedSnapshot.Metric] {
        store.loadOrNil()?.metrics ?? []
    }

    var snapshotCapturedAt: Date? { store.loadOrNil()?.capturedAt }

    func reload() {
        watches = store.metricWatches()
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current()
            .notificationSettings()
            .authorizationStatus
    }

    func add(metricID: String, title: String, condition: MetricWatch.Condition) async {
        watches.append(
            MetricWatch(
                id: UUID().uuidString,
                metricID: metricID,
                title: title,
                condition: condition
            )
        )
        persist()
        await requestAuthorizationIfNeeded()
    }

    func setEnabled(_ isEnabled: Bool, id: String) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        watches[index].isEnabled = isEnabled
        persist()
        // The latch is deliberately left alone. Pausing a watch mid-incident and
        // resuming it later must not replay the notification the user muted.
    }

    func delete(id: String) {
        watches.removeAll { $0.id == id }
        persist()
    }

    /// Asks for permission the first time the user has actually said they want
    /// to be told something.
    ///
    /// iOS grants exactly one prompt. Spending it at launch — before the user
    /// has expressed any interest in notifications, on a screen that hasn't
    /// explained what they would be for — is how an app ends up permanently
    /// unable to deliver the feature it was denied for.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }

        do {
            // No badge: nothing in this app counts unread anything, and asking
            // for a permission that is never exercised is a reason to say no.
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            authorizationError = error.localizedDescription
        }
        await refreshAuthorization()
    }

    private func persist() {
        try? store.writeMetricWatches(watches)
    }
}
