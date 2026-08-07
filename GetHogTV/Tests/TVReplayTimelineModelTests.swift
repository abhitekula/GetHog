import Foundation
import GetHogKit
import Testing
@testable import GetHog

/// Pins the bucketing that stands in for a player.
///
/// This is the whole of what the TV can say about a replay, so it has to be
/// right about *where* things happened, not merely how many there were: a
/// strip that put a burst in the wrong half of the recording is worse than no
/// strip, because it looks like a measurement.
@Suite("TV replay timeline")
struct TVReplayTimelineModelTests {

    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// One incremental rrweb event at `offset` seconds into the recording.
    private static func event(at offset: TimeInterval, type: Int = 3) -> SnapshotEvent {
        let millis = (origin.timeIntervalSince1970 + offset) * 1_000
        return SnapshotEvent(
            windowID: "w",
            type: type,
            timestamp: millis,
            event: .object(["type": .number(Double(type)), "timestamp": .number(millis)])
        )
    }

    private static func model(
        events: [SnapshotEvent],
        diagnostics: ReplayDiagnostics = ReplayDiagnostics(),
        duration: TimeInterval = 480
    ) -> TVReplayTimelineModel {
        TVReplayTimelineModel(
            events: events,
            diagnostics: diagnostics,
            origin: origin,
            duration: duration
        )
    }

    @Test("activity lands in the segment it happened in")
    func weightsLandInTheRightBuckets() {
        // 480 seconds over 48 buckets is 10 seconds each, so these three are
        // buckets 0, 1 and 47 — first, second and last.
        let model = Self.model(events: [
            Self.event(at: 1),
            Self.event(at: 2),
            Self.event(at: 15),
            Self.event(at: 475)
        ])
        #expect(model.buckets[0].weight == 2)
        #expect(model.buckets[1].weight == 1)
        #expect(model.buckets[47].weight == 1)
        #expect(model.buckets.map(\.weight).reduce(0, +) == 4)
    }

    @Test("an event exactly on the duration belongs to the last segment")
    func finalInstantIsInsideTheRecording() {
        // `Int(480 / 10)` is 48, one past the end. An event at the last
        // instant is in the recording, not after it, and indexing past the
        // array would be a crash rather than a wrong bar.
        let model = Self.model(events: [Self.event(at: 480)])
        #expect(model.buckets[47].weight == 1)
    }

    @Test("only incremental events count as activity")
    func snapshotsAndMetaAreNotActivity() {
        // Every blob range opens with a meta (4) and a full snapshot (2). If
        // those counted, the strip would draw a spike at every range boundary
        // that nobody in the session caused.
        let model = Self.model(events: [
            Self.event(at: 5, type: 2),
            Self.event(at: 5, type: 4),
            Self.event(at: 5, type: 3)
        ])
        #expect(model.buckets[0].weight == 1)
        // `totalEvents` still counts everything: it reports what was fetched,
        // not what was drawn.
        #expect(model.totalEvents == 3)
    }

    @Test("an event before the origin is dropped rather than folded into the first segment")
    func negativeOffsetsAreDropped() {
        // Network entries buffered before the recorder started carry earlier
        // timestamps. Putting them in bucket 0 would claim activity at a
        // moment the recording does not cover.
        let model = Self.model(events: [Self.event(at: -30)])
        #expect(model.buckets.allSatisfy { $0.weight == 0 })
    }

    @Test("a console error marks its own segment and no other")
    func consoleErrorsFlagOneBucket() {
        let diagnostics = ReplayDiagnostics.extract(from: [
            Self.consoleEvent(at: 105, level: "error"),
            Self.consoleEvent(at: 200, level: "warn")
        ])
        let model = Self.model(events: [], diagnostics: diagnostics)
        // 105s / 10s = bucket 10; the warning at 200s must not mark bucket 20.
        #expect(model.buckets[10].hasConsoleError)
        #expect(!model.buckets[20].hasConsoleError)
        #expect(model.buckets.count(where: \.hasConsoleError) == 1)
        #expect(model.consoleErrors == 1)
        #expect(model.consoleWarnings == 1)
    }

    @Test("summary counts equal the diagnostics they came from")
    func summaryCountsMatchTheFixture() {
        let diagnostics = ReplayDiagnostics.extract(from: [
            Self.consoleEvent(at: 10, level: "error"),
            Self.consoleEvent(at: 20, level: "error"),
            Self.consoleEvent(at: 30, level: "log")
        ])
        let model = Self.model(events: [Self.event(at: 1)], diagnostics: diagnostics)
        #expect(model.consoleErrors == 2)
        #expect(model.consoleWarnings == 0)
        #expect(model.totalEvents == 1)
        #expect(model.bufferedSeconds == 480)
    }

    @Test("a recording with no measured duration yields no buckets rather than dividing by zero")
    func zeroDurationYieldsNoBuckets() {
        #expect(Self.model(events: [Self.event(at: 1)], duration: 0).buckets.isEmpty)
        #expect(Self.model(events: [Self.event(at: 1)], duration: -5).buckets.isEmpty)
        let unparsed = TVReplayTimelineModel(
            events: [Self.event(at: 1)],
            diagnostics: ReplayDiagnostics(),
            origin: nil,
            duration: 480
        )
        #expect(unparsed.buckets.isEmpty)
        // The counts survive either way — the view still has something to say
        // when it has no axis to draw it on.
        #expect(unparsed.totalEvents == 1)
    }

    @Test("segment starts run from zero to the end of the recording")
    func bucketStartsCoverTheDuration() {
        let model = Self.model(events: [])
        #expect(model.buckets.count == TVReplayTimelineModel.bucketCount)
        #expect(model.buckets.first?.start == 0)
        // Last bucket *starts* one width before the end, not at it.
        #expect(model.buckets.last?.start == 470)
        #expect(model.buckets.map(\.index) == Array(0..<TVReplayTimelineModel.bucketCount))
    }

    @Test("the incident caption counts segments, and says nothing when there are none")
    func incidentSummaryReadsTheMarks() {
        let diagnostics = ReplayDiagnostics.extract(from: [
            Self.consoleEvent(at: 10, level: "error"),
            Self.consoleEvent(at: 100, level: "error")
        ])
        let model = Self.model(events: [], diagnostics: diagnostics)
        let summary = TVReplayTimelineView.incidentSummary(model)
        #expect(summary.contains("2 segments"))
        #expect(!summary.contains("failed requests"))
    }

    /// An rrweb plugin event carrying one console line, in the shape
    /// `ReplayDiagnostics.extract` actually reads — `type: 6`, the
    /// `rrweb/console@1` plugin, and a `payload.payload` array of already
    /// JSON-encoded arguments. Built this way rather than by constructing a
    /// `ReplayConsoleEntry` directly so the test drives the real extractor: a
    /// change to how PostHog ships console lines breaks this rather than
    /// passing it by coincidence.
    private static func consoleEvent(at offset: TimeInterval, level: String) -> SnapshotEvent {
        let millis = (origin.timeIntervalSince1970 + offset) * 1_000
        return SnapshotEvent(
            windowID: "w",
            type: 6,
            timestamp: millis,
            event: .object([
                "type": .number(6),
                "timestamp": .number(millis),
                "data": .object([
                    "plugin": .string("rrweb/console@1"),
                    "payload": .object([
                        "level": .string(level),
                        "payload": .array([.string("\"something happened\"")]),
                        "trace": .array([])
                    ])
                ])
            ])
        )
    }
}
