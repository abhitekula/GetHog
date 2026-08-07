import Charts
import GetHogKit
import GetHogUI
import SwiftUI

/// One segment of a recording's duration, with how much happened in it.
struct TVActivityBucket: Identifiable, Equatable {
    /// Position in the strip, 0-based. Also the `Identifiable` id, because a
    /// bucket is defined by where it sits.
    let index: Int
    /// Seconds from the recording's origin at which this segment starts.
    let start: TimeInterval
    /// How many incremental rrweb events (`type == 3`) landed in it — the DOM
    /// mutations, scrolls, moves and inputs that are what "activity" means in a
    /// replay. Full snapshots and meta events are excluded deliberately: there
    /// is one of each at the start of every range, so counting them would draw
    /// a spike at every blob boundary that no user did anything to cause.
    let weight: Int
    /// A console line at `.error` fell in this segment.
    let hasConsoleError: Bool
    /// A request with a 4xx/5xx status fell in this segment.
    let hasFailedRequest: Bool

    var id: Int { index }
}

/// What the TV draws where the other platforms draw a player.
///
/// A plain value rather than an `@Observable`: everything here is derived from
/// inputs the loader already has, so there is no state to own, and a struct is
/// what lets the bucketing be tested against a synthetic event list.
struct TVReplayTimelineModel: Equatable {

    /// How many segments the strip is divided into.
    ///
    /// A fixed count rather than a fixed segment length, so a 40-second session
    /// and a 40-minute one both fill the screen. 48 is dense enough to show
    /// where the bursts were at 1,920pt and coarse enough that a single event
    /// does not become a bar nobody can see.
    static let bucketCount = 48

    let buckets: [TVActivityBucket]
    let totalEvents: Int
    let consoleErrors: Int
    let consoleWarnings: Int
    let failedRequests: Int
    let requests: Int
    let bufferedSeconds: TimeInterval

    /// - Parameters:
    ///   - origin: when the recording's clock starts. `nil` means the loader has
    ///     not parsed a first event yet, which is not the same as a
    ///     zero-length recording — both yield no buckets, and the view says so
    ///     differently.
    ///   - duration: the recording's length in seconds.
    init(
        events: [SnapshotEvent],
        diagnostics: ReplayDiagnostics,
        origin: Date?,
        duration: TimeInterval
    ) {
        totalEvents = events.count
        consoleErrors = diagnostics.consoleCount(.error)
        consoleWarnings = diagnostics.consoleCount(.warn)
        failedRequests = diagnostics.failureCount
        requests = diagnostics.network.count
        bufferedSeconds = duration

        guard let origin, duration > 0 else {
            // No division by zero, and no single bucket standing in for a
            // duration nobody measured. An empty strip is what the view reads
            // as "nothing to draw yet".
            buckets = []
            return
        }

        let width = duration / Double(Self.bucketCount)
        var weights = [Int](repeating: 0, count: Self.bucketCount)
        var errors = [Bool](repeating: false, count: Self.bucketCount)
        var failures = [Bool](repeating: false, count: Self.bucketCount)

        func slot(for offset: TimeInterval) -> Int? {
            guard offset >= 0 else { return nil }
            let raw = Int(offset / width)
            // The final instant belongs to the final bucket rather than to one
            // past the end — an event exactly on the duration is in the
            // recording, not after it.
            return min(raw, Self.bucketCount - 1)
        }

        let originMillis = origin.timeIntervalSince1970 * 1_000
        for event in events where event.type == 3 {
            guard let index = slot(for: (event.timestamp - originMillis) / 1_000) else { continue }
            weights[index] += 1
        }
        for entry in diagnostics.console where entry.level == .error {
            guard let index = slot(for: entry.timestamp.timeIntervalSince(origin)) else { continue }
            errors[index] = true
        }
        for entry in diagnostics.network where entry.isFailure {
            guard let index = slot(for: entry.start.timeIntervalSince(origin)) else { continue }
            failures[index] = true
        }

        buckets = (0..<Self.bucketCount).map { index in
            TVActivityBucket(
                index: index,
                start: Double(index) * width,
                weight: weights[index],
                hasConsoleError: errors[index],
                hasFailedRequest: failures[index]
            )
        }
    }

    /// Nothing loaded yet — what the screen holds before the first ingest.
    static let empty = TVReplayTimelineModel(
        events: [],
        diagnostics: ReplayDiagnostics(),
        origin: nil,
        duration: 0
    )

    /// Reads the loader the way the screen reads it.
    ///
    /// **This composition is the thing that needed testing, and its absence is
    /// how a doubling bug got past nine passing tests.** Every test in
    /// `TVReplayTimelineModelTests` hands the initialiser above an explicit
    /// array, so not one of them could see that the *caller* was assembling
    /// that array wrongly.
    ///
    /// `archivedEvents` alone, never `archivedEvents + pending`. `pending` is
    /// not the remainder of the archive — it is a second copy of the events
    /// queued for the web player, which `ingest` fills alongside the archive
    /// (`ReplayLoader:396` assigns it the whole archive on a restart; `:405`
    /// appends the same batch just merged at `:389`). Its only drain,
    /// `drainPendingDelivery()`, is called from `ReplayPlayerView` — a file
    /// **not compiled into this target** — so on tvOS `pending` is never
    /// emptied and stays permanently equal to `archivedEvents`. Adding the two
    /// reported exactly twice the events that existed, and doubled every
    /// bucket weight against its own documented contract.
    /// `@MainActor` because `ReplayLoader` is: the reads below cross no
    /// isolation boundary, they happen where the loader already lives.
    @MainActor
    init(loader: ReplayLoader, recording: SessionRecording) {
        self.init(
            events: loader.archivedEvents,
            diagnostics: loader.diagnostics,
            origin: loader.replayStart ?? recording.startTime,
            duration: recording.recordingDuration ?? loader.bufferedSeconds
        )
    }
}

