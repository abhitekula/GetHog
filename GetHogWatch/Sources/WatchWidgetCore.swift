import Foundation
import GetHogKit
import WidgetKit

// The complications' whole brain, with no SwiftUI in it.
//
// It lives in the **app** target and is compiled into the appex a second time,
// because on this platform that is the only way it can be checked. The watch
// widget extension is a separate binary that `GetHogWatchTests` does not
// compile — the same fact that pushed the iOS scoring rule into the kit, met
// again on a fence that cannot touch the kit. So the derivation lives here,
// where a test can run it without a watch face, and `project.yml` lists these
// two files in the appex's sources as well; each binary carries its own copy.
//
// Nothing here draws. `WatchWidgetViews.swift` in the extension does the
// drawing, and it holds every helper that needs `SwiftUI` — a separation this
// package already pays for once (see `WatchSparklineMath`, extracted because
// naming a SwiftUI `View` type from `GetHogWatchTests` crashes the watchOS
// test host).

// MARK: - Cache

/// The complication process's entire view of the outside world.
///
/// **This extension never calls the PostHog API.** Rate limits are billed per
/// *organisation* and that budget is shared with the user's own production
/// integrations — a handful of complications on a watch face, each waking on
/// its own schedule, would multiply request volume against an allowance that
/// isn't ours to spend, from a process the user never launched. The watch app
/// fetches, reduces the result to `SharedSnapshot`, and writes it to the
/// watch-local App Group container; everything here is a read of those files.
///
/// The consequence is deliberate: when a file is missing or old, the
/// complication says so and says how old. It does not quietly go and get
/// fresher data.
struct WatchWidgetCache {

    let store: SharedSnapshotStore

    init(store: SharedSnapshotStore = .shared) {
        self.store = store
    }

    func snapshot() -> SharedSnapshot? { store.loadOrNil() }

    /// The activity feed, from its **own** file with its **own** capture time.
    ///
    /// Deliberately not folded into the snapshot's age: a wake whose events
    /// query alone failed keeps the feed it had, so the two stamps drift apart
    /// on purpose. Anything drawn from this must be aged by
    /// `ActivityFeed.capturedAt`, never by `SharedSnapshot.capturedAt`.
    func activity() -> ActivityFeed? { WatchActivity.read(from: store) }

    /// The user's metric watches, written by `WatchSessionListener` from the
    /// phone hand-off. Read for firing state and for ranking only — this
    /// process posts no notification and writes no latch.
    func watches() -> [MetricWatch] { store.metricWatches() }
}

// MARK: - Freshness

/// How old the rendered numbers are, in a form the views can state plainly.
///
/// A twin of the iOS `WidgetFreshness`, which lives in `GetHogWidgets/` — an
/// iOS extension target this one cannot import, and which cannot import this.
/// Unifying the two into the kit is the right eventual home and is outside this
/// task's fence; until then the numbers below are pinned to the same kit
/// constant on both sides, which is the part that must not drift.
struct WatchFreshness: Equatable {

    /// `nil` before the watch has ever synced.
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

    /// Compact enough for a complication: "now", "20m", "3h", "2d".
    var shortLabel: String {
        guard let age else { return "never" }
        switch age {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(age / 60))m"
        case ..<86_400: return "\(Int(age / 3_600))h"
        default: return "\(Int(age / 86_400))d"
        }
    }

    /// Spelled out for VoiceOver, which should not have to read "3h" aloud —
    /// and which is the *only* place the age appears on the circular and corner
    /// faces, where there is no room to draw it.
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

// MARK: - Refresh policy

/// How often the extension asks WidgetKit to call the provider again.
///
/// The iOS `WidgetRefresh` numbers, restated for the wrist and for the same
/// reason: each timeline carries an hour of entries fifteen minutes apart. The
/// values are identical — they all come from one pair of file reads — but the
/// entry dates advance, so the "12m" age label stays truthful without the
/// provider being woken. That is one provider call an hour, and it leaves
/// headroom for the reload the app triggers whenever it writes a fresher
/// snapshot. That reload, not this timer, is what actually makes a
/// complication current.
///
/// `.after` and never `.atEnd`: `.atEnd` on a timeline whose entries are
/// already in the past turns into a reload loop that burns the whole day's
/// budget in minutes.
enum WatchWidgetRefresh {

