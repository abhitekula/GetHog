import Foundation
import Testing

@testable import GetHogKit

@Suite("Endpoint catalog")
struct APITests {

    @Test("builds the dashboard detail endpoint")
    func dashboardDetail() {
        let endpoint = PostHogAPI.dashboard(projectID: 1_001, dashboardID: 71_001)
        #expect(endpoint.path == "/api/projects/1001/dashboards/71001/")
        #expect(endpoint.category == .analytics)
    }

    @Test("requests cached dashboard results by default to protect the shared budget")
    func dashboardUsesCache() {
        let cached = PostHogAPI.dashboard(projectID: 1, dashboardID: 2)
        #expect(cached.query.contains { $0.name == "refresh" && $0.value == "force_cache" })

        // Only an explicit pull-to-refresh may trigger recomputation.
        let refreshed = PostHogAPI.dashboard(projectID: 1, dashboardID: 2, refresh: true)
        #expect(refreshed.query.contains { $0.name == "refresh" && $0.value == "lazy_async" })
    }

    @Test("builds a HogQL events query with a keyset cursor rather than OFFSET")
    func eventsKeyset() throws {
        let floor = Date(timeIntervalSince1970: 1_699_000_000)
        let cursor = EventCursor(timestamp: Date(timeIntervalSince1970: 1_700_000_000), uuid: "u1")
        let endpoint = PostHogAPI.events(projectID: 1, limit: 50, since: floor, before: cursor)

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1/query/")
        #expect(endpoint.category == .query)

        let body = try #require(endpoint.body).asString
        #expect(body.contains("HogQLQuery"))
        #expect(body.contains("LIMIT 50"))
        // OFFSET is rejected for personal API keys, so paging must be keyset.
        #expect(!body.uppercased().contains("OFFSET"))
        // On the (timestamp, uuid) pair: timestamps are not unique, and a page
        // boundary cutting a tie group used to drop its remainder silently.
        #expect(body.contains("(timestamp, uuid) <"))
    }

    @Test("omits the cursor clause on the first page but never the time bound")
    func eventsFirstPage() throws {
        let floor = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = PostHogAPI.events(projectID: 1, limit: 25, since: floor)
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(!sql.contains("(timestamp, uuid) <"))
        #expect(sql.contains("timestamp > toDateTime64("))
        #expect(sql.contains("LIMIT 25"))
    }

    @Test("escapes single quotes in an event filter so a value cannot break out of the literal")
    func eventsFilterEscaping() throws {
        let floor = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = PostHogAPI.events(projectID: 1, limit: 10, since: floor, search: "it's")

        // Inspect the decoded SQL rather than the JSON bytes: JSON encoding adds
        // its own backslash layer that has nothing to do with HogQL safety.
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains(#"it\'s"#))
        #expect(!sql.contains("%it's%"))
    }

    @Test("escapes a backslash before escaping quotes, so escaping cannot be bypassed")
    func eventsFilterBackslashEscaping() throws {
        let floor = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = PostHogAPI.events(projectID: 1, limit: 10, since: floor, search: #"a\'b"#)
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains(#"a\\\'b"#))
    }

    private static func decodedSQL(from endpoint: Endpoint) -> String? {
        guard let body = endpoint.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let query = json["query"] as? [String: Any]
        else { return nil }
        return query["query"] as? String
    }

    @Test("builds the snapshot source listing and a blob range request")
    func snapshotEndpoints() {
        let listing = PostHogAPI.snapshotSources(projectID: 1, recordingID: "abc")
        // Under `/projects/`, not `/environments/`. The `/environments/` alias
        // this once pinned carries `deprecation: true` and
        // `sunset: Fri, 31 Jul 2026 00:00:00 GMT` in PostHog's own response
        // headers, with the `/projects/` form named as its successor. The two
        // return byte-identical data, so this expectation moved with the fix
        // rather than the fix being written around the test.
        #expect(listing.path == "/api/projects/1/session_recordings/abc/snapshots")
        #expect(listing.query.isEmpty)

        let blobs = PostHogAPI.snapshotBlobs(
            projectID: 1,
            recordingID: "abc",
            range: BlobRange(start: "0", end: "19")
        )
        #expect(blobs.query.contains { $0.name == "source" && $0.value == "blob_v2" })
        #expect(blobs.query.contains { $0.name == "start_blob_key" && $0.value == "0" })
        #expect(blobs.query.contains { $0.name == "end_blob_key" && $0.value == "19" })
    }

    @Test("builds a flag toggle as a PATCH carrying only the active field")
    func flagToggle() throws {
        let endpoint = PostHogAPI.setFlagActive(projectID: 1, flagID: 71_002, active: false)
        #expect(endpoint.method == "PATCH")
        #expect(endpoint.path == "/api/projects/1/feature_flags/71002/")
        #expect(endpoint.category == .crud)

        let body = try #require(endpoint.body).asString
        #expect(body.contains("\"active\":false"))
    }

    @Test("builds the session timeline query filtered on the session id")
    func sessionTimeline() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = PostHogAPI.sessionEvents(
            projectID: 1,
            sessionID: "sess-1",
            within: start...start.addingTimeInterval(300),
            limit: 500
        )
        let body = try #require(endpoint.body).asString
        // The materialised column, not `properties.$session_id`, which is a
        // JSON extraction over every row in the window and measured 38.66s
        // against 1.35s for the same five rows.
        #expect(body.contains("WHERE $session_id"))
        #expect(!body.contains("properties.$session_id"))
        #expect(body.contains("sess-1"))
        // Bounded, for the reason the events feed was: an unbounded scan of the
        // shared `events` table ran 8.5s and failed 1 in 5 under load. Filtering
        // on the session id does not prune partitions; a timestamp range does.
        #expect(body.contains("timestamp >"))
        #expect(body.contains("timestamp <"))
    }
}

@Suite("Scope preflight")
struct ScopePreflightTests {

    @Test("marks a capability available when its probe succeeds")
    func availableCapability() {
        let result = CapabilityReport(results: [.dashboards: .available])
        #expect(result.isAvailable(.dashboards))
        #expect(result.missingScopes.isEmpty)
    }

    @Test("names the exact missing scope so onboarding can tell the user what to tick")
    func missingScopeNamed() {
        let report = CapabilityReport(results: [
            .sessions: .locked(scope: "session_recording:read")
        ])
        #expect(!report.isAvailable(.sessions))
        #expect(report.missingScopes == ["session_recording:read"])
    }

    @Test("falls back to the documented scope when PostHog does not name one")
    func fallsBackToDocumentedScope() {
        let report = CapabilityReport(results: [.flags: .locked(scope: nil)])
        // The user still needs an actionable instruction.
        #expect(report.missingScopes == [Capability.flags.requiredScopes.joined(separator: ", ")])
    }
}

private extension Data {
    var asString: String { String(decoding: self, as: UTF8.self) }
}
