import Foundation
import Testing

@testable import GetHogKit

/// `GET /exports/`.
///
/// Named for chart exports, but this authored fixture models six `video/mp4`
/// renders of session recordings, with `dashboard` and `insight` null on every
/// one. The expectations below pin the synthetic response shape, not what the
/// endpoint's name suggests.
@Suite("Recording exports")
struct RecordingExportTests {

    // A single fixed instant, so nothing here depends on when the suite runs.
    // Expiry is a pure function of a date the caller passes in for exactly this
    // reason: a test that read the clock would start failing on its own.
    static let now = PostHogDate.parse("2026-01-12T12:00:00.000Z")!

    @Test("decodes the session-recording video renders this endpoint really returns")
    func decodesRenders() throws {
        let page = try Page<RecordingExport>.decode(from: Fixture.data("exports.json"))
        #expect(page.count == 120)
        #expect(page.results.count == 6)

        let first = try #require(page.results.first)
        #expect(first.id == 700_043)
        #expect(first.format == .videoMP4)
        #expect(first.filename == "Example filename 0312")
        #expect(first.hasContent)
        #expect(first.failure == nil)
        #expect(first.createdAt != nil)
        #expect(first.expiresAfter != nil)

        // The whole reason this model is named for recordings: the payload
        // never carries a dashboard or an insight, only a recording id.
        #expect(page.results.allSatisfy { $0.dashboardID == nil && $0.insightID == nil })
        #expect(page.results.allSatisfy { $0.sessionRecordingID != nil })
    }

    /// `export_format` is `video/mp4` on every row today, but the field exists
    /// because it is not guaranteed to stay that way. A hard-coded enum would
    /// throw on the first CSV export and empty the entire list, not just the
    /// one row — `Page` decoding is all-or-nothing.
    @Test("quarantines an export format this client has never seen")
    func unknownFormat() throws {
        let json = """
        {"id": 1, "export_format": "text/csv", "has_content": true,
         "created_at": "2026-01-14T04:36:18.000Z", "exception": null}
        """
        let export = try JSONDecoder().decode(RecordingExport.self, from: Data(json.utf8))
        #expect(export.format == .unknown("text/csv"))
        #expect(export.format.rawValue == "text/csv")
        // A player must not be handed something that is not a video.
        #expect(!export.format.isVideo)
        #expect(export.id == 1)
    }

    /// A render that blew up and one that has not finished both answer
    /// `has_content: false`. Collapsing them shows a permanent failure as a
    /// spinner that never resolves.
    @Test("tells a failed render apart from one that is still rendering")
    func failedVersusPending() throws {
        let page = try Page<RecordingExport>.decode(from: Fixture.data("exports.json"))

        let failed = try #require(page.results.first { $0.id == 700_046 })
        #expect(!failed.hasContent)
        guard case .failed(let reason) = failed.state(asOf: Self.now) else {
            Issue.record("expected .failed, got \(failed.state(asOf: Self.now))")
            return
        }
        #expect(reason == "Example exception 0317")
        #expect(failed.failure != nil)

        let pending = try #require(page.results.first { $0.id == 700_045 })
        #expect(!pending.hasContent)
        #expect(pending.failure == nil)
        #expect(pending.state(asOf: Self.now) == .pending)
    }

    /// `expires_after` is real — PostHog deletes the object and the download
    /// link 404s. Showing a play button for a dead file is worse than saying it
    /// is gone.
    @Test("decides expiry purely from the date it is handed")
    func expiryIsPure() throws {
        let page = try Page<RecordingExport>.decode(from: Fixture.data("exports.json"))

        let stale = try #require(page.results.first { $0.id == 700_043 })
        #expect(stale.hasContent)
        #expect(stale.hasExpired(asOf: Self.now))
        #expect(stale.state(asOf: Self.now) == .expired)

        // The same record, read a day after it was made, is perfectly good.
        let fresh = try #require(PostHogDate.parse("2026-01-07T16:00:00.000Z"))
        #expect(!stale.hasExpired(asOf: fresh))
        #expect(stale.state(asOf: fresh) == .ready)

        let live = try #require(page.results.first { $0.id == 700_047 })
        #expect(!live.hasExpired(asOf: Self.now))
        #expect(live.state(asOf: Self.now) == .ready)
    }

    /// A failure outranks expiry: "this render crashed" is the fact worth
    /// showing, and it stays true forever. Reporting it as merely expired would
    /// suggest re-requesting the same export would work.
    @Test("reports a failed export as failed even once it has expired")
    func failureOutranksExpiry() throws {
        let json = """
        {"id": 2, "export_format": "video/mp4", "has_content": false,
         "created_at": "2025-06-18T00:00:00.000Z",
         "expires_after": "2025-09-16T00:00:00.000Z",
         "exception": "RuntimeError: ffmpeg exited with code 1"}
        """
        let export = try JSONDecoder().decode(RecordingExport.self, from: Data(json.utf8))
        #expect(export.hasExpired(asOf: Self.now))
        guard case .failed = export.state(asOf: Self.now) else {
            Issue.record("expected .failed, got \(export.state(asOf: Self.now))")
            return
        }
    }

