import Foundation
import Testing

@testable import GetHogKit

/// Ingestion warnings, via `ingestion_warnings_v2`.
///
/// Two things about this endpoint are unlike every other list in this client and
/// both are pinned here, because getting either wrong produces an empty screen
/// rather than an error:
///
/// 1. It answers a **bare JSON array**, not a `Page`, with no
///    `count`/`next`/`results` envelope around it.
/// 2. The **legacy** `/ingestion_warnings/` path answers 403 *"This action does
///    not support personal API key access"*, so it is not in the catalog at all.
///
/// The row fixture is hand-written from the public response shape. No live
/// tenant values are used, which is why the unknown-value cases below are
/// asserted rather than assumed.
@Suite("Ingestion warnings")
struct IngestionWarningTests {

    // MARK: - Envelope

    /// A `Page`-shaped decoder throws on this, and
    /// a screen whose decode throws shows an error where the truth is "nothing
    /// is wrong with your ingestion".
    @Test("decodes the bare array the live endpoint actually returns")
    func bareArrayEnvelope() throws {
        let empty = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_empty.json"))
        #expect(empty.isEmpty)

        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        #expect(rows.count == 6)
    }

    /// Pins the difference rather than merely working around it: if someone
    /// later "tidies" this to `Page<IngestionWarning>` to match its neighbours,
    /// this fails instead of the screen silently emptying.
    @Test("is not a paginated page, and must not be decoded as one")
    func notAPage() throws {
        let data = try Fixture.data("ingestion_warnings_v2.json")
        #expect(throws: (any Error).self) {
            try Page<IngestionWarning>.decode(from: data)
        }
    }

    // MARK: - Unknown values

    /// PostHog documents four categories — `size`, `merge`, `event`, `unknown` —
    /// and three severities. Both are open in practice, and a warning this
    /// client has never heard of is exactly the one worth showing: it is new.
    @Test("quarantines an unrecognised category and severity instead of dropping the row")
    func unknownCategoryAndSeverity() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let odd = try #require(rows.first { $0.type == "quota_limited_wandering_hedgehog" })

        guard case .unknown(let category) = odd.category else {
            Issue.record("expected an unknown category, got \(odd.category)")
            return
        }
        #expect(category == "fixture_lab")

        guard case .unknown(let severity) = odd.severity else {
            Issue.record("expected an unknown severity, got \(odd.severity)")
            return
        }
        #expect(severity == "catastrophic")

        // The count still has to survive — it is what decides whether an
        // unrecognised warning is worth interrupting someone for.
        #expect(odd.count == 17)
    }

    /// `unknown` is *also* a category the server ships deliberately, so the
    /// quarantine case and the real value are the same case. Neither may be
    /// rendered as a raw identifier.
    @Test("treats the server's own `unknown` category as a value, not a decode failure")
    func serverSuppliedUnknownCategory() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let row = try #require(rows.first { $0.type == "person_property_update_too_large" })
        #expect(row.category == .unknown("unknown"))
        #expect(row.category.title == "Uncategorised")
    }

    @Test("titles every known category and severity without echoing the raw string")
    func knownTitles() {
        #expect(IngestionWarningCategory.merge.title == "Merges")
        #expect(IngestionWarningCategory.size.title == "Payload size")
        #expect(IngestionWarningCategory.event.title == "Events")
        #expect(IngestionWarningSeverity.error.title == "Error")
        #expect(IngestionWarningSeverity.warning.title == "Warning")
        #expect(IngestionWarningSeverity.info.title == "Info")

        // An unrecognised value is humanised from its own identifier rather
        // than called "Unknown", so a category PostHog adds next month still
        // reads as something.
        #expect(IngestionWarningSeverity.unknown("catastrophic").title == "Catastrophic")
        #expect(IngestionWarningCategory.unknown("hedgehog_containment").title == "Hedgehog containment")
    }

    // MARK: - Sparkline

    /// The server pre-aggregates and ships a sparkline per row, which is the
    /// whole reason this screen is cheap: no client-side rollup, one request.
    @Test("keeps the server's pre-aggregated sparkline")
    func sparkline() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let merge = try #require(rows.first { $0.type == "cannot_merge_already_identified" })
        #expect(merge.sparkline.count == 12)
        #expect(merge.sparkline.max() == 207)
    }

    /// A row with no buckets at all is not a broken row — it is a warning whose
    /// activity falls outside the requested window. It must decode, and it must
    /// be distinguishable from a flat line so the view can say which it is.
    @Test("survives an empty sparkline")
    func emptySparkline() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let flat = try #require(rows.first { $0.type == "ignored_invalid_timestamp" })
        #expect(flat.sparkline.isEmpty)
        #expect(!flat.hasTrend)

        let zeroes = try #require(rows.first { $0.type == "person_property_update_too_large" })
        // Twelve zero buckets is a *drawable* series that happens to be flat,
        // which is a different fact from "no buckets were returned".
        #expect(zeroes.sparkline.count == 12)
        #expect(!zeroes.hasTrend)
    }

    /// A null bucket means no events in that hour, not a missing hour. Dropping
    /// it would shorten the series and silently re-date every point after it.
    @Test("reads a null sparkline bucket as zero rather than removing it")
    func nullBucketKeepsItsPlace() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let row = try #require(rows.first { $0.type == "replay_timestamp_too_far" })
        #expect(row.sparkline.count == 12)
        #expect(row.sparkline[1] == 0)
        #expect(row.sparkline[3] == 0)
    }

    /// PostHog documents the bucket width as a function of the requested range:
    /// *"Buckets are hourly for time ranges up to 2 days and daily for wider
    /// ranges."* The row itself does not say which it got, so the window that
    /// asked for it is the only thing that can label the axis.
    @Test("derives the bucket width from the requested window, not from the row")
    func bucketWidthFollowsTheWindow() {
        #expect(IngestionWarningWindow.twoDays.bucket == .hourly)
        #expect(IngestionWarningWindow.sevenDays.bucket == .daily)
        #expect(IngestionWarningWindow.thirtyDays.bucket == .daily)
        #expect(IngestionWarningWindow.twoDays.bucket.title == "hourly")
        #expect(IngestionWarningWindow.thirtyDays.bucket.title == "daily")
    }

    // MARK: - Ordering and samples

    @Test("ranks by severity first and volume second")
    func ordering() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
            .sorted(by: IngestionWarning.mostUrgentFirst)

        #expect(rows.first?.severity == .error)

        // An unrated severity sorts last rather than being guessed at: PostHog
        // never said it was low, and pretending it did would bury a warning
        // this client simply has not learned to rank yet.
        #expect(rows.last?.severity == .unknown("catastrophic"))

        let warnings = rows.filter { $0.severity == .warning }
        #expect(warnings.map(\.count) == warnings.map(\.count).sorted(by: >))
    }

    @Test("counts samples without decoding their shape")
    func samples() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let future = try #require(rows.first { $0.type == "event_timestamp_in_future" })
        // `details` is keyed by warning type and differs on every one of them,
        // so the count is the only thing that can be asserted across all rows.
        #expect(future.sampleCount == 2)
        #expect(future.lastSeen != nil)
    }

    /// Absent on a warning PostHog has aggregated but not timestamped. A row
    /// that force-unwrapped this would take the page down.
    @Test("tolerates a missing last_seen")
    func missingLastSeen() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let row = try #require(rows.first { $0.type == "replay_timestamp_too_far" })
        #expect(row.lastSeen == nil)
    }

    /// The type is the only stable identity a row has — there is no id field —
    /// and it is what the human-readable title is derived from.
    @Test("humanises the warning type without inventing a title")
    func titleFromType() throws {
        let rows = try IngestionWarning.decodeList(from: Fixture.data("ingestion_warnings_v2.json"))
        let merge = try #require(rows.first { $0.type == "cannot_merge_already_identified" })
        #expect(merge.title == "Cannot merge already identified")
        #expect(merge.id == "cannot_merge_already_identified")
    }

    // MARK: - Endpoint

    @Test("builds the v2 path, never the personal-key-incompatible legacy one")
    func endpointPath() {
        let endpoint = PostHogAPI.ingestionWarnings(projectID: 1_001)
        #expect(endpoint.path == "/api/projects/1001/ingestion_warnings_v2/")
        // Pre-aggregated by the server: this computes nothing, so it belongs to
        // the CRUD budget rather than the scarce analytics one.
        #expect(endpoint.category == .crud)
        #expect(endpoint.method == "GET")
    }

    @Test("sends the window, ordering and limit the API documents")
    func endpointQuery() {
        let endpoint = PostHogAPI.ingestionWarnings(
            projectID: 1,
            window: .thirtyDays,
            category: .merge,
            orderBy: .lastSeen,
            limit: 250
        )
        #expect(endpoint.query.contains { $0.name == "date_from" && $0.value == "-30d" })
        #expect(endpoint.query.contains { $0.name == "category" && $0.value == "merge" })
        #expect(endpoint.query.contains { $0.name == "order_by" && $0.value == "last_seen" })
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "250" })
    }

    /// The documented range is 1–500 and the API rejects anything outside it.
    /// Clamping here means a caller's mistake costs nothing; not clamping means
    /// an HTTP 400 the screen has to explain.
    @Test("clamps the limit to the documented 1–500 range")
    func endpointLimitClamped() {
        #expect(
            PostHogAPI.ingestionWarnings(projectID: 1, limit: 9_000).query
                .contains { $0.name == "limit" && $0.value == "500" }
        )
        #expect(
            PostHogAPI.ingestionWarnings(projectID: 1, limit: 0).query
                .contains { $0.name == "limit" && $0.value == "1" }
        )
    }

    /// "All categories" must omit the parameter rather than send an empty one —
    /// `category=` filters to warnings whose category is the empty string, which
    /// is none of them.
    @Test("omits the category filter entirely when none is chosen")
    func endpointNoCategory() {
        let endpoint = PostHogAPI.ingestionWarnings(projectID: 1, category: nil)
        #expect(!endpoint.query.contains { $0.name == "category" })
    }

    /// An unrecognised category came from the server, so it round-trips as a
    /// filter value — the alternative is a filter chip that cannot filter.
    @Test("round-trips an unrecognised category as a filter value")
    func endpointUnknownCategory() {
        let endpoint = PostHogAPI.ingestionWarnings(
            projectID: 1,
            category: .unknown("hedgehog_containment")
        )
        #expect(
            endpoint.query.contains { $0.name == "category" && $0.value == "hedgehog_containment" }
        )
    }
}
