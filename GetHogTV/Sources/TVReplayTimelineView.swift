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
/// A plain value rather than an `@Observable`: the view owns the value while it
/// incrementally tracks archive authority and delivery cursors. Keeping that
/// state in a struct makes each delivery transition testable with synthetic
/// event lists.
struct TVReplayTimelineModel: Equatable {

    /// How many segments the strip is divided into.
    ///
    /// A fixed count rather than a fixed segment length, so a 40-second session
    /// and a 40-minute one both fill the screen. 48 is dense enough to show
    /// where the bursts were at 1,920pt and coarse enough that a single event
    /// does not become a bar nobody can see.
    static let bucketCount = 48

    private(set) var buckets: [TVActivityBucket]
    private(set) var totalEvents: Int
    private(set) var consoleErrors: Int
    private(set) var consoleWarnings: Int
    private(set) var failedRequests: Int
    private(set) var requests: Int
    private(set) var bufferedSeconds: TimeInterval

    private var networkIDs: Set<String>
    private var origin: Date?
    private var archiveCursor: ReplayArchiveDeliveryCursor?
    private var authority: Authority?

    private struct Authority: Equatable {
        let loaderID: ObjectIdentifier
        let recordingID: String
        let origin: Date?
        let duration: TimeInterval
    }

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
        var uniqueNetwork: [ReplayNetworkEntry] = []
        var networkIDs: Set<String> = []
        for entry in diagnostics.network where networkIDs.insert(entry.id).inserted {
            uniqueNetwork.append(entry)
        }
        self.networkIDs = networkIDs
        self.origin = origin
        archiveCursor = nil
        authority = nil
        totalEvents = events.count
        consoleErrors = diagnostics.consoleCount(.error)
        consoleWarnings = diagnostics.consoleCount(.warn)
        failedRequests = uniqueNetwork.count(where: \.isFailure)
        requests = uniqueNetwork.count
        bufferedSeconds = duration

        guard let origin, duration > 0 else {
            // No division by zero, and no single bucket standing in for a
            // duration nobody measured. An empty strip is what the view reads
            // as "nothing to draw yet".
            buckets = []
            return
        }

        let width = Self.bucketWidth(duration: duration)
        var weights = [Int](repeating: 0, count: Self.bucketCount)
        var errors = [Bool](repeating: false, count: Self.bucketCount)
        var failures = [Bool](repeating: false, count: Self.bucketCount)