/// The session's replay, as much of it as an Apple TV can honestly show.
///
/// There is no player here and this does not pretend otherwise: WebKit is not
/// in the tvOS SDK, so `ReplayPlayerView` is not compiled into this target at
/// all. What *is* available is everything that view's loader already fetches
/// and parses — the rrweb event stream and the console and network lines
/// extracted from it — so the recording is drawn as a shape over time rather
/// than played back.
///
/// Non-interactive by design. There is nothing to seek to, so nothing offers a
/// seek; the strip is decorative and the counts beneath it are the content.
struct TVReplayTimelineView: View {
    let recording: SessionRecording
    let loader: ReplayLoader

    /// Held rather than recomputed in `body`.
    ///
    /// This was a computed property, which meant a full copy of the event array
    /// and three walks of it on **every observation tick** — and `ReplayLoader`
    /// publishes once per ingested blob range, so a long recording paid that
    /// O(n) through the whole load. `Export.swift`'s `InsightShareMenu` names
    /// this exact shape as a defect ("`encode` answered it by building the
    /// entire file, during `body`, on every layout pass"); this is the same
    /// mistake with a bigger array.
    @State private var model = TVReplayTimelineModel.empty

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CardHeader(title: "Replay activity", systemImage: "waveform.path.ecg")
                availability
            }
        }
        // `archiveDeliveryRevision` is the loader's own "the archive changed"
        // counter: `ingest` bumps it after every merge and `reset()` bumps it
        // too, so a retry recomputes rather than showing the old shape. Every
        // other input this model reads — `replayStart`, `bufferedSeconds`,
        // `diagnostics` — is written by the same two methods, so one key
        // covers all of them.
        .task(id: loader.archiveDeliveryRevision) {
            model = TVReplayTimelineModel(loader: loader, recording: recording)
        }
    }

    @ViewBuilder
    private var availability: some View {
        switch loader.availability {
        case .idle, .preparing:
            HStack(spacing: Theme.Space.s) {
                ProgressView()
                Text("Loading the recording…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
            }

        case .mobileOnly:
            // The same words the player's notice uses on every other platform.
            // A mobile recording is not a thing this app declines to render on
            // the TV specifically; it is a thing rrweb cannot render anywhere.
            notice(
                "Mobile session",
                detail: "This recording was captured by a mobile SDK, which this app doesn't replay. Open it in PostHog on a computer to watch it."
            )

        case .noData:
            notice("No replay data", detail: "This session was recorded without a replay, or it has expired.")

        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                notice("Couldn't load the replay", detail: "The recording is on PostHog; only this device's copy failed.")
                FailureDetail(text: reason)
            }

        case .ready:
            timeline
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if model.buckets.isEmpty {
                Text("The recording has no measured duration to lay activity over.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
            } else {
                strip(model)
                incidents(model)
            }

            StatStrip {
                MetricTile(label: "Events", value: Double(model.totalEvents).compactFormatted, compact: true)
                MetricTile(label: "Console errors", value: Double(model.consoleErrors).compactFormatted, compact: true)
                MetricTile(label: "Console warnings", value: Double(model.consoleWarnings).compactFormatted, compact: true)
                MetricTile(label: "Failed requests", value: Double(model.failedRequests).compactFormatted, compact: true)
                MetricTile(label: "Requests", value: Double(model.requests).compactFormatted, compact: true)
            }
        }
    }

    private func strip(_ model: TVReplayTimelineModel) -> some View {
        Chart(model.buckets) { bucket in
            BarMark(
                x: .value("Segment", bucket.index),
                y: .value("Activity", bucket.weight)
            )
            .foregroundStyle(SeriesPalette.color(at: 0))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 160)
        // Decorative: the counts below say everything this shape says, in
        // words, and a bar chart with no axes has no reading order to offer.
        .accessibilityHidden(true)
    }

    /// Where the trouble was, on the same axis as the activity above it.
    @ViewBuilder
    private func incidents(_ model: TVReplayTimelineModel) -> some View {
        let marked = model.buckets.filter { $0.hasConsoleError || $0.hasFailedRequest }
        if !marked.isEmpty {
            Chart(marked) { bucket in
                RuleMark(x: .value("Segment", bucket.index))
                    .foregroundStyle(
                        bucket.hasConsoleError ? Theme.Status.criticalInk : Theme.Status.warningInk
                    )
            }
            .chartXScale(domain: 0...(TVReplayTimelineModel.bucketCount - 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 28)
            .accessibilityHidden(true)

            Text(Self.incidentSummary(model))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    static func incidentSummary(_ model: TVReplayTimelineModel) -> String {
        let errors = model.buckets.count(where: \.hasConsoleError)
        let failures = model.buckets.count(where: \.hasFailedRequest)
        var parts: [String] = []
        if errors > 0 {
            parts.append("console errors in \(errors) \(errors == 1 ? "segment" : "segments")")
        }
        if failures > 0 {
            parts.append("failed requests in \(failures) \(failures == 1 ? "segment" : "segments")")
        }
        return "Marked: " + parts.joined(separator: ", ") + "."
    }

    private func notice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.Typography.body.weight(.semibold))
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }
}