    static let step: TimeInterval = 15 * 60
    static let horizon: TimeInterval = 60 * 60

    static func entryDates(from start: Date) -> [Date] {
        stride(from: 0, to: horizon, by: step).map { start.addingTimeInterval($0) }
    }

    static func nextReload(from start: Date) -> Date {
        start.addingTimeInterval(horizon)
    }

    static func timeline<E: TimelineEntry>(from start: Date, entry: (Date) -> E) -> Timeline<E> {
        Timeline(
            entries: entryDates(from: start).map(entry),
            policy: .after(nextReload(from: start))
        )
    }
}

// MARK: - Entries

/// Every entry's `relevance` carries a `duration` of one timeline step rather
/// than the default zero. The default means "valid until the next entry", and
/// the *last* entry in a timeline has no next entry: if WidgetKit is late
/// calling the provider back, a stale alarm would keep its rank indefinitely.
/// Expiring with the step makes a claim lapse into silence rather than into a
/// lie. (The rationale is `HealthEntry.relevance`'s on iOS, and it holds here
/// unchanged.)

/// The headline-metric complication's state at one instant.
struct WatchMetricEntry: TimelineEntry, Equatable {
    let date: Date
    let projectName: String
    /// The configured metric first, then the rest. Every family leads with
    /// `metrics.first`; the corner and circular faces draw nothing else.
    let metrics: [SharedSnapshot.Metric]
    /// `nil` until the watch has written its first snapshot.
    let capturedAt: Date?
    /// Computed in the provider, where the watch list is one file read away,
    /// rather than here: an entry is a value WidgetKit copies around and
    /// re-reads, and touching the file system from a property it reads would
    /// turn one read into one per render.
    let relevanceScore: Float

    var primary: SharedSnapshot.Metric? { metrics.first }
    var hasData: Bool { capturedAt != nil && !metrics.isEmpty }
    /// A synced project with nothing to show is a different problem from a
    /// project that has never synced, and it needs different words.
    var isEmptyProject: Bool { capturedAt != nil && metrics.isEmpty }
    var freshness: WatchFreshness { WatchFreshness(capturedAt: capturedAt, now: date) }

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: relevanceScore, duration: WatchWidgetRefresh.step)
    }
}

/// The health complication's state at one instant.
///
/// **Watch-local evaluation only.** The snapshot the watch writes carries no
/// `ingestion` and no `quota` — those are two requests the wrist deliberately
/// does not spend — so `SharedSnapshot.healthVerdict` on it is always
/// `.unchecked`, and rendering that as a verdict would be a claim nobody
/// checked. What this reports is the user's own `MetricWatch` set, evaluated
/// against the cached snapshot at zero cost. The app's error pulse is not here
/// either: it is in-memory in the app process and never persisted, so this
/// process cannot see it and does not pretend to.
struct WatchHealthEntry: TimelineEntry, Equatable {

    /// One firing watch, named the way the wrist will draw it.
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
    }

    let date: Date
    let capturedAt: Date?
    /// Enabled watches this watch knows about — the denominator of "N firing".
    let watchCount: Int
    let firingRows: [Row]
    let relevanceScore: Float

    var hasSynced: Bool { capturedAt != nil }
    var firingCount: Int { firingRows.count }
    var freshness: WatchFreshness { WatchFreshness(capturedAt: capturedAt, now: date) }

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: relevanceScore, duration: WatchWidgetRefresh.step)
    }
}

/// The Smart Stack card's state at one instant.
///
/// Three modes rather than a pile of optionals, because the stack shows one
/// rectangular card and the three things it can say are genuinely different
/// claims: an alert, a glance, and an admission that there is nothing to show.
struct WatchStackEntry: TimelineEntry, Equatable {

    enum Mode: Equatable {
        /// At least one of the user's watches is over its line.
        case alert(title: String, count: Int)
        /// Nothing firing: the headline number and the newest event.
        ///
        /// `eventCapturedAt` is the **feed's** own stamp, not the snapshot's.
        /// The two files are written by different branches of one refresh and a
        /// failed events query leaves the old feed in place; ageing the event
        /// line by the snapshot would silently claim the event was re-read.
        case quiet(
            metricTitle: String?,
            valueText: String?,
            latestEvent: String?,
            eventCapturedAt: Date?
        )
        /// The watch has never written a snapshot.
        case unsynced
    }

