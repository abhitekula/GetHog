import Foundation
import Testing

@testable import GetHogKit

/// The two health sections the widgets read, and the compatibility rules that
/// let a widget binary from one release read a snapshot written by another.
@Suite("Snapshot health")
struct SnapshotHealthTests {

    // MARK: - Fixtures

    /// The demo project's warnings, trimmed to the shapes that matter: one
    /// error, two warnings, one info, and one severity this client has never
    /// heard of.
    private let warningsJSON = """
        [
          {"type":"cannot_merge_already_identified","category":"merge","severity":"error",
           "count":4182,"last_seen":"2026-01-20T02:00:00Z",
           "sparkline":[12,40,133,null,9,402],"samples":[{"timestamp":"2026-01-20T02:00:00Z"}]},
          {"type":"message_size_too_large","category":"size","severity":"warning",
           "count":917,"sparkline":[0,0,31,44],"samples":[]},
          {"type":"event_timestamp_in_future","category":"event","severity":"warning",
           "count":233,"sparkline":[4,9,11],"samples":[]},
          {"type":"ignored_invalid_timestamp","category":"event","severity":"info",
           "count":61,"sparkline":[],"samples":[]},
          {"type":"brand_new_problem","category":"event","severity":"catastrophe",
           "count":5,"sparkline":[1,2],"samples":[]}
        ]
        """