    /// `inactivity_periods` is what makes "skip inactivity" possible, and the
    /// idle stretches are the half that carries the information. Filtering them
    /// out at decode leaves nothing to skip.
    @Test("keeps every inactivity period, idle ones included")
    func inactivityPeriods() throws {
        let page = try Page<RecordingExport>.decode(from: Fixture.data("exports.json"))
        let first = try #require(page.results.first)
        let context = try #require(first.context)

        #expect(context.inactivityPeriods.count == 4)
        #expect(context.inactivityPeriods.contains { !$0.isActive })

        let idle = try #require(context.inactivityPeriods.first { !$0.isActive })
        #expect(abs(idle.startSeconds - 107.124) < 0.001)
        #expect(abs(idle.endSeconds - 148.21) < 0.001)
        #expect(abs(idle.duration - 41.086) < 0.001)

        // 98.124 active + 41.086 idle + 11.37 active + 12.0 active.
        #expect(abs(context.activeDuration - 121.494) < 0.001)
        #expect(abs(context.idleDuration - 41.086) < 0.001)
    }

    @Test("derives a list row from the render context")
    func listRow() throws {
        let page = try Page<RecordingExport>.decode(from: Fixture.data("exports.json"))
        let first = try #require(page.results.first)

        // The three facts a row needs: how long, how big, and which recording
        // it came from — so tapping the row can open the recording itself.
        #expect(abs((first.duration ?? 0) - 47.211) < 0.001)
        #expect(first.fileSizeBytes == 2_152_533)
        #expect(first.sessionRecordingID == "018f0000-0000-7000-8000-000000000001")
        #expect(first.summary == "0:47 · 2.2 MB")

        let long = try #require(page.results.first { $0.id == 700_044 })
        #expect(long.summary == "8:10 · 49.8 MB")
        // `truncated` means PostHog cut the render short; a row that claimed the
        // full session length would be lying about what the file contains.
        #expect(long.context?.truncated == true)
    }

    /// A render still in flight has no size and no duration yet. Every one of
    /// those fields is optional for that reason.
    @Test("survives an export with no render context at all")
    func missingContext() throws {
        let json = """
        {"id": 3, "export_format": "video/mp4", "has_content": false,
         "created_at": "2026-01-14T04:36:18.000Z", "export_context": null,
         "exception": null, "filename": null}
        """
        let export = try JSONDecoder().decode(RecordingExport.self, from: Data(json.utf8))
        #expect(export.context == nil)
        #expect(export.duration == nil)
        #expect(export.fileSizeBytes == nil)
        #expect(export.sessionRecordingID == nil)
        #expect(export.summary == "Not rendered yet")
        // No `expires_after` means nothing has told us it died.
        #expect(!export.hasExpired(asOf: Self.now))
        #expect(export.state(asOf: Self.now) == .pending)
    }

    /// The status line has to come from the same date the rest of the row was
    /// rendered against, or a list can show "Ready" next to a play button that
    /// 404s — the two would have asked the clock a few milliseconds apart.
    @Test("names the state from the date it is given, never from the clock")
    func statusWording() throws {
        let page = try Page<RecordingExport>.decode(from: Fixture.data("exports.json"))

        let live = try #require(page.results.first { $0.id == 700_047 })
        let pending = try #require(page.results.first { $0.id == 700_045 })
        let failed = try #require(page.results.first { $0.id == 700_046 })
        let stale = try #require(page.results.first { $0.id == 700_043 })

        #expect(live.statusText(asOf: Self.now) == "Ready")
        #expect(pending.statusText(asOf: Self.now) == "Rendering")
        #expect(failed.statusText(asOf: Self.now) == "Failed")
        #expect(stale.statusText(asOf: Self.now) == "Expired")

        // Same record, earlier date, different word — the date is the input.
        let fresh = try #require(PostHogDate.parse("2026-01-07T16:00:00.000Z"))
        #expect(stale.statusText(asOf: fresh) == "Ready")
    }

    // MARK: - Endpoints

    @Test("builds the exports listing as plain CRUD")
    func exportsEndpoint() {
        let endpoint = PostHogAPI.exports(projectID: 1_001, limit: 100)
        #expect(endpoint.path == "/api/projects/1001/exports/")
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "100" })
        // Listing renders computes nothing, so it must not bill the shared
        // `.query` budget.
        #expect(endpoint.category == .crud)
    }

    @Test("builds the content link that redirects to the presigned file")
    func exportContentEndpoint() {
        let endpoint = PostHogAPI.exportContent(projectID: 1_001, exportID: 700_047)
        #expect(endpoint.path == "/api/projects/1001/exports/700047/content/")
        #expect(endpoint.method == "GET")
        #expect(endpoint.category == .crud)
    }
}