    let date: Date
    let capturedAt: Date?
    let mode: Mode
    let relevanceScore: Float

    var freshness: WatchFreshness { WatchFreshness(capturedAt: capturedAt, now: date) }

    /// The event line's age, by the feed's own stamp. `nil` in every mode that
    /// draws no event line.
    var eventFreshness: WatchFreshness? {
        guard case .quiet(_, _, let event, let eventCapturedAt) = mode, event != nil
        else { return nil }
        return WatchFreshness(capturedAt: eventCapturedAt, now: date)
    }

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: relevanceScore, duration: WatchWidgetRefresh.step)
    }
}

// MARK: - Derivation

/// Snapshot plus watch list plus feed, in — entries out. Pure, so every rule
/// below is pinned by `WatchComplicationCoreTests` rather than by looking at a
/// watch face.
enum WatchComplicationCore {

    // MARK: Metric

    /// The configured metric first, then the rest.
    ///
    /// A configuration naming a metric the snapshot no longer holds falls back
    /// to `metrics.first` — the same fallback `WatchModel.headlineMetric`
    /// makes, so the complication and the app's first page lead with the same
    /// number when nothing has been chosen.
    static func ordered(
        _ metrics: [SharedSnapshot.Metric], chosenMetricID: String?
    ) -> [SharedSnapshot.Metric] {
        guard let chosenMetricID,
              let match = metrics.first(where: { $0.id == chosenMetricID })
        else { return metrics }
        return [match] + metrics.filter { $0.id != chosenMetricID }
    }

    static func metricEntry(
        snapshot: SharedSnapshot?,
        chosenMetricID: String?,
        watches: [MetricWatch],
        date: Date
    ) -> WatchMetricEntry {
        guard let snapshot else {
            return WatchMetricEntry(
                date: date, projectName: "GetHog", metrics: [],
                capturedAt: nil, relevanceScore: 0
            )
        }
        let metrics = ordered(snapshot.metrics, chosenMetricID: chosenMetricID)
        return WatchMetricEntry(
            date: date,
            projectName: snapshot.projectName,
            metrics: metrics,
            capturedAt: snapshot.capturedAt,
            // Scored against the metric the faces actually lead with. The score
            // decays with `date`, so the four entries in one timeline rank lower
            // as the snapshot behind them ages, without the provider being woken
            // to say so.
            relevanceScore: SnapshotRelevance.metric(
                metrics.first, in: snapshot, watches: watches, now: date
            )
        )
    }

    // MARK: Health

    /// Which of the user's watches are over their line **in this snapshot**.
    ///
    /// Evaluated with an empty prior breach set, never against
    /// `metric-watch-breaches.json`. That file is anti-spam state: it
    /// deliberately keeps an id whose metric has gone missing, so a
    /// disappearance can never be mistaken for a recovery and buy a second
    /// notification. Reading it here would let a complication claim urgency
    /// about a number the snapshot no longer contains. See
    /// `SnapshotRelevance.isBreaching`, which is careful about exactly this.
    ///
    /// The title is the metric's current name when the snapshot has it and the
    /// watch's saved title when it does not — the rule `WatchHealth.derive`
    /// applies on the Health page, so the two surfaces name a watch the same
    /// way.
    static func firingRows(
        snapshot: SharedSnapshot?, watches: [MetricWatch]
    ) -> [WatchHealthEntry.Row] {
        guard let snapshot else { return [] }
        let enabled = watches.filter(\.isEnabled)
        let breaching = MetricWatchEvaluator.evaluate(
            snapshot: snapshot, watches: enabled, breaching: []
        ).breaching
        return enabled
            .filter { breaching.contains($0.id) }
            .map { watch in
                WatchHealthEntry.Row(
                    id: watch.id,
                    title: snapshot.metric(id: watch.metricID)?.title ?? watch.title
                )
            }
    }