    private func warnings() throws -> [IngestionWarning] {
        try IngestionWarning.decodeList(from: Data(warningsJSON.utf8))
    }

    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        ingestion: SharedSnapshot.IngestionDigest? = nil,
        quota: SharedSnapshot.QuotaDigest? = nil,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1,
            projectName: "Default project",
            metrics: [],
            flags: [],
            ingestion: ingestion,
            quota: quota,
            capturedAt: capturedAt
        )
    }

    // MARK: - Ingestion reduction

    @Test("the ingestion digest counts every severity band separately")
    func ingestionCounts() throws {
        let digest = SharedSnapshot.IngestionDigest(
            warnings: try warnings(), window: .sevenDays, capturedAt: at
        )

        #expect(digest.typeCount == 5)
        #expect(digest.errorCount == 1)
        #expect(digest.warningCount == 2)
        #expect(digest.infoCount == 1)
        // A severity PostHog added after this build shipped is counted, never
        // folded into `info` — PostHog adds severities when it has something new
        // to warn about, so reading an unrecognised one as mild fails in exactly
        // the direction that matters.
        #expect(digest.unratedCount == 1)
        #expect(digest.affectedEvents == 4182 + 917 + 233 + 61 + 5)
    }

    @Test("the worst row leads, ranked the way the ingestion screen ranks it")
    func ingestionTopRow() throws {
        let digest = SharedSnapshot.IngestionDigest(
            warnings: try warnings(), window: .sevenDays, capturedAt: at
        )

        #expect(digest.topTitle == "Cannot merge already identified")
        #expect(digest.topSeverity == .error)
        #expect(digest.topCount == 4182)
        // The bucket contract includes a null bucket meaning "no
        // events that hour", so it stays as a zero rather than being compacted
        // away and silently re-dating every point after it.
        #expect(digest.topSparkline == [12, 40, 133, 0, 9, 402])
        // The row carries no bucket size, so the window that asked for it is the
        // only thing that can label the sparkline.
        #expect(digest.windowTitle == "7 days")
    }

    @Test("a project with no warnings reduces to a digest that says so")
    func ingestionEmpty() {
        let digest = SharedSnapshot.IngestionDigest(warnings: [], window: .sevenDays, capturedAt: at)

        // Zero is the good news and has to be distinguishable from "not
        // checked", which is `nil` at the snapshot level.
        #expect(digest.typeCount == 0)
        #expect(digest.affectedEvents == 0)
        #expect(digest.topTitle == nil)
        #expect(digest.topSeverity == nil)
        #expect(digest.topSparkline.isEmpty)
    }

    @Test("the carried sparkline is bounded, however many buckets the window returns")
    func ingestionSparklineBounded() throws {
        let buckets = (0..<400).map { String($0) }.joined(separator: ",")
        let json = """
            [{"type":"noisy","category":"event","severity":"warning","count":1,
              "sparkline":[\(buckets)],"samples":[]}]
            """
        let digest = SharedSnapshot.IngestionDigest(
            warnings: try IngestionWarning.decodeList(from: Data(json.utf8)),
            window: .thirtyDays,
            capturedAt: at
        )

        // The snapshot is written on every refresh and read on every widget
        // render; an unbounded array would grow the file for points no widget
        // is wide enough to draw.
        #expect(digest.topSparkline.count <= SharedSnapshot.IngestionDigest.sparklineLimit)
        // The newest buckets are the ones worth keeping.
        #expect(digest.topSparkline.last == 399)
    }

    // MARK: - Quota reduction

    private func quotaLimits() -> QuotaLimits {
        QuotaLimits(resources: [
            .init(key: "events", limited: false, usage: 1812, limit: 1_000_000),
            .init(key: "signals_credits", limited: false, usage: 3000, limit: 4500),
            .init(key: "exceptions", limited: false, usage: 18, limit: nil),
            .init(key: "ai_credits", limited: false, usage: 0, limit: 15_500),
        ])
    }

    @Test("the quota digest leads with the most-pressed metered resource")
    func quotaTopResource() {
        let digest = SharedSnapshot.QuotaDigest(quotaLimits(), capturedAt: at)

        #expect(digest.topTitle == "Signals credits")
        #expect(digest.topState == .watch)
        #expect(digest.topUsage == 3000)
        #expect(digest.topLimit == 4500)
        let fraction = try? #require(digest.topFraction)
        #expect(abs((fraction ?? 0) - 0.6666) < 0.001)
        #expect(digest.pressingCount == 1)
        #expect(digest.blockedCount == 0)
        #expect(digest.resourceCount == 4)
    }

    @Test("a blocked resource is reported as already cut off, not as a forecast")
    func quotaBlocked() {
        let digest = SharedSnapshot.QuotaDigest(
            QuotaLimits(resources: [
                .init(key: "events", limited: true, usage: 1_000_000, limit: 1_000_000),
                .init(key: "signals_credits", limited: false, usage: 3000, limit: 4500),
            ]),
            capturedAt: at
        )

        #expect(digest.blockedCount == 1)
        #expect(digest.topState == .blocked)
        #expect(digest.topTitle == "Events")
    }

    @Test("a resource with no limit is not reported as being near one")
    func quotaUnmetered() {
        let digest = SharedSnapshot.QuotaDigest(
            QuotaLimits(resources: [.init(key: "exceptions", limited: false, usage: 18, limit: nil)]),
            capturedAt: at
        )

        // A missing limit is not a limit of zero, and dividing by one would put
        // a full bar on a resource PostHog never metered.
        #expect(digest.topFraction == nil)
        #expect(digest.topLimit == nil)
        #expect(digest.topState == .unmetered)
        #expect(digest.pressingCount == 0)
    }

    // MARK: - Refetch cadence

    @Test("quota is refetched on its own slow clock, not on every refresh")
    func quotaCadence() {
        let digest = SharedSnapshot.QuotaDigest(quotaLimits(), capturedAt: at)

        // A monthly allowance does not move in the two hours between background
        // wakes, and every refetch is a request against an organisation-wide
        // budget shared with the user's production integrations.
        #expect(SharedSnapshot.QuotaDigest.isDue(previous: digest, now: at.addingTimeInterval(3_600)) == false)
        #expect(
            SharedSnapshot.QuotaDigest.isDue(
                previous: digest,
                now: at.addingTimeInterval(SharedSnapshot.QuotaDigest.refreshInterval + 1)
            )
        )
        // Nothing carried forward means nothing to carry: fetch.
        #expect(SharedSnapshot.QuotaDigest.isDue(previous: nil, now: at))
        // A capture stamped in the future is clock drift, not a reason to spend
        // a request.
        #expect(SharedSnapshot.QuotaDigest.isDue(previous: digest, now: at.addingTimeInterval(-86_400)) == false)
    }

    @Test("a section carried forward across refreshes is flagged as older than the snapshot")
    func carriedForwardSectionIsFlagged() {
        let quota = SharedSnapshot.QuotaDigest(quotaLimits(), capturedAt: at)
        let snapshot = self.snapshot(quota: quota, capturedAt: at.addingTimeInterval(6 * 3_600))

        // "Updated 2m ago" in the footer is a claim about the metrics. Saying it
        // over a six-hour-old quota figure would be the app lying about
        // freshness, which is the one thing it does not do.
        #expect(snapshot.isCarriedForward(quota.capturedAt))
        // Written in the same pass: no second age to state.
        #expect(self.snapshot(quota: quota, capturedAt: at).isCarriedForward(quota.capturedAt) == false)
    }

    // MARK: - Verdict

    private func ingestion(
        errors: Int = 0, warnings: Int = 0, info: Int = 0, unrated: Int = 0
    ) -> SharedSnapshot.IngestionDigest {
        SharedSnapshot.IngestionDigest(
            typeCount: errors + warnings + info + unrated,
            errorCount: errors,
            warningCount: warnings,
            infoCount: info,
            unratedCount: unrated,
            affectedEvents: 0,
            topTitle: errors + warnings + info + unrated > 0 ? "Something" : nil,
            topSeverity: nil,
            topCount: 0,
            topSparkline: [],
            windowTitle: "7 days",
            capturedAt: at
        )
    }

    private func quota(blocked: Int = 0, state: SharedSnapshot.QuotaState? = .clear) -> SharedSnapshot.QuotaDigest {
        SharedSnapshot.QuotaDigest(
            blockedCount: blocked,
            pressingCount: state == .watch || state == .critical ? 1 : 0,
            resourceCount: 18,
            topTitle: "Signals credits",
            topState: state,
            topUsage: 3000,
            topLimit: 4500,
            capturedAt: at
        )
    }

    @Test("nothing checked is not the same as nothing wrong")
    func verdictUnchecked() {
        let snapshot = self.snapshot()
        #expect(snapshot.healthVerdict == .unchecked)
        #expect(snapshot.healthHeadline == "Not checked yet")
    }

    @Test("a blocked quota outranks everything, because it is already dropping data")
    func verdictBlockedQuota() {
        let snapshot = self.snapshot(ingestion: ingestion(), quota: quota(blocked: 2, state: .blocked))
        #expect(snapshot.healthVerdict == .critical)
        #expect(snapshot.healthHeadline == "2 quotas at their limit")
    }

    @Test("an ingestion error is critical")
    func verdictIngestionError() {
        let snapshot = self.snapshot(ingestion: ingestion(errors: 1, warnings: 2), quota: quota())
        #expect(snapshot.healthVerdict == .critical)
        #expect(snapshot.healthHeadline == "1 ingestion error")
    }

    @Test("a warning, or a severity this build cannot read, asks for attention")
    func verdictAttention() {
        #expect(self.snapshot(ingestion: ingestion(warnings: 3)).healthVerdict == .attention)
        // Unrecognised is not benign.
        #expect(self.snapshot(ingestion: ingestion(unrated: 1)).healthVerdict == .attention)
        // Info is informational; it does not raise the verdict.
        #expect(self.snapshot(ingestion: ingestion(info: 4)).healthVerdict == .clear)
    }

    @Test("a quota past the watch band asks for attention before it blocks")
    func verdictQuotaPressure() {
        #expect(self.snapshot(quota: quota(state: .watch)).healthVerdict == .attention)
        #expect(self.snapshot(quota: quota(state: .critical)).healthVerdict == .attention)
        #expect(self.snapshot(quota: quota(state: .critical)).healthHeadline == "Signals credits near its limit")
        #expect(self.snapshot(quota: quota(state: .unmetered)).healthVerdict == .clear)
    }

    @Test("a genuinely quiet project reads as nothing to report, not as an empty screen")
    func verdictClear() {
        let snapshot = self.snapshot(ingestion: ingestion(), quota: quota())
        #expect(snapshot.healthVerdict == .clear)
        #expect(snapshot.healthHeadline == "Nothing to report")
        #expect(snapshot.healthDetail == "Ingestion and quota checked")
    }

    @Test("the detail line never implies a check that did not run")
    func detailNamesWhatWasChecked() {
        // The trap this exists to close: a quota-blocked project produces **no
        // ingestion warning at all**, so "ingestion clear" over an unchecked
        // quota would be a clean bill of health for a project dropping every
        // event.
        #expect(self.snapshot(ingestion: ingestion()).healthDetail == "Quota not checked")
        #expect(self.snapshot(quota: quota()).healthDetail == "Ingestion not checked")
        #expect(self.snapshot().healthDetail == "Open GetHog to sync")
    }

    // MARK: - Compatibility

    /// Everything a snapshot written by *this* build carries.
    private func fullJSON() throws -> Data {
        try JSONEncoder.snapshotEncoderForTests.encode(
            snapshot(
                ingestion: SharedSnapshot.IngestionDigest(
                    warnings: try warnings(), window: .sevenDays, capturedAt: at
                ),
                quota: SharedSnapshot.QuotaDigest(quotaLimits(), capturedAt: at)
            )
        )
    }

    @Test("the health sections survive the round trip through the App Group file")
    func roundTrip() throws {
        let decoded = try JSONDecoder.snapshotDecoderForTests.decode(
            SharedSnapshot.self, from: try fullJSON()
        )

        #expect(decoded.ingestion?.errorCount == 1)
        #expect(decoded.ingestion?.topTitle == "Cannot merge already identified")
        #expect(decoded.quota?.topTitle == "Signals credits")
        #expect(decoded.healthVerdict == .critical)
    }

    @Test("a snapshot written before the health sections existed still decodes")
    func decodesSnapshotWithoutHealth() throws {
        // The app and the widget are separately installed binaries. A widget
        // updated ahead of the app reads snapshots the old app wrote, and a
        // missing section must mean "not checked" rather than a failed decode
        // that renders as "no data at all".
        let json = """
            {"projectID":1,"projectName":"Default project","metrics":[],"flags":[],
             "capturedAt":"2023-11-14T22:13:20Z"}
            """
        let decoded = try JSONDecoder.snapshotDecoderForTests.decode(
            SharedSnapshot.self, from: Data(json.utf8)
        )

        #expect(decoded.ingestion == nil)
        #expect(decoded.quota == nil)
        #expect(decoded.healthVerdict == .unchecked)
    }

    @Test("an older widget ignores every field a newer snapshot added")
    func ignoresUnknownFields() throws {
        // The property the synthesised decode has always had, stated as a test
        // because the whole widget/app split depends on it: keys with no
        // matching property are skipped, at the top level and inside a section.
        let json = """
            {"projectID":1,"projectName":"Default project","metrics":[],"flags":[],
             "capturedAt":"2023-11-14T22:13:20Z",
             "renders":{"count":3},"sdkHealth":"needs_attention","futureScalar":7,
             "ingestion":{"typeCount":2,"errorCount":1,"capturedAt":"2023-11-14T22:13:20Z",
                          "somethingAddedLater":{"nested":[1,2,3]}}}
            """
        let decoded = try JSONDecoder.snapshotDecoderForTests.decode(
            SharedSnapshot.self, from: Data(json.utf8)
        )

        #expect(decoded.projectID == 1)
        #expect(decoded.ingestion?.errorCount == 1)
        #expect(decoded.healthVerdict == .critical)
    }

    @Test("a section missing every optional field decodes to its zero state")
    func sectionDefaults() throws {
        let json = """
            {"projectID":1,"projectName":"P","capturedAt":"2023-11-14T22:13:20Z",
             "ingestion":{"capturedAt":"2023-11-14T22:13:20Z"},
             "quota":{"capturedAt":"2023-11-14T22:13:20Z"}}
            """
        let decoded = try JSONDecoder.snapshotDecoderForTests.decode(
            SharedSnapshot.self, from: Data(json.utf8)
        )

        // Every field a future build might add has to be able to arrive absent,
        // so every field but the timestamp defaults rather than throwing.
        #expect(decoded.ingestion?.typeCount == 0)
        #expect(decoded.ingestion?.windowTitle.isEmpty == false)
        #expect(decoded.quota?.resourceCount == 0)
        // Missing collections are the ordinary shape of an older snapshot.
        #expect(decoded.metrics.isEmpty)
        #expect(decoded.flags.isEmpty)
        #expect(decoded.healthVerdict == .clear)
    }

    @Test("a section that cannot say how old it is is dropped, not dated")
    func sectionWithoutTimestampIsDropped() throws {
        // Freshness is the one thing this app will not guess at. A section with
        // no capture time cannot be labelled honestly, so it costs the section
        // and nothing else — the metrics beside it still render.
        let json = """
            {"projectID":1,"projectName":"P","metrics":[],"flags":[],
             "capturedAt":"2023-11-14T22:13:20Z",
             "quota":{"blockedCount":4}}
            """
        let decoded = try JSONDecoder.snapshotDecoderForTests.decode(
            SharedSnapshot.self, from: Data(json.utf8)
        )

        #expect(decoded.quota == nil)
        #expect(decoded.projectID == 1)
        #expect(decoded.healthVerdict == .unchecked)
    }

    @Test("a snapshot with no capture time is rejected rather than dated now")
    func snapshotWithoutTimestampIsRejected() {
        // Defaulting to `Date()` here would make every stale snapshot claim to
        // be current — the exact lie the freshness footer exists to prevent.
        let json = """
            {"projectID":1,"projectName":"P","metrics":[],"flags":[]}
            """
        #expect(throws: (any Error).self) {
            try JSONDecoder.snapshotDecoderForTests.decode(SharedSnapshot.self, from: Data(json.utf8))
        }
    }

    @Test("a severity or quota state this build has never seen is quarantined, not fatal")
    func unknownEnumValues() throws {
        let json = """
            {"projectID":1,"projectName":"P","metrics":[],"flags":[],
             "capturedAt":"2023-11-14T22:13:20Z",
             "ingestion":{"typeCount":1,"topSeverity":"catastrophe",
                          "capturedAt":"2023-11-14T22:13:20Z"},
             "quota":{"resourceCount":1,"topState":"incinerated",
                      "capturedAt":"2023-11-14T22:13:20Z"}}
            """
        let decoded = try JSONDecoder.snapshotDecoderForTests.decode(
            SharedSnapshot.self, from: Data(json.utf8)
        )

        // A raw value written by a newer app build must not take the whole
        // section down: the label falls back, the counts still carry meaning.
        #expect(decoded.ingestion?.topSeverity == .unrated)
        #expect(decoded.quota?.topState == nil)
    }
}

// MARK: - Test plumbing

extension JSONEncoder {
    /// Matches `SharedSnapshotStore`'s own coders, so these tests exercise the
    /// same date strategy the two processes actually agree on.
    static var snapshotEncoderForTests: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var snapshotDecoderForTests: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