        let originMillis = origin.timeIntervalSince1970 * 1_000
        for event in events where event.type == 3 {
            guard let index = Self.slot(
                for: (event.timestamp - originMillis) / 1_000,
                duration: duration
            ) else { continue }
            weights[index] += 1
        }
        for entry in diagnostics.console where entry.level == .error {
            guard let index = Self.slot(
                for: entry.timestamp.timeIntervalSince(origin),
                duration: duration
            ) else { continue }
            errors[index] = true
        }
        for entry in uniqueNetwork where entry.isFailure {
            guard let index = Self.slot(
                for: entry.start.timeIntervalSince(origin),
                duration: duration
            ) else { continue }
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

    /// Consumes the loader's delivery ledger rather than its accumulated
    /// archive. A stable authority receives only the batches after
    /// `archiveCursor`, so each event and diagnostic is reduced once. A retry,
    /// backfill that moves the origin, replacement loader, recording change, or
    /// provisional-duration change invalidates the cursor and asks the ledger
    /// for one complete `.restart` delivery instead.
    @MainActor
    mutating func ingest(loader: ReplayLoader, recording: SessionRecording) {
        let nextOrigin = loader.replayStart ?? recording.startTime
        let nextDuration = recording.recordingDuration ?? loader.bufferedSeconds
        let nextAuthority = Authority(
            loaderID: ObjectIdentifier(loader),
            recordingID: recording.id,
            origin: nextOrigin,
            duration: nextDuration
        )

        if authority != nextAuthority {
            archiveCursor = nil
        }

        let delivery = loader.archiveDelivery(after: archiveCursor)
        apply(delivery, origin: nextOrigin, duration: nextDuration)
        archiveCursor = delivery.cursor
        authority = nextAuthority
    }

    /// Applies an exactly-once delivery. `.append` touches only the delivered
    /// events; `.restart` is a complete archive and replaces every aggregate.
    mutating func apply(
        _ delivery: ReplayArchiveDelivery,
        origin: Date?,
        duration: TimeInterval
    ) {
        let deliveredDiagnostics = ReplayDiagnostics.extract(from: delivery.events)
        guard delivery.mode == .append else {
            self = TVReplayTimelineModel(
                events: delivery.events,
                diagnostics: deliveredDiagnostics,
                origin: origin,
                duration: duration
            )
            return
        }

        // `ingest` invalidates the cursor before asking for a delivery when the
        // axis changes, so an append always belongs to the buckets already on
        // screen. Keeping this check local prevents a future caller from
        // silently folding a delta into a differently based timeline.
        guard self.origin == origin, bufferedSeconds == duration else {
            assertionFailure("A replay timeline append requires a stable authority")
            return
        }

        totalEvents += delivery.events.count
        consoleErrors += deliveredDiagnostics.consoleCount(.error)
        consoleWarnings += deliveredDiagnostics.consoleCount(.warn)

        var newFailedRequests: [ReplayNetworkEntry] = []
        for entry in deliveredDiagnostics.network where networkIDs.insert(entry.id).inserted {
            requests += 1
            if entry.isFailure {
                failedRequests += 1
                newFailedRequests.append(entry)
            }
        }

        guard let origin, duration > 0 else { return }
        let originMillis = origin.timeIntervalSince1970 * 1_000
        var updated = buckets

        for event in delivery.events where event.type == 3 {
            guard let index = Self.slot(
                for: (event.timestamp - originMillis) / 1_000,
                duration: duration
            ) else { continue }
            updated[index] = updated[index].addingActivity()
        }
        for entry in deliveredDiagnostics.console where entry.level == .error {
            guard let index = Self.slot(
                for: entry.timestamp.timeIntervalSince(origin),
                duration: duration
            ) else { continue }
            updated[index] = updated[index].markingConsoleError()
        }
        for entry in newFailedRequests {
            guard let index = Self.slot(
                for: entry.start.timeIntervalSince(origin),
                duration: duration
            ) else { continue }
            updated[index] = updated[index].markingFailedRequest()
        }
        buckets = updated
    }

    private static func bucketWidth(duration: TimeInterval) -> TimeInterval {
        duration / Double(bucketCount)
    }

    private static func slot(for offset: TimeInterval, duration: TimeInterval) -> Int? {
        guard offset >= 0, duration > 0 else { return nil }
        let raw = Int(offset / bucketWidth(duration: duration))
        // The final instant belongs to the final bucket rather than to one
        // past the end — an event exactly on the duration is in the recording,
        // not after it.
        return min(raw, bucketCount - 1)
    }
}

private extension TVActivityBucket {
    func addingActivity() -> Self {
        Self(
            index: index,
            start: start,
            weight: weight + 1,
            hasConsoleError: hasConsoleError,
            hasFailedRequest: hasFailedRequest
        )
    }

    func markingConsoleError() -> Self {
        Self(
            index: index,
            start: start,
            weight: weight,
            hasConsoleError: true,
            hasFailedRequest: hasFailedRequest
        )
    }

    func markingFailedRequest() -> Self {
        Self(
            index: index,
            start: start,
            weight: weight,
            hasConsoleError: hasConsoleError,
            hasFailedRequest: true
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
    let onRetry: () -> Void

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
        // The revision says a delivery is available; `model` owns the cursor
        // that turns it into either an exactly-once delta or a full restart.
        // Loader identity and recording identity cover SwiftUI reusing this
        // view for a different archive whose revision happens to be equal.
        .task(id: updateID) {
            model.ingest(loader: loader, recording: recording)
        }
    }

    private var updateID: UpdateID {
        UpdateID(
            loaderID: ObjectIdentifier(loader),
            recordingID: recording.id,
            archiveRevision: loader.archiveDeliveryRevision
        )
    }

    private struct UpdateID: Equatable {
        let loaderID: ObjectIdentifier
        let recordingID: String
        let archiveRevision: Int
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
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
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