    static func healthEntry(
        snapshot: SharedSnapshot?, watches: [MetricWatch], date: Date
    ) -> WatchHealthEntry {
        WatchHealthEntry(
            date: date,
            capturedAt: snapshot?.capturedAt,
            watchCount: watches.count(where: \.isEnabled),
            firingRows: firingRows(snapshot: snapshot, watches: watches),
            relevanceScore: score(snapshot: snapshot, watches: watches, now: date)
        )
    }

    // MARK: Stack

    static func stackEntry(
        snapshot: SharedSnapshot?,
        watches: [MetricWatch],
        activity: ActivityFeed?,
        date: Date
    ) -> WatchStackEntry {
        let mode: WatchStackEntry.Mode
        if let snapshot {
            let firing = firingRows(snapshot: snapshot, watches: watches)
            if let first = firing.first {
                mode = .alert(title: first.title, count: firing.count)
            } else {
                let headline = snapshot.metrics.first
                mode = .quiet(
                    metricTitle: headline?.title,
                    valueText: headline.map { WatchWidgetNumber.compact($0.value, unit: $0.unit) },
                    latestEvent: activity?.lines.first?.event,
                    // The feed's stamp travels with the line it belongs to.
                    eventCapturedAt: activity?.capturedAt
                )
            }
        } else {
            mode = .unsynced
        }
        return WatchStackEntry(
            date: date,
            capturedAt: snapshot?.capturedAt,
            mode: mode,
            relevanceScore: score(snapshot: snapshot, watches: watches, now: date)
        )
    }

    // MARK: Scoring

    /// The loudest thing the snapshot has to say, on the kit's scale.
    ///
    /// `max` over `SnapshotRelevance.metric` across every cached metric rather
    /// than a second scale of this file's own: the health and stack surfaces
    /// speak for the whole watch list, not for one configured tile, and one
    /// scoring rule that a kit test already runs beats two that agree by
    /// accident. `SnapshotRelevance.health` is deliberately **not** consulted —
    /// it reads `ingestion` and `quota`, which a watch-written snapshot never
    /// carries, so it would return a hard zero on every wrist snapshot and say
    /// nothing at all.
    static func score(snapshot: SharedSnapshot?, watches: [MetricWatch], now: Date) -> Float {
        guard let snapshot else { return 0 }
        return snapshot.metrics.reduce(Float(0)) { best, metric in
            max(best, SnapshotRelevance.metric(metric, in: snapshot, watches: watches, now: now))
        }
    }

    /// The window the Smart Stack should treat this widget as relevant in, for
    /// `WidgetRelevance` — the second, coarser API beside the per-entry score.
    ///
    /// `nil` when nothing is firing or nothing is cached: there is no "alert"
    /// context in `RelevantContext`, so a date interval while firing is the
    /// entire vocabulary available, and offering one while quiet would be this
    /// widget asking for the top of the stack on the strength of existing.
    ///
    /// The interval ends where the *score* would have decayed to nothing —
    /// `capturedAt + SnapshotRelevance.decayHorizon` — so the two relevance
    /// APIs cannot disagree: they are computed from the same firing state and
    /// expire on the same clock. `nil` when that end is not after `now`, since
    /// a `DateInterval` ending in the past claims a relevance already over.
    static func stackRelevanceWindow(
        snapshot: SharedSnapshot?, watches: [MetricWatch], now: Date
    ) -> DateInterval? {
        guard let snapshot,
              !firingRows(snapshot: snapshot, watches: watches).isEmpty
        else { return nil }
        let end = snapshot.capturedAt.addingTimeInterval(SnapshotRelevance.decayHorizon)
        guard end > now else { return nil }
        return DateInterval(start: now, end: end)
    }
}

// MARK: - Numbers

/// A number small enough for a complication.
///
/// `Double.compactFormatted` in GetHogUI is the same idea, but it cannot carry
/// a unit and the wrist's faces have to put "%" and "$" somewhere. The unit
/// rules are the iOS widgets' `WidgetNumber.decorate`, restated: a symbol hugs
/// the number, a word gets a space.
enum WatchWidgetNumber {

