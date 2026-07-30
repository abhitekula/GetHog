import AppIntents
import Foundation
import GetHogKit
import SwiftUI
import WidgetKit

/// The widget extension's entire view of the outside world.
///
/// **This extension never calls the PostHog API.** Rate limits are billed per
/// *organisation* and that budget is shared with the user's own production
/// integrations — a few installed widgets, each waking on its own schedule,
/// would multiply request volume against an allowance that isn't ours to spend,
/// from a process the user never launched. The app fetches, reduces the result
/// to `SharedSnapshot`, and writes it to the App Group container; everything
/// here is a read of that file.
///
/// The consequence is deliberate: when the snapshot is missing or old, the
/// widget says so and offers to open the app. It does not quietly go and get
/// fresher data.
enum WidgetCache {

    static var store: SharedSnapshotStore { .shared }

    static func snapshot() -> SharedSnapshot? { store.loadOrNil() }

    /// Metrics with the configured one first, then the rest in snapshot order —
    /// the multi-metric families fill from the same list, so a user who picked a
    /// metric sees it in the lead position on every size.
    static func metrics(preferring id: String?) -> [SharedSnapshot.Metric] {
        guard let snapshot = snapshot() else { return [] }
        guard let id, let chosen = snapshot.metric(id: id) else { return snapshot.metrics }
        return [chosen] + snapshot.metrics.filter { $0.id != id }
    }

    /// Only flags the user opted in to. Outside the app there is no confirmation
    /// dialog to answer, so a flag stays invisible to widgets and Control Center
    /// until the user deliberately allows it.
    static func quickToggleFlags() -> [SharedSnapshot.Flag] {
        snapshot()?.quickToggleFlags ?? []
    }

    static func quickToggleFlag(id: Int?) -> SharedSnapshot.Flag? {
        let candidates = quickToggleFlags()
        guard let id else { return candidates.first }
        // The lookup goes through the opted-in list, not the full flag list: a
        // configuration saved while a flag was allowed must stop working the
        // moment the user revokes that permission.
        return candidates.first { $0.id == id }
    }

    // MARK: Sample data

    /// Used for placeholders, the widget gallery, and previews. Plausible but
    /// obviously generic, so nobody mistakes gallery art for their own numbers.
    static let sample = SharedSnapshot(
        projectID: 0,
        projectName: "Your project",
        metrics: [
            .init(
                id: "1", title: "Active users", value: 12_480, unit: nil, previous: 10_920,
                sparkline: [8_900, 9_400, 10_100, 10_920, 11_600, 12_480]
            ),
            .init(
                id: "2", title: "Signups", value: 318, unit: nil, previous: 344,
                sparkline: [402, 380, 355, 344, 330, 318]
            ),
            .init(id: "3", title: "Bounce rate", value: 41.2, unit: "%", previous: 44.9, sparkline: []),
            .init(
                id: "4", title: "Errors", value: 27, unit: nil, previous: 27,
                sparkline: [31, 29, 28, 27, 27, 27]
            ),
            .init(id: "5", title: "Revenue", value: 8_640, unit: "$", previous: 7_900, sparkline: []),
            .init(id: "6", title: "Sessions", value: 44_120, unit: nil, previous: nil, sparkline: []),
        ],
        flags: [
            .init(id: 1, key: "new-onboarding", active: true, quickToggleAllowed: true),
            .init(id: 2, key: "beta-search", active: false, quickToggleAllowed: true),
        ],
        capturedAt: Date()
    )
}

// MARK: - Refresh policy

/// How often the extension asks WidgetKit to call the provider again.
///
/// WidgetKit gives each widget a *daily* budget of refreshes (roughly 40–70,
/// depending on how the user actually looks at the widget). Asking every 15
/// minutes would want ~96 a day, so the system would silently throttle us and
/// the cadence would become unpredictable.
///
/// Instead each timeline carries an hour of entries fifteen minutes apart. The
/// values are identical — they all come from the same snapshot — but the entry
/// dates advance, so the "Updated 20 min ago" line stays truthful without the
/// provider being woken. That is one provider call an hour, comfortably inside
/// the budget, and it leaves headroom for the reload the app triggers whenever
/// it writes a fresher snapshot. That reload, not this timer, is what actually
/// makes a widget current.
///
/// `.after` and never `.atEnd`: `.atEnd` on a timeline whose entries are already
/// in the past turns into a reload loop that burns the whole day's budget in
/// minutes.
enum WidgetRefresh {

    static let step: TimeInterval = 15 * 60
    static let horizon: TimeInterval = 60 * 60

    static func entryDates(from start: Date) -> [Date] {
        stride(from: 0, to: horizon, by: step).map { start.addingTimeInterval($0) }
    }

    static func nextReload(from start: Date) -> Date {
        start.addingTimeInterval(horizon)
    }

    static func timeline<E: TimelineEntry>(from start: Date, entry: (Date) -> E) -> Timeline<E> {
        Timeline(entries: entryDates(from: start).map(entry), policy: .after(nextReload(from: start)))
    }
}

// MARK: - Freshness

/// How old the rendered numbers are, in a form the views can state plainly.
struct WidgetFreshness: Equatable {

    /// `nil` before the app has ever synced.
    let capturedAt: Date?
    let now: Date

    var age: TimeInterval? {
        guard let capturedAt else { return nil }
        return max(0, now.timeIntervalSince(capturedAt))
    }

    var isStale: Bool {
        guard let age else { return true }
        return age > SharedSnapshot.defaultStaleTolerance
    }

    /// Compact enough for a widget footer: "now", "20m", "3h", "2d".
    var shortLabel: String {
        guard let age else { return "never" }
        switch age {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(age / 60))m"
        case ..<86_400: return "\(Int(age / 3_600))h"
        default: return "\(Int(age / 86_400))d"
        }
    }

    /// Spelled out for VoiceOver, which should not have to read "3h" aloud.
    var spokenLabel: String {
        guard let age else { return "not synced yet" }
        switch age {
        case ..<60: return "updated just now"
        case ..<3_600: return "updated \(Int(age / 60)) minutes ago"
        case ..<86_400: return "updated \(Int(age / 3_600)) hours ago"
        default: return "updated \(Int(age / 86_400)) days ago"
        }
    }
}

// MARK: - Hand-off to the app

/// The only "refresh" a widget can honestly offer: open the app, which holds the
/// credentials, the rate-limit governor, and somewhere to show a failure.
struct RefreshInAppIntent: AppIntent {

    static var title: LocalizedStringResource { "Open GetHog to sync" }
    static var description: IntentDescription {
        IntentDescription("Opens GetHog so it can refresh the data your widgets show.")
    }

    /// The whole point. The extension has no business fetching.
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        WidgetCache.store.requestOpen(PendingOpen(metricID: nil, requestedAt: Date()))
        return .result()
    }
}

extension SharedSnapshotStore {

    /// Best-effort: a failed hand-off means the app opens on its last screen
    /// instead of the requested one, which is not worth surfacing an error for
    /// in a process that has no UI.
    func requestOpen(_ open: PendingOpen) {
        try? enqueue(open)
    }

    func requestFlagWrite(_ write: PendingFlagWrite) {
        try? enqueue(write)
    }
}
