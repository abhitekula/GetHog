import Foundation
import Observation
import GetHogKit

/// Streams rrweb snapshot events for one recording.
///
/// This type is the *only* thing in the app that talks to the snapshot
/// endpoints. PostHog documents them as internal and subject to change without
/// notice, so every call is wrapped and every failure resolves to a value of
/// `Availability` — never a thrown error that could unwind the session screen.
/// A break here must cost the player and nothing else.
@MainActor
@Observable
final class ReplayLoader {

    enum Availability: Equatable {
        /// Nothing attempted yet.
        case idle
        /// Listing sources, or waiting for the first chunk to be playable.
        case preparing
        /// Enough data has arrived to construct a player.
        case ready
        /// Recorded by a mobile SDK: the snapshots are in a format PostHog has
        /// not open-sourced a transform for, so there is nothing to try.
        case mobileOnly
        /// The API answered, but there is no stored replay to play.
        case noData
        /// The internal API failed. The message is shown verbatim in a card.
        case unavailable(String)
    }

    // MARK: - Tuning

    /// The endpoint caps a request at 20 blobs and rejects a lone `blob_key`
    /// for `blob_v2`, so every fetch is expressed as a bounded range.
    private static let blobsPerRequest = 20

    /// Seconds of playback kept buffered ahead of the playhead.
    ///
    /// Deliberately *not* conditioned on Wi-Fi vs cellular. Fetching only what
    /// the viewer is about to watch is itself the data-saving mechanism, and
    /// connection-type branching only makes the app behave differently for
    /// reasons the user can't see. A 54-minute session is 43 blobs — three
    /// requests — and most viewers watch far less than all of it.
    static let prefetchLead: TimeInterval = 60

    /// How much to have in hand before playback starts.
    private static let initialCoverage: TimeInterval = 30

    // MARK: - Observed state

    private(set) var availability: Availability = .idle
    private(set) var isFetching = false

    /// Snapshot events fetched but not yet handed to the web player.
    private(set) var pending: [SnapshotEvent] = []
    var pendingCount: Int { pending.count }

    /// Snapshot events retained for the full-screen replay renderer.
    private(set) var archivedEvents: [SnapshotEvent] = []
    var archivedEventCount: Int { archivedEvents.count }

    /// Wall-clock time of the first snapshot event. rrweb measures its offsets
    /// from this instant, so it — not `recording.start_time` — is what timeline
    /// entries must be rebased against before seeking.
    private(set) var replayStart: Date?

    /// Seconds of session covered by everything fetched so far.
    private(set) var bufferedSeconds: TimeInterval = 0

    /// Console output and network timing, read out of the same events.
    ///
    /// This is free. rrweb carries both as `type: 6` plugin events inside the
    /// blobs already being fetched to render frames, so the console and network
    /// panes add no request and consume none of the organisation-wide rate
    /// limit. They are accumulated here rather than in the view because
    /// `pending` is drained into the web player and then discarded.
    private(set) var diagnostics = ReplayDiagnostics()

    private(set) var loadedRangeCount = 0
    private(set) var rangeCount = 0

    /// Set when a *later* chunk fails after playback already started. The player
    /// keeps running on what it has; this is surfaced as a footnote, not a
    /// full-screen failure.
    private(set) var streamingError: String?

    // MARK: - Internals

    @ObservationIgnored private var ranges: [BlobRange] = []
    @ObservationIgnored private var nextRangeIndex = 0
    @ObservationIgnored private var targetCoverage: TimeInterval = 0
    @ObservationIgnored private var firstTimestampMS: Double?
    @ObservationIgnored private var lastTimestampMS: Double?
    @ObservationIgnored private var hasFullSnapshot = false
    @ObservationIgnored private var totalEventCount = 0
    @ObservationIgnored private var loadGeneration = 0

    @ObservationIgnored private var client: PostHogClient?
    @ObservationIgnored private var projectID: Int?
    @ObservationIgnored private var recordingID: String?

    var isComplete: Bool { !ranges.isEmpty && nextRangeIndex >= ranges.count }

    /// rrweb needs at least two events and one full snapshot before it can paint
    /// a frame, so booting earlier than this just throws inside the web view.
    var canBoot: Bool { hasFullSnapshot && totalEventCount >= 2 }

    var progressFraction: Double {
        guard rangeCount > 0 else { return 0 }
        return Double(loadedRangeCount) / Double(rangeCount)
    }

    // MARK: - Lifecycle