    static func compact(_ value: Double, unit: String? = nil) -> String {
        let number: String
        if abs(value) >= 1_000 {
            number = value.formatted(
                .number.notation(.compactName).precision(.fractionLength(0...1))
            )
        } else if value == value.rounded() {
            number = value.formatted(.number.precision(.fractionLength(0)))
        } else {
            number = value.formatted(.number.precision(.fractionLength(0...1)))
        }
        return decorate(number, unit: unit)
    }

    static func full(_ value: Double, unit: String? = nil) -> String {
        decorate(value.formatted(.number.precision(.fractionLength(0...2))), unit: unit)
    }

    private static func decorate(_ number: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return number }
        if unit == "%" { return number + "%" }
        if unit.count == 1, unit.rangeOfCharacter(from: .letters) == nil { return unit + number }
        return "\(number) \(unit)"
    }
}

// MARK: - Sample data

/// Gallery, placeholder and preview data.
///
/// Plausible but obviously generic, so nobody mistakes gallery art for their
/// own numbers — and wholly synthetic, which the repository's fixture-privacy
/// gate enforces on these very files. Project id zero, round values, titles
/// that name nothing real.
enum WatchWidgetSample {

    static let projectName = "Your project"

    static let snapshot = SharedSnapshot(
        projectID: 0,
        projectName: projectName,
        metrics: [
            // `dashboardID` is nil throughout: these are gallery placeholders,
            // and no dashboard exists that they were read from.
            .init(
                id: "1", title: "Active users", value: 12_480, unit: nil, previous: 10_920,
                sparkline: [8_900, 9_400, 10_100, 10_920, 11_600, 12_480], dashboardID: nil
            ),
            .init(
                id: "2", title: "Signups", value: 318, unit: nil, previous: 344,
                sparkline: [402, 380, 355, 344, 330, 318], dashboardID: nil
            ),
            .init(
                id: "3", title: "Bounce rate", value: 41.2, unit: "%", previous: 44.9,
                sparkline: [], dashboardID: nil
            ),
            .init(
                id: "4", title: "Errors", value: 27, unit: nil, previous: 27,
                sparkline: [31, 29, 28, 27, 27, 27], dashboardID: nil
            ),
        ],
        // Empty, and not an oversight: every flag the watch writes carries
        // `quickToggleAllowed: false` (the per-flag opt-in has no watch UI), so
        // no watch complication renders a flag and a sample flag would be
        // gallery art for a surface that does not exist.
        flags: [],
        capturedAt: Date()
    )

    static let activity = ActivityFeed(
        lines: [
            ActivityLine(id: "sample-1", event: "example signup completed", timestamp: nil),
            ActivityLine(id: "sample-2", event: "example checkout submitted", timestamp: nil),
            ActivityLine(id: "sample-3", event: "example feature used", timestamp: nil),
        ],
        capturedAt: Date()
    )

    /// One watch, quiet against the sample. The gallery must not show an alarm:
    /// a firing sample would teach the user that a red card means nothing.
    static let watches: [MetricWatch] = [
        MetricWatch(
            id: "sample-watch-1",
            metricID: "1",
            title: "Active users",
            condition: .above(100_000)
        ),
    ]

    // Every sample entry carries `relevanceScore: 0`, deliberately. These feed
    // the gallery and the redacted placeholder, which are not a ranking — a
    // sample that claimed urgency would be this widget arguing for the top of a
    // stack on data belonging to nobody.

    static func metricEntry(at date: Date = Date()) -> WatchMetricEntry {
        WatchMetricEntry(
            date: date,
            projectName: snapshot.projectName,
            metrics: snapshot.metrics,
            capturedAt: date,
            relevanceScore: 0
        )
    }

    static func healthEntry(at date: Date = Date()) -> WatchHealthEntry {
        WatchHealthEntry(
            date: date,
            capturedAt: date,
            watchCount: watches.count,
            firingRows: [],
            relevanceScore: 0
        )
    }

    static func stackEntry(at date: Date = Date()) -> WatchStackEntry {
        let headline = snapshot.metrics.first
        return WatchStackEntry(
            date: date,
            capturedAt: date,
            mode: .quiet(
                metricTitle: headline?.title,
                valueText: headline.map { WatchWidgetNumber.compact($0.value, unit: $0.unit) },
                latestEvent: activity.lines.first?.event,
                eventCapturedAt: date
            ),
            relevanceScore: 0
        )
    }
}