    func start(client: PostHogClient, projectID: Int, recording: SessionRecording) async {
        guard availability == .idle else { return }
        let generation = loadGeneration

        // The cheapest possible check comes first: mobile recordings are never
        // attempted, so the user gets an explanation instead of a spinner that
        // resolves into a broken player.
        guard recording.isReplayable else {
            availability = .mobileOnly
            return
        }

        self.client = client
        self.projectID = projectID
        self.recordingID = recording.id
        availability = .preparing

        do {
            let data = try await client.data(
                for: PostHogAPI.snapshotSources(projectID: projectID, recordingID: recording.id)
            )
            guard generation == loadGeneration else { return }
            let listing = try SnapshotSourceListing.decode(from: data)

            guard !listing.isRealtimeOnly else {
                // An in-progress session with nothing flushed to blob storage.
                availability = .noData
                return
            }

            ranges = listing.blobRanges(maxPerRequest: Self.blobsPerRequest)
            rangeCount = ranges.count
            guard !ranges.isEmpty else {
                availability = .noData
                return
            }

            targetCoverage = Self.initialCoverage
            await pump(generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            availability = .unavailable(Self.describe(error))
        }
    }

    /// Requests that the buffer reach `seconds` of session time. Cheap to call
    /// often — it collapses into the in-flight fetch when one is running.
    func ensureCoverage(upTo seconds: TimeInterval) {
        let generation = loadGeneration
        targetCoverage = max(targetCoverage, seconds)
        guard !isFetching, !isComplete, streamingError == nil else { return }
        guard availability == .ready || availability == .preparing else { return }
        Task { await pump(generation: generation) }
    }

    /// Hands over everything fetched since the last call.
    func drainPending() -> [SnapshotEvent] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    /// Clears all progress so a failed load can be retried from scratch.
    func reset() {
        loadGeneration &+= 1
        availability = .idle
        isFetching = false
        pending = []
        archivedEvents.removeAll(keepingCapacity: false)
        diagnostics = ReplayDiagnostics()
        replayStart = nil
        bufferedSeconds = 0
        loadedRangeCount = 0
        rangeCount = 0
        streamingError = nil
        ranges = []
        nextRangeIndex = 0
        targetCoverage = 0
        firstTimestampMS = nil
        lastTimestampMS = nil
        hasFullSnapshot = false
        totalEventCount = 0
    }

    // MARK: - Fetching

    /// Loads ranges until the buffer covers `targetCoverage`.
    ///
    /// Serialised by `isFetching`: everything here is main-actor isolated, so
    /// the check-and-set can't race even though the body suspends.
    private func pump(generation: Int) async {
        guard generation == loadGeneration, !isFetching else { return }
        isFetching = true
        defer {
            if generation == loadGeneration {
                isFetching = false
            }
        }

        while generation == loadGeneration, !isComplete, bufferedSeconds < targetCoverage {
            let advanced = await loadNextRange(generation: generation)
            if !advanced { break }
        }
    }

    private func loadNextRange(generation: Int) async -> Bool {
        guard generation == loadGeneration,
              let client, let projectID, let recordingID,
              nextRangeIndex < ranges.count
        else { return false }

        let range = ranges[nextRangeIndex]
        do {
            let data = try await client.data(
                for: PostHogAPI.snapshotBlobs(
                    projectID: projectID, recordingID: recordingID, range: range
                )
            )
            guard generation == loadGeneration else { return false }
            // ~1.6 MB of JSONL per range; parsing it on the main actor would
            // drop frames in whatever is already on screen. The console and
            // network extraction rides along in the same detached task so the
            // megabyte is walked once, off the main actor, rather than twice.
            let (events, chunk) = try await Task.detached(priority: .userInitiated) {
                let events = try SnapshotParser.parse(jsonl: data)
                return (events, ReplayDiagnostics.extract(from: events))
            }.value
            guard generation == loadGeneration else { return false }

            nextRangeIndex += 1
            loadedRangeCount = nextRangeIndex
            diagnostics.merge(chunk)
            ingest(events)
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            let message = Self.describe(error)
            if canBoot {
                // Playback already works; losing a later chunk must not take the
                // player down, so it becomes a footnote instead.
                streamingError = message
            } else {
                availability = .unavailable(message)
            }
            return false
        }
    }

    private func ingest(_ events: [SnapshotEvent]) {
        guard !events.isEmpty else {
            if isComplete, !canBoot { availability = .noData }
            return
        }

        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let archiveBatch = events.enumerated().sorted { left, right in
            left.element.timestamp == right.element.timestamp
                ? left.offset < right.offset
                : left.element.timestamp < right.element.timestamp
        }.map(\.element)
        archivedEvents = Self.mergedArchivedEvents(archivedEvents, with: archiveBatch)

        if firstTimestampMS == nil, let first = sorted.first {
            firstTimestampMS = first.timestamp
            replayStart = Date(timeIntervalSince1970: first.timestamp / 1000)
        }
        if let last = sorted.last {
            lastTimestampMS = max(lastTimestampMS ?? last.timestamp, last.timestamp)
        }

        hasFullSnapshot = hasFullSnapshot || sorted.contains { $0.isFullSnapshot }
        totalEventCount += sorted.count
        pending.append(contentsOf: sorted)

        if let first = firstTimestampMS, let last = lastTimestampMS {
            bufferedSeconds = max(0, (last - first) / 1000)
        }

        if canBoot {
            availability = .ready
        } else if isComplete {
            availability = .noData
        }
    }

    /// Merges timestamp-sorted archive batches while preserving source order for
    /// equal timestamps. Existing archive events win ties because they were
    /// fetched from an earlier blob range.
    static func mergedArchivedEvents(
        _ existing: [SnapshotEvent],
        with incoming: [SnapshotEvent]
    ) -> [SnapshotEvent] {
        var merged: [SnapshotEvent] = []
        merged.reserveCapacity(existing.count + incoming.count)

        var existingIndex = 0
        var incomingIndex = 0
        while existingIndex < existing.count, incomingIndex < incoming.count {
            if existing[existingIndex].timestamp <= incoming[incomingIndex].timestamp {
                merged.append(existing[existingIndex])
                existingIndex += 1
            } else {
                merged.append(incoming[incomingIndex])
                incomingIndex += 1
            }
        }
        merged.append(contentsOf: existing[existingIndex...])
        merged.append(contentsOf: incoming[incomingIndex...])
        return merged
    }

    private static func describe(_ error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}
