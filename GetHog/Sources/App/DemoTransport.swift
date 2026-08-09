import CoreGraphics
import Foundation
import ImageIO
import GetHogKit
import UniformTypeIdentifiers

/// Loads deterministic, hand-authored PostHog response shapes containing only fictional data.
/// Preserves each endpoint's method, path, shape, and status. Ships in Release —
/// onboarding's "Explore the demo" enters it at runtime via `AppModel.enterDemo()`,
/// which is also what App Review uses to see the app without a PostHog credential.
private actor DemoSummaryGenerationState {
    private let startsAbsent: Bool
    private var generated = false

    init(startsAbsent: Bool) {
        self.startsAbsent = startsAbsent
    }

    var shouldReturnMissing: Bool { startsAbsent && !generated }

    func markGenerated() {
        generated = true
    }
}

struct DemoTransport: HTTPTransport {

    static let launchArgument = "-GetHogDemo"
    static let dashboardID = 725_101
    static let hogQLDashboardID = 725_102
    static let emptyDashboardID = 725_103
    static let emptyCollectionEnvironment = "GETHOG_DEMO_EMPTY_COLLECTION"
    static let summaryGenerationEnvironment = "GETHOG_DEMO_SUMMARY_GENERATION"
    static let dashboardDetailDelayEnvironment = "GETHOG_DEMO_DASHBOARD_DETAIL_DELAY_MS"
    static let dashboardRecomputeFailureEnvironment = "GETHOG_DEMO_DASHBOARD_RECOMPUTE_FAILURE"

    enum EmptyCollection: String, CaseIterable {
        case dashboards
        case insights
        case sessions
        case experiments
        case errorTracking

        func matches(path: String, body: String) -> Bool {
            switch self {
            case .dashboards: path.hasSuffix("/dashboards/")
            case .insights: path.hasSuffix("/insights/")
            case .sessions: path.hasSuffix("/session_recordings/")
            case .experiments: path.hasSuffix("/experiments/")
            case .errorTracking:
                path.hasSuffix("/query/") && body.contains("ErrorTrackingQuery")
            }
        }
    }

    private let emptyCollection: EmptyCollection?
    private let summaryGeneration: DemoSummaryGenerationState
    private let dashboardDetailDelayMilliseconds: Int
    private let dashboardRecomputeFailure: Bool

    init(
        emptyCollection: EmptyCollection? = nil,
        summaryInitiallyAbsent: Bool? = nil,
        dashboardDetailDelayMilliseconds: Int? = nil,
        dashboardRecomputeFailure: Bool? = nil
    ) {
        self.emptyCollection = emptyCollection ?? ProcessInfo.processInfo.environment[
            Self.emptyCollectionEnvironment
        ].flatMap(EmptyCollection.init(rawValue:))
        let startsAbsent = summaryInitiallyAbsent
            ?? (ProcessInfo.processInfo.environment[Self.summaryGenerationEnvironment] == "1")
        summaryGeneration = DemoSummaryGenerationState(startsAbsent: startsAbsent)
        let environmentDelay = ProcessInfo.processInfo.environment[
            Self.dashboardDetailDelayEnvironment
        ].flatMap(Int.init)
        self.dashboardDetailDelayMilliseconds = max(
            0,
            dashboardDetailDelayMilliseconds ?? environmentDelay ?? 0
        )
        self.dashboardRecomputeFailure = dashboardRecomputeFailure
            ?? (ProcessInfo.processInfo.environment[
                Self.dashboardRecomputeFailureEnvironment
            ] == "1")
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // `path(percentEncoded: false)`, never `url.path`, for two reasons that
        // both silently route a request to the empty-page fallback:
        //
        // 1. `URL.path` **normalises the trailing slash away**, and every PostHog
        //    collection endpoint ends in one. `/feature_flags/` arrived here as
        //    `/feature_flags`, so `contains("/feature_flags/")` was false and the
        //    whole list came back empty — while `/dashboards/1/` still matched,
        //    so detail screens looked perfectly healthy. That asymmetry is what
        //    made it read as a fixture problem rather than a routing one.
        // 2. `URLComponents` percent-encodes the `@` in `/users/@me/`; this
        //    accessor decodes it, where the raw path would not.
        let path = request.url?.path(percentEncoded: false) ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let query = request.url?.query ?? ""
        let isDashboardDetail = path.contains("/dashboards/")
            && !path.hasSuffix("/dashboards/")

        if isDashboardDetail, dashboardDetailDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(dashboardDetailDelayMilliseconds))
        }
        if isDashboardDetail,
           dashboardRecomputeFailure,
           query.contains("refresh=lazy_async") {
            return Self.jsonReply(
                url: request.url!,
                data: Data(#"{"detail":"Synthetic dashboard recompute failed"}"#.utf8),
                status: 503
            )
        }

        if request.httpMethod == "POST",
           path.hasSuffix("/create_session_summaries_individually/"),
           Self.isCanonicalSummaryGenerationRequest(request.httpBody) {
            await summaryGeneration.markGenerated()
            return Self.jsonReply(
                url: request.url!, data: Data(#"{}"#.utf8), status: 200
            )
        }

        if path.hasSuffix("/single_session_summaries/\(Self.summarisedDemoSession)/"),
           await summaryGeneration.shouldReturnMissing {
            return Self.jsonReply(url: request.url!, data: Self.noStoredSummary, status: 404)
        }

        // Writes route by **method**, because a create and a list share a path.
        // `POST /annotations/` and `GET /annotations/` differ in nothing else,
        // and answering the create with the collection's `Page` envelope would
        // fail to decode as one `Annotation` — which the composer reports as
        // "PostHog answered, but not in a shape this app could read". A demo that
        // says that about its own fixture is worse than one with no route at all.
        if let write = Self.writeFixture(
            method: request.httpMethod ?? "GET",
            path: path,
            body: body
        ) {
            try? await Task.sleep(for: .milliseconds(120))
            return Self.jsonReply(url: request.url!, data: write.data, status: write.status)
        }

        let reply = if let emptyCollection,
                       emptyCollection.matches(path: path, body: body)
        {
            Reply(Self.emptyPage)
        } else {
            Self.fixture(for: path, body: body, query: query)
        }
        // A touch of latency so loading states actually render rather than
        // flashing past — otherwise skeletons and spinners go untested.
        try? await Task.sleep(for: .milliseconds(120))
        return Self.jsonReply(url: request.url!, data: reply.data, status: reply.status)
    }

    private static func jsonReply(
        url: URL,
        data: Data,
        status: Int
    ) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    /// One demo answer: the bytes, and the status they arrive with.
    ///
    /// The status travels *with* the fixture rather than being decided beside
    /// it. It used to be decided beside it — a `status(for:)` returned 404 for a
    /// session with no stored summary while the routing separately returned the
    /// 404's body — and two functions that have to agree about one route by
    /// inspection is the arrangement every other comment in this file exists to
    /// avoid. There is now one place per route where both are chosen.
    private struct Reply {
        let data: Data
        let status: Int

        init(_ data: Data, status: Int = 200) {
            self.data = data
            self.status = status
        }
    }

    /// The session the demo summary fixture describes — and the one the demo
    /// player actually plays, so its chapters seek to real frames.
    private static let summarisedDemoSession = "018f1000-0000-7000-8000-000000000001"

    private static func isCanonicalSummaryGenerationRequest(_ body: Data?) -> Bool {
        guard let body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sessionIDs = payload["session_ids"] as? [String]
        else { return false }

        return sessionIDs == [summarisedDemoSession]
    }

    /// Only the replay timeline builder owns `session_events.json`. A bare
    /// `$session_id` predicate is valid SQL-console input too, so claiming on the
    /// predicate alone substitutes a plausible but unrelated response. Decode the
    /// request and require the builder's selected columns, bounded window, order,
    /// and canonical demo session together.
    private static func isCanonicalSessionTimelineQuery(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = payload["query"] as? [String: Any],
              query["kind"] as? String == "HogQLQuery",
              let sql = query["query"] as? String
        else { return false }

        return sql.contains(
            "SELECT uuid, event, timestamp, distinct_id, properties.$current_url, properties"
        )
            && sql.contains("FROM events")
            && sql.contains("WHERE $session_id = '\(summarisedDemoSession)'")
            && sql.contains("AND timestamp > toDateTime64(")
            && sql.contains("AND timestamp < toDateTime64(")
            && sql.contains("ORDER BY timestamp ASC")
            && sql.contains("LIMIT ")
    }

    private static let noStoredSummary =
        Data(#"{"detail":"No stored summary found for this session."}"#.utf8)

    // Deterministic fixture routing preserves the response shape and status for this case.

    /// The column `PostHogAPI.errorIssueOccurrence` filters on — and the only
    /// marker that tells its HogQL apart from the events feed's. Body.
    private static let exceptionIssueColumn = "$exception_issue_id"

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static let unresolvedFramesIssue = "018f3300-0000-7000-8000-000000000901"

    /// The second row: `LedgerFetchFault`, `fetchHarborLedger` — matching
    /// `exception_resolved_frame.json`'s description and function exactly. Body.
    private static let resolvedFrameIssue = "018f3300-0000-7000-8000-000000000902"

    /// The two experiments with a detail fixture of their own, matched in the
    /// **path**. 71101 is running under Bayesian statistics; 71103 finished under
    /// frequentist ones. The third, 71102, is a draft and answers from its list
    /// row — see `experimentDetail(for:)` for why that is enough.
    private static let runningExperimentID = 71_101
    private static let completedExperimentID = 71_103

    /// 71103 again, in the **body** this time, and by *name* rather than by id:
    /// `ExperimentExposureQuery` carries `experiment_name` as a string, while its
    /// `experiment_id` is a JSON number whose spelling on the wire is the
    /// encoder's business rather than something to key a route on.
    private static let completedExperimentName = "Example export format trial"

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static let secondDemoOrganization = "018f9000-0000-7000-8000-000000000443"

    /// The column both survey-results queries filter on, and the only marker
    /// that tells their HogQL apart from the events feed's. Body.
    private static let surveyIDColumn = "properties.$survey_id"

    /// The one survey in `surveys.json` carrying a `start_date`, and therefore
    /// the only one whose results are ever asked for. Body — it appears inside
    /// the generated SQL, not in the path. `surveys.json`'s own `_note` records
    /// that the date was added and why.
    private static let launchedDemoSurvey = "018f9000-0000-7000-8000-000000000107"

    /// The three metric uuids the demo experiments declare, matched in the body.
    /// Each has exactly one result fixture, and nothing stands in for a metric it
    /// does not describe.
    private static let funnelMetricUUID = "018f9000-0000-7000-8000-000000000268"
    private static let meanMetricUUID = "018f9000-0000-7000-8000-000000000269"
    private static let shippedMetricUUID = "018f9000-0000-7000-8000-000000000270"

    /// The two demo notebooks, matched in the **path** — `PostHogAPI.notebook`
    /// looks one up by `short_id`, not by the uuid in `id`.
    ///
    /// Two, because they read two different ways and the difference is the whole
    /// of `Notebook.ReadingStrategy`: the first has a legacy rich-text body this
    /// build walks, while the second has one in PostHog's newer markdown generation
    /// that it cannot. Serving either file for both handles would put one
    /// notebook's body under the other's title *and* under the other's reading
    /// strategy, which is two wrong answers rather than one.
    private static let richDemoNotebook = "synthetic-id-0050"
    private static let plainTextDemoNotebook = "synthetic-id-0049"

    /// The four demo saved queries, matched in the **path** for a detail request
    /// and in the **query string** for a run history (`?saved_query_id=…`).
    ///
    /// Spelled once here because the two spellings have to agree: the run
    /// history of `example_meteor_delivery_failures` must arrive under
    /// `example_meteor_delivery_failures` and nowhere else. `warehouse_saved_queries.json`
    /// is the list all four come from.
    private static let failedSavedQuery = "018f9000-0000-7000-8000-000000000400"
    private static let modifiedSavedQuery = "018f9000-0000-7000-8000-000000000371"
    private static let plainSavedQuery = "018f9000-0000-7000-8000-000000000014"
    private static let healthySavedQuery = "018f9000-0000-7000-8000-000000000243"

    /// Every write the demo answers, and the only fixtures here built from the
    /// *request* rather than served whole.
    ///
    /// Routed by **method and path together**, because a create and a list share
    /// a path: `POST /annotations/` and `GET /annotations/` differ in nothing
    /// else, and `PATCH /surveys/:id/` sits under the same prefix as the survey
    /// list. Returns nil for every other pair, and the caller falls through to the
    /// ordinary read routing.
    ///
    /// The lifecycle writes below could have been left to fall through. They would
    /// have answered 200 by accident — a `POST …/surveys/:id/stop/` contains
    /// `/surveys/` and would have been served the survey *list* — and the screens
    /// would have looked correct, because none of them decodes a write's response
    /// and the optimistic override carries the change. Routing them explicitly
    /// costs little and buys two things: `DemoTransportTests` can drive the real
    /// `PostHogAPI` builders and assert that each one lands somewhere deliberate,
    /// and the demo answers each write with the object it claims to have changed
    /// rather than with a page of unrelated rows.
    private static func writeFixture(method: String, path: String, body: String) -> Reply? {
        if method == "POST", path.hasSuffix("/annotations/") {
            return createdAnnotation(body: body)
        }
        if let alert = alertWrite(method: method, path: path, body: body) {
            return alert
        }
        if let lifecycle = lifecycleWrite(method: method, path: path) {
            return lifecycle
        }
        return nil
    }

    // Deterministic fixture routing preserves the response shape and status for this case.

    private static func alertWrite(method: String, path: String, body: String) -> Reply? {
        guard path.contains("/alerts/") else { return nil }

        if method == "POST", path.hasSuffix("/alerts/") {
            return createdAlert(body: body)
        }
        if method == "PATCH" {
            return alertAfterWrite(path: path, body: body)
        }
        return nil
    }

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func createdAlert(body: String) -> Reply? {
        var submitted = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
            as? [String: Any] ?? [:]
        let now = Date()

        // The millisecond epoch rendered into the uuid tail, for the reason
        // `createdAnnotation` gives: two alerts written in one demo run must not
        // collide as `Identifiable`, and a `static var` counter reached from an
        // arbitrary task is exactly what strict concurrency is for.
        let suffix = String(format: "%012d", Int(now.timeIntervalSince1970 * 1000) % 1_000_000_000_000)
        submitted["id"] = "019e7a10-0000-0000-a1ff-\(suffix)"
        submitted["created_at"] = PostHogDate.iso8601(now)
        submitted["created_by"] = demoUser
        // A brand-new alert has not been evaluated yet, and every one of these is
        // a fact the server would not have. `Not firing` would claim a check that
        // never ran; the app's own `AlertState` keeps `unknown` for exactly this.
        submitted["state"] = "Not firing"
        submitted["last_notified_at"] = NSNull()
        submitted["last_checked_at"] = NSNull()
        submitted["next_check_at"] = NSNull()
        submitted["last_value"] = NSNull()
        submitted["checks"] = []
        submitted["snoozed_until"] = NSNull()

        if let insightID = submitted["insight"] as? Int {
            submitted["insight"] = demoInsightSummary(id: insightID)
        }
        if let userIDs = submitted["subscribed_users"] as? [Int] {
            submitted["subscribed_users"] = userIDs.map { _ in demoUser }
        }

        // 201, like the annotation create and unlike the lifecycle PATCHes: this
        // one makes a row.
        return (try? JSONSerialization.data(withJSONObject: submitted)).map { Reply($0, status: 201) }
    }

    /// The alert named in the path, with whichever field the PATCH carried moved.
    ///
    /// Matched by id rather than served as the first row, for the reason
    /// `surveyAfterWrite` documents: the screen that made the write is showing one
    /// particular alert, and answering with a neighbour's name decodes perfectly
    /// cleanly and is wrong.
    private static func alertAfterWrite(path: String, body: String) -> Reply? {
        guard let page = loadData("alerts"),
              let object = try? JSONSerialization.jsonObject(with: page) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              var row = results.first(where: { row in
                  guard let id = row["id"] as? String else { return false }
                  return path.contains("/alerts/\(id)/")
              })
        else { return nil }

        let submitted = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
            as? [String: Any] ?? [:]

        if let enabled = submitted["enabled"] as? Bool {
            row["enabled"] = enabled
        }

        // `snoozed_until` is the one field whose two directions have different
        // types: a **relative** duration string goes up ("4h", "1d") and a stored
        // datetime comes back, because the serializer runs the request value
        // through `relative_date_parse(…, increase=True, always_truncate=True)`.
        // The demo does the same arithmetic *including the truncation*, so what
        // the screen reads back is the shape and the rounding the real API would
        // produce rather than a flat now-plus-four-hours that would quietly teach
        // the wrong expectation. Key **present and null** is an unsnooze, and it
        // has to be distinguished from the key being absent — that distinction is
        // the whole reason `setAlertSnoozed` sends an explicit null.
        if submitted.keys.contains("snoozed_until") {
            if let duration = submitted["snoozed_until"] as? String {
                row["snoozed_until"] = snoozedUntil(duration).map(PostHogDate.iso8601) ?? NSNull()
                row["state"] = "Snoozed"
            } else {
                row["snoozed_until"] = NSNull()
                row["state"] = "Not firing"
            }
        }

        return (try? JSONSerialization.data(withJSONObject: row)).map { Reply($0) }
    }

    /// PostHog's `relative_date_parse(value, UTC, increase: true, alwaysTruncate:
    /// true)` for the four durations `AlertSnooze` offers, and nothing else.
    ///
    /// The truncation is the part worth reproducing: an `h` unit lands on the
    /// start of the hour and anything larger on the start of the day, so "1d" sent
    /// at 15:40 means *tomorrow at 00:00 UTC*, not twenty-four hours. A demo that
    /// added a flat interval would show a plausible time that the real server
    /// would never return.
    private static func snoozedUntil(_ duration: String, from now: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc

        let hours: Int
        switch duration {
        case "1h": hours = 1
        case "4h": hours = 4
        case "8h": hours = 8
        case "1d":
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
            return tomorrow.map { calendar.startOfDay(for: $0) }
        default:
            // A duration this build does not model. Answering `null` would read
            // as "unsnoozed", so the field is left alone by returning nothing and
            // the caller writes null — which is the honest answer for a request
            // this demo cannot interpret.
            return nil
        }

        guard let raised = calendar.date(byAdding: .hour, value: hours, to: now) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: raised)
        return calendar.date(from: parts)
    }

    /// `alerts.json`, narrowed by `insight_id` when the request carried one.
    ///
    /// The filter is applied because the endpoint applies it — `safely_get_queryset`
    /// reads `insight_id` off the query string — and a demo that returned the whole
    /// list for a filtered request would put the funnel's alert on the trends
    /// insight's screen. `count` is rewritten to match, because a page whose
    /// `count` disagrees with its `results` is a page that teaches a caller to
    /// distrust both.
    private static func alertsPage(query: String) -> Reply {
        guard let page = loadData("alerts") else { return unrouted("/alerts/") }
        guard let insightID = URLComponents(string: "?\(query)")?
            .queryItems?
            .first(where: { $0.name == "insight_id" })?
            .value
        else { return Reply(page) }

        guard var object = try? JSONSerialization.jsonObject(with: page) as? [String: Any],
              let results = object["results"] as? [[String: Any]]
        else { return Reply(page) }

        let matching = results.filter { row in
            guard let insight = row["insight"] as? [String: Any],
                  let id = insight["id"] as? Int
            else { return false }
            return String(id) == insightID
        }
        object["results"] = matching
        object["count"] = matching.count
        guard let filtered = try? JSONSerialization.data(withJSONObject: object) else {
            return Reply(page)
        }
        return Reply(filtered)
    }

    /// The demo identity, in the `UserBasicSerializer` shape alerts embed.
    ///
    /// Read out of `users_me.json` rather than written twice, so the byline on a
    /// demo-created alert is the same person the rest of the demo says you are.
    private static var demoUser: [String: Any] {
        guard let data = loadData("users_me"),
              let me = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return [
            "id": me["id"] ?? 0,
            "uuid": me["uuid"] ?? "",
            "distinct_id": me["distinct_id"] ?? "",
            "first_name": me["first_name"] ?? "",
            "last_name": me["last_name"] ?? "",
            "email": me["email"] ?? "",
        ]
    }

    /// The `InsightBasicSerializer` object an alert response nests, built from the
    /// insight the demo actually has under that id.
    ///
    /// Falls back to the bare id rather than inventing a name: an alert labelled
    /// with somebody else's insight is the failure `experimentDetail` documents at
    /// length, and `InsightAlert.displayTitle` already degrades to "Untitled
    /// alert" when there is no name to be had.
    private static func demoInsightSummary(id: Int) -> [String: Any] {
        guard let data = loadData("insights_list"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let insight = results.first(where: { $0["id"] as? Int == id })
        else { return ["id": id] }

        return [
            "id": id,
            "short_id": insight["short_id"] ?? NSNull(),
            "name": insight["name"] ?? NSNull(),
            "derived_name": insight["derived_name"] ?? NSNull(),
        ]
    }

    /// The app's one write that produces a visible new row.
    ///
    /// A demo that swallowed it would show the composer's confirmation, the sheet
    /// closing and then nothing — indistinguishable from a bug in the optimistic
    /// insert. Every other write the app makes mutates a row that is already in a
    /// fixture.
    ///
    /// This echoes the submitted fields back with a synthetic id, which is what
    /// PostHog does apart from the id being real. It is deliberately **not** a
    /// stored fixture: a canned annotation would show text nobody typed, and the
    /// whole point of exercising this path is watching your own words land on the
    /// right day. `created_by` is filled from the demo identity so the byline is
    /// not blank; nothing else is invented.
    private static func createdAnnotation(body: String) -> Reply? {
        let now = Date()
        var submitted = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
            as? [String: Any] ?? [:]
        // The millisecond epoch, not a counter. Two annotations written in one
        // demo run must not collide as `Identifiable` — that would collapse them
        // to one row and make the second look like it was never written — and a
        // `static var` incremented from `send` is a mutable global reached from
        // an arbitrary task, which is exactly what strict concurrency is for. A
        // clock is monotonic enough for a value that only has to be distinct from
        // the other values in one session, and no two sheet dismissals share a
        // millisecond. Far above any id in the fixtures, so a demo annotation
        // can never be mistaken for a fixture row.
        submitted["id"] = Int(now.timeIntervalSince1970 * 1000)
        submitted["created_at"] = PostHogDate.iso8601(now)
        submitted["updated_at"] = PostHogDate.iso8601(now)
        submitted["created_by"] = ["first_name": "Demo", "last_name": "User", "email": ""]
        // 201, alone among the writes here: this one creates a row. The lifecycle
        // writes below all answer 200 with the object they changed, which is what
        // PostHog's own actions return.
        return (try? JSONSerialization.data(withJSONObject: submitted)).map { Reply($0, status: 201) }
    }

    // Deterministic fixture routing preserves the response shape and status for this case.

    private static func lifecycleWrite(method: String, path: String) -> Reply? {
        if method == "POST", path.contains("/experiments/") {
            // `end/` writes `end_date` and the conclusion and leaves the linked
            // flag alone; `pause/`/`resume/` write nothing on the experiment at
            // all and move `status`, which PostHog derives from the flag.
            if path.hasSuffix("/end/") {
                return experimentAfterWrite(path: path, endDate: Date(), status: "stopped")
            }
            if path.hasSuffix("/pause/") {
                return experimentAfterWrite(path: path, endDate: nil, status: "paused")
            }
            if path.hasSuffix("/resume/") {
                return experimentAfterWrite(path: path, endDate: nil, status: "running")
            }
        }

        if path.contains("/surveys/") {
            // A survey has no `status` field — 37 keys and none of them is one —
            // so all three of these move a *date* and nothing else, which is the
            // same thing the real endpoints do.
            if method == "POST", path.hasSuffix("/stop/") {
                return surveyAfterWrite(path: path, action: "stop")
            }
            if method == "POST", path.hasSuffix("/launch/") {
                return surveyAfterWrite(path: path, action: "launch")
            }
            // The resume, and the one route here that has to be told apart from a
            // *read* by its method alone: `PATCH /surveys/:id/` and
            // `GET /surveys/:id/` are the same path.
            if method == "PATCH" {
                return surveyAfterWrite(path: path, action: "resume")
            }
        }

        return nil
    }

    /// The experiment named in the path, with the field its action moves.
    ///
    /// Built from the same fixtures `experimentDetail` serves, so an experiment
    /// paused from the sheet answers with the experiment the sheet is showing
    /// rather than with a neighbour.
    private static func experimentAfterWrite(
        path: String,
        endDate: Date?,
        status: String
    ) -> Reply? {
        // `/experiments/71101/pause/` — trim the action so the detail lookup, which
        // matches `/experiments/<id>/`, still finds the row.
        let base = path.split(separator: "/").dropLast().joined(separator: "/")
        let detail = experimentDetail(for: "/\(base)/")
        guard detail.status == 200,
              var object = try? JSONSerialization.jsonObject(with: detail.data) as? [String: Any]
        else { return nil }

        object["status"] = status
        if let endDate { object["end_date"] = PostHogDate.iso8601(endDate) }
        return (try? JSONSerialization.data(withJSONObject: object)).map { Reply($0) }
    }

    /// The survey named in the path, with its dates moved the way the action moves
    /// them.
    private static func surveyAfterWrite(path: String, action: String) -> Reply? {
        guard let page = loadData("surveys"),
              let object = try? JSONSerialization.jsonObject(with: page) as? [String: Any],
              let results = object["results"] as? [[String: Any]]
        else { return nil }

        // Matched by id rather than served as the first row: the sheet that made
        // the write is showing one particular survey, and answering with another
        // one's name is the failure `experimentDetail` documents at length.
        guard var row = results.first(where: { row in
            guard let id = row["id"] as? String else { return false }
            return path.contains("/surveys/\(id)/")
        }) else { return nil }

        let now = PostHogDate.iso8601(Date())
        switch action {
        case "stop": row["end_date"] = now
        case "launch": row["start_date"] = now
        // Resume clears the end date and touches nothing else — the same one key
        // the real PATCH carries.
        default: row["end_date"] = NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: row)).map { Reply($0) }
    }

    private static func fixture(for path: String, body: String, query: String) -> Reply {
        // Deterministic fixture routing preserves the response shape and status for this case.
        if path.hasSuffix("/query/") {
            // Web analytics: six sections, six kinds, one screen.
            if body.contains("WebOverviewQuery") { return load("web_overview") }
            if body.contains("WebStatsTableQuery") { return load("web_stats") }
            if body.contains("WebVitalsPathBreakdownQuery") { return load("web_vitals") }
            if body.contains("WebExternalClicksTableQuery") { return load("web_external_clicks") }
            if body.contains("WebNotableChangesQuery") { return load("web_notable_changes") }
            // Deterministic fixture routing preserves the response shape and status for this case.
            if body.contains("MarketingAnalyticsTableQuery") { return load("marketing_analytics") }

            if body.contains("ErrorTrackingQuery") { return load("error_tracking") }

            // The stack trace behind one issue. `errorIssueOccurrence` is a
            // *HogQL* query, so this has to be matched above the generic
            // `HogQLQuery` line below or the events fixture answers it — and
            // that failure is quiet, because the events fixture decodes fine and
            // simply carries no `exception_list`, so `ExceptionOccurrence.first`
            // finds nothing and the screen draws "no stored exception event was
            // found" over an issue that has one. Which is exactly what the demo
            // did before this route existed: the whole stack-trace screen, from
            // the frame list to the minified caveat to the disclosure of
            // PostHog's resolve failures, was unreachable and therefore under no
            // UI audit and in no screenshot.
            //
            // Keyed on `$exception_issue_id`, which appears in no other SQL this
            // app builds (`PostHogAPI+ErrorTracking` is its only writer), and
            // then on the issue id itself — because the three demo issues
            // deliberately do not all answer the same thing.
            if body.contains(exceptionIssueColumn) {
                if body.contains(unresolvedFramesIssue) { return load("exception_unresolved_frames") }
                if body.contains(resolvedFrameIssue) { return load("exception_resolved_frame") }
                // Deterministic fixture routing preserves the response shape and status for this case.
                return Reply(emptyQueryResult)
            }

            // Deterministic fixture routing preserves the response shape and status for this case.
            if body.contains("ExperimentExposureQuery") {
                return body.contains(completedExperimentName)
                    ? load("experiment_exposures_complete")
                    : load("experiment_exposures_running")
            }
            // Deterministic fixture routing preserves the response shape and status for this case.
            if body.contains("ExperimentQuery") {
                if body.contains(funnelMetricUUID) { return load("experiment_result_funnel") }
                if body.contains(meanMetricUUID) { return load("experiment_result_mean") }
                if body.contains(shippedMetricUUID) { return load("experiment_result_shipped") }
                return Reply(emptyQueryResult)
            }

            // Data taxonomy. `TeamTaxonomyQuery` must be tested before
            // `EventTaxonomyQuery` only to read in the order the screens load.
            if body.contains("TeamTaxonomyQuery") { return load("team_taxonomy") }
            // Deterministic fixture routing preserves the response shape and status for this case.
            if body.contains("EventTaxonomyQuery") {
                guard !body.contains("\"properties\"") else {
                    return unroutedQueryKind(
                        "EventTaxonomyQuery with named properties",
                        because: """
                            the only deterministic fixture of this kind is its discovery form, for $pageview. \
                            Answering the named form from it would put one property's values under \
                            another property's name.
                            """
                    )
                }
                return load("event_taxonomy")
            }
            // The actor-side counterpart, and the **only** thing that answers for
            // a property living on a person or a group rather than on an event —
            // `TaxonomyPropertyDetailView.loadActorSample` is its one caller, and
            // it is the whole of that screen for a group-scoped property.
            //
            // Reads as though `EventTaxonomyQuery` above could shadow it and it
            // cannot: "ActorsPropertyTaxonomyQuery" contains "PropertyTaxonomy
            // Query", not "EventTaxonomyQuery". Order here is for reading.
            //
            // The fixture is one row, because the request names one property
            // and the response is positional and parallel to that array —
            // `TaxonomyPropertySample.zip` is the join, and a second row would be
            // attributed to a property nobody asked about.
            if body.contains("ActorsPropertyTaxonomyQuery") {
                return load("actors_property_taxonomy")
            }

            if body.contains("GroupsQuery") { return load("groups") }
            if body.contains("TracesQuery") { return load("llm_traces") }

            // Chart drill-down. One fixture answers every drill, which is the
            // honest limit of one deterministic fixture: the demo cannot show that funnel
            // step 2 and step 3 hold *different* people, only that asking the
            // question reaches an answer at all.
            //
            // Its own envelope, not `QueryResponse`'s — `hasMore` and
            // `missing_actors_count` have no equivalent there. The fixture
            // deliberately keeps a non-zero `missing_actors_count` and one
            // unresolved person (`is_unresolved`, no properties at all): both
            // are supported response shapes, and both are states the sheet renders
            // differently, and a tidied fixture would leave them untested.
            if body.contains("ActorsQuery") { return load("insight_actors") }

            // Deterministic fixture routing preserves the response shape and status for this case.
            if body.contains("EndpointsUsageOverviewQuery") { return load("endpoints_usage_overview") }
            if body.contains("EndpointsUsageTableQuery") { return load("endpoints_usage_table") }

            // The SQL schema browser, and it has to be matched **above** the
            // generic `HogQLQuery` line rather than beside it: both of its
            // queries *are* `HogQLQuery`, so the line below would answer them
            // with the events fixture. That fixture has no `table_name`
            // column, so every row would decode to nil and the browser would
            // draw "No tables" over a 141-table project — empty rather than
            // wrong-shaped, which is the better of the two failures and still
            // makes the feature unreachable in demo mode.
            //
            // Matched on the SQL the builders emit rather than on a kind name,
            // which is the exception this file's header warns about: `information
            // _schema.tables` and `information_schema.columns` are what tells the
            // two apart, and the table name inside the `WHERE` is what selects
            // between the column fixtures.
            if body.contains("information_schema.tables") { return load("schema_tables") }
            if body.contains("information_schema.columns") {
                if body.contains("'events'") { return load("schema_columns_events") }
                if body.contains("'persons'") { return load("schema_columns_persons") }
                if body.contains("'sessions'") { return load("schema_columns_sessions") }
                // Deterministic fixture routing preserves the response shape and status for this case.
                return Reply(emptyQueryResult)
            }

            // Group analytics and property depth: four more HogQL queries, and
            // the same hazard the schema and survey routes carry. Every one of
            // them is a `HogQLQuery`, so without these lines the events
            // fixture below answers all four — and it answers them *quietly*,
            // because `query_hogql.json` decodes as a perfectly good
            // `QueryResponse` and simply lacks their columns. Measured against
            // the demo fixture: it has no `distinct_people`, so the group screen
            // read "0 people" over a group with six; no `people`, so every event
            // in the breakdown showed no-one; and no `value`/`occurrences` pair,
            // so a property's whole value distribution came back empty. Four
            // screens' worth of empty states over data that is right here.
            //
            // Keyed on the **SQL the builders emit**, not on a kind name, which
            // is the exception this file's header warns about and the same one
            // `information_schema` takes above. `PostHogAPI+Groups` is the only
            // writer of all four, and the markers below are checked against it:
            //
            //   groupPeople               `uniqExact(person_id) OVER () AS distinct_people`
            //   groupEventBreakdown       `uniq(person_id) AS people,`
            //   propertyValueDistribution `… AS distinct_values` + `GROUP BY value`
            //   propertyCarrierEvents     `… AS distinct_values,` + `GROUP BY event`
            //
            // No marker appears in another of the four: the breakdown selects
            // `distinct_events`, never `distinct_values`, and the people query
            // selects `distinct_people`, never a bare `people`. The last two are
            // the only pair that share one — both compute `distinct_values` —
            // and what separates them is what they group by, which is also the
            // difference in what they mean: one row per value of a property
            // versus one row per event carrying it. A route that served the
            // first to the second would list property values under a column
            // headed "Event", with plausible counts. That is the wrong-answer
            // class the experiment and survey routes are split to avoid.
            //
            // `groupEvents` is deliberately **not** routed here. It is built
            // through `eventsSQL`, selects the events feed's own columns, and is
            // therefore one of the few HogQL queries the fixture below answers
            // honestly rather than emptily.
            if body.contains("AS distinct_people") { return load("group_people") }
            if body.contains("uniq(person_id) AS people") { return load("group_event_breakdown") }
            if body.contains("AS distinct_values") {
                return body.contains("GROUP BY value")
                    ? load("property_value_distribution")
                    : load("property_carrier_events")
            }

            // Deterministic fixture routing preserves the response shape and status for this case.
            if body.contains(surveyIDColumn) {
                guard body.contains(launchedDemoSurvey) else { return Reply(emptyQueryResult) }
                return body.contains("AS impressions")
                    ? load("survey_results_summary")
                    : load("survey_answers")
            }

            // A session timeline is a HogQL query too, but the generic SQL-console
            // fixture belongs to a different fictional date range. Returning it
            // here placed four otherwise-valid events thousands of hours past the
            // ten-second replay. Keep the route keyed to the builder's materialised
            // session column so the canonical replay, summary and event timeline
            // share one clock without changing arbitrary HogQL results.
            if isCanonicalSessionTimelineQuery(body) { return load("session_events") }

            // The generic HogQL fixture, and it is the events feed's.
            //
            // **Not "the two screens backed by HogQL"**, which is what this said
            // and was already false when it was written: the survey routes above,
            // `PersonDetailView`'s recent-events query and
            // `SessionTimelineStore`'s session query are all `HogQLQuery` too,
            // and every one of them reaches this line unless something above
            // claims it first. That is the whole hazard this fallback carries —
            // an events fixture decodes cleanly as any of their responses and
            // simply lacks the columns they read, so the screen draws an empty
            // state rather than an error. The person and session queries survive
            // it because they select the events columns this fixture has; the
            // survey ones did not.
            if body.contains("HogQLQuery") { return load("query_hogql") }

            // Deterministic fixture routing preserves the response shape and status for this case.
            return Reply(emptyQueryResult)
        }

        if path.contains("/snapshots") {
            return query.contains("blob_v2")
                ? load("snapshot_blobs", ext: "jsonl")
                : load("snapshot_sources")
        }

        if path.contains("/users/") { return load("users_me") }

        // Organization switching, and the **only route here outside
        // `/api/projects/…`** — so it is matched on its own prefix rather than
        // on a resource segment, the way `/llm_analytics/@me/spend/` is below.
        //
        // Without it `AppModel.selectOrganization` fetched the empty page, and
        // `selectOrganization` is the one place in the app already written not to
        // read zero results as success: it refuses the switch and says the key
        // may not be able to see the projects. So the demo's answer was not a
        // blank screen but a *plausible sentence about the reader's API key*,
        // for a demo that has no API key at all.
        //
        // Keyed on the organization id, because the two demo organizations hold
        // different projects and serving one fixture to both would show the
        // second organization the first's project — the class of wrong answer
        // the experiment and survey routes are split to avoid.
        if path.hasPrefix("/api/organizations/") && path.hasSuffix("/projects/") {
            return path.contains(secondDemoOrganization)
                ? load("organization_projects_second")
                : load("organization_projects")
        }

        // The consumption trio. All three answer a **bare object**, not a
        // `Page`, so the empty-page fallback below cannot stand in for a missing
        // route: `{"count":0,…,"results":[]}` decodes as a `QuotaLimits` with no
        // resources and an `SDKHealthReport` with no verdict, which reads as
        // "you have no quota problems" — a failure that looks exactly like good
        // news, and the one answer worse than an error.
        //
        // `/llm_analytics/@me/spend/` is the only route here with no project
        // segment; it is matched on the resource, not the prefix.
        if path.hasSuffix("/quota_limits/") { return load("quota_limits") }
        if path.contains("/sdk_health/") { return load("sdk_health_report") }
        if path.contains("/llm_analytics/") && path.hasSuffix("/spend/") { return load("llm_spend") }

        // Dashboard detail is deliberately exact so an invented id cannot look valid.
        if path.contains("/dashboards/") {
            if path.hasSuffix("/dashboards/") { return load("dashboards_list") }
            if path.hasSuffix("/dashboards/\(dashboardID)/") { return load("dashboard_detail_raw") }
            if path.hasSuffix("/dashboards/\(Self.hogQLDashboardID)/") {
                return load("dashboard_hogql_visualizations")
            }
            if path.hasSuffix("/dashboards/\(Self.emptyDashboardID)/") {
                return load("dashboard_empty_tiles")
            }
            return unrouted(path)
        }

        if path.contains("/feature_flags/") { return load("feature_flags") }
        if path.contains("/exports/") { return load("exports") }

        // Deterministic fixture routing preserves the response shape and status for this case.
        if path.contains("/alerts/") {
            return path.hasSuffix("/alerts/")
                ? alertsPage(query: query)
                : unrouted(path)
        }

        // **Two products, one prefix.** `/conversations/tickets/` is Support;
        // `/conversations/` on its own is Max's assistant threads, which is a
        // different product with a different payload. The tickets route is
        // matched on the *full* four-segment path and nothing here matches
        // `/conversations/` alone — a route that did would shadow whichever of
        // the two came second, and it would do it silently, because both answer
        // a well-formed `Page`. Max has no fixture, so it falls through to the
        // empty page below, which is the honest stand-in and must stay
        // reachable. `DemoTransportTests` asserts both halves of that.
        //
        // Each route serves its separately declared synthetic fixture so their
        // distinct response shapes remain deterministic.
        if path.contains("/conversations/tickets/") {
            if path.hasSuffix("/messages/") { return load("conversations_ticket_messages") }
            // Same list-versus-detail split as dashboards: the list ends in
            // `tickets/`, a detail request ends in an id.
            return path.hasSuffix("/tickets/")
                ? load("conversations_tickets")
                : firstResult(in: "conversations_tickets")
        }

        // A **bare array**, not a `Page` — so the generic empty-page fallback
        // below cannot serve this path: `[IngestionWarning]` does not decode
        // from `{"results":[]}`, and the screen would show a decoding error
        // instead of an empty state.
        if path.contains("/ingestion_warnings_v2/") { return load("ingestion_warnings_v2") }
        // The second bare array, and the one that was missing. Without this route
        // the fallback handed `{"count":0,…,"results":[]}` to a `[GroupType]`
        // decode and the Groups screen rendered "Couldn't load groups —
        // DecodingError.typeMismatch … Expected to decode Array<Any> but found a
        // dictionary instead" — a Swift type name shown to a user, for a project
        // that has two perfectly good group types.
        // The one route here whose response is **not JSON**. `/content/` serves
        // the rendered page image, so it answers bytes the JSON fallback below
        // could never stand in for — handed `{"count":0,…}`, the image decoder
        // fails and the overlay shows a read error instead of a page.
        if path.contains("/heatmap_screenshots/") {
            return path.contains("/content/")
                ? Reply(demoPageRender)
                : load("heatmap_screenshots_saved")
        }

        if path.contains("/groups_types/") { return load("groups_types") }
        // Deterministic fixture routing preserves the response shape and status for this case.
        if path.contains("/event_definitions/") { return load("event_definitions") }
        // The **property** definitions, which are a different resource and were
        // unrouted — `/property_definitions/` does not contain
        // `/event_definitions/`, so the line above never covered it.
        //
        // Two screens ask, and the missing route cost them differently. The
        // Taxonomy root's Properties tab asked project-wide and got 501, so the
        // whole tab was a failure state. `TaxonomyEventDetailView` asked for one
        // event's properties, caught its own failure separately, and therefore
        // showed the properties with *every* curation state missing: no type, no
        // verified mark, no description, on a screen whose reason to exist is
        // showing exactly those.
        //
        // One deterministic fixture answers both, and the difference is worth stating
        // because it is an overclaim in the narrow direction. The scoped
        // scoped call sends `event_names` + `filter_by_event_names` and comes
        // back with a *subset*; this serves the project's first 200 of 386 to
        // both. That is safe only because the scoped caller uses the result as a
        // **lookup table** — `Dictionary(page.results.map { ($0.name, $0) })`,
        // read by the property names the taxonomy sample already returned — so
        // an extra definition for a property that event does not carry is never
        // looked up and never drawn. Nothing here iterates the page as "this
        // event's properties"; if something ever does, it needs its own fixture.
        if path.contains("/property_definitions/") { return load("property_definitions") }
        if path.contains("/dashboard_templates/") { return load("dashboard_templates") }
        // The count sub-resource has its own envelope and is checked first, so
        // `/comments/count/` never falls through to the thread fixture.
        if path.hasSuffix("/comments/count/") { return Reply(Data(#"{"count":4}"#.utf8)) }
        if path.contains("/comments/") { return load("comments") }

        // AI session summaries. Checked **before** `/session_recordings/`
        // although the two paths do not overlap, because both are keyed on the
        // same synthetic session id. The summary and recording for
        // `018f1000-0000-7000-8000-000000000001` must stay aligned so the demo
        // can navigate between them.
        //
        // The detail route serves its fixture for whichever id reaches it, which
        // is the same stand-in convention as `firstResult` below — but only for
        // the one session this admits to having a summary. Every other synthetic
        // id deliberately returns 404 to exercise the no-summary state.
        //
        // That 404 is deliberate rather than a missing fixture. Serving 200 for
        // every id would make the demo unable to show the no-summary state and
        // would let a regression turning it into an error card go unnoticed.
        // The status is spelled beside the body it belongs to; the separate
        // `status(for:)` that used to decide it is gone.
        if path.contains("/single_session_summaries/") {
            if path.hasSuffix("/single_session_summaries/") {
                return load("single_session_summaries")
            }
            return path.contains(summarisedDemoSession)
                ? load("single_session_summary")
                : Reply(noStoredSummary, status: 404)
        }

        // Deterministic fixture routing preserves the response shape and status for this case.
        if path.contains("/session_recording_playlists/") {
            guard !path.hasSuffix("/session_recording_playlists/") else {
                return load("session_recording_playlists")
            }
            guard path.hasSuffix("/recordings/") else {
                return firstResult(in: "session_recording_playlists")
            }
            return path.contains("/example-orbit-overview/")
                || path.contains("/example-reviewed-orbits/")
                ? load("session_recording_playlist_recordings")
                : Reply(emptyPlaylistRecordings)
        }

        if path.contains("/session_recordings/") {
            guard path.hasSuffix("/session_recordings/") else {
                return firstResult(in: "session_recordings")
            }
            return filteredRecordings(query: query)
        }
        if path.contains("/persons/") { return load("persons") }
        if path.contains("/cohorts/") { return load("cohorts") }
        if path.contains("/surveys/") { return load("surveys") }
        // Split for the same reason `/session_recordings/` is, and it became
        // reachable the moment the saved-insight library shipped a detail
        // screen: that screen fetches one insight by short id, and a `Page`
        // cannot decode as a single `Insight`, so the page fixture on the
        // detail path fails as a *decoding* error — which reads on screen as a
        // broken insight rather than as a missing fixture.
        if path.contains("/insights/") {
            guard path.hasSuffix("/insights/") else { return firstResult(in: "insights_list") }
            return insightPage(query: query)
        }
        // The list/detail split again, but the detail cannot be `firstResult`:
        // the list uses PostHog's leaner `ExperimentBasicSerializer`, which
        // **defers `metrics`, `metrics_secondary` and `stats_config`**, and those
        // three are exactly what the results sheet cannot be drawn without. A
        // row served as its own detail would give a launched experiment no
        // metrics at all, and the sheet would say "This experiment has no
        // metrics attached" about one that has them — a sentence that is not
        // merely empty but false.
        if path.contains("/experiments/") {
            return path.hasSuffix("/experiments/")
                ? load("experiments")
                : experimentDetail(for: path)
        }

        // The project object index. Its rows carry the same ids as the fixtures
        // above, so a result tapped in the demo lands on the same dashboard,
        // flag or survey the product screens show.
        if path.contains("/file_system/") { return load("file_system") }

        // Notebooks. The list/detail split again, and the detail is matched on
        // the **short id** because that is what the viewset looks up
        // (`lookup_field = "short_id"`; the uuid form is a 404).
        //
        // `firstResult` is wrong here in a way the other list/detail pairs are
        // not, and the reason is not the payload but the *screen*:
        // `NotebookDetailView` re-titles itself from whatever the detail
        // returns, so serving one notebook's body for every handle renames the
        // document the reader opened as it loads. Two handles, two files.
        //
        // A third handle answers 501 rather than borrowing one of the two. That
        // is the honest answer — this demo has two notebooks — and it is also
        // the only way the detail screen's own `LoadFailureState` stays
        // reachable, which matters more than usual here: that state exists
        // because this exact path used to print a `DecodingError` dump at the
        // reader when it fell through unrouted.
        if path.contains("/notebooks/") {
            if path.hasSuffix("/notebooks/") { return load("notebooks_list") }
            if path.contains("/\(richDemoNotebook)/") { return load("notebook_detail") }
            if path.contains("/\(plainTextDemoNotebook)/") { return load("notebook_detail_plain") }
            return unrouted(path)
        }

        // Deterministic fixture routing preserves the response shape and status for this case.
        if path.contains("/warehouse_saved_queries/") {
            return path.hasSuffix("/warehouse_saved_queries/")
                ? load("warehouse_saved_queries")
                : savedQueryDetail(for: path)
        }
        if path.contains("/data_modeling_jobs/") {
            return dataModelingJobs(path: path, query: query)
        }

        // Deterministic fixture routing preserves the response shape and status for this case.
        if knownEmptyCollections.contains(where: path.hasSuffix) {
            return Reply(emptyPage)
        }
        return unrouted(path)
    }

    /// A fixture as a 200 reply.
    ///
    /// A miss is **500, not an empty page**, for the reason `unrouted` gives at
    /// length: a fixture named here and absent from the bundle is a build
    /// problem, and answering it with a well-formed empty collection turns a
    /// missing file into a screen that says the project has nothing. The name is
    /// in the message because that is the only thing that identifies which
    /// resource failed to copy.
    private static func load(_ name: String, ext: String = "json") -> Reply {
        guard let data = loadData(name, ext: ext) else {
            return Reply(
                envelope(
                    "demo_fixture_unreadable",
                    "\(name).\(ext) is routed by DemoTransport but is not in the app bundle."
                ),
                status: 500
            )
        }
        return Reply(data)
    }

    /// The same bytes, for the three routes that re-shape a fixture rather than
    /// serving it whole.
    private static func loadData(_ name: String, ext: String = "json") -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: "DemoData/\(name)", withExtension: ext)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Serves a collection fixture's first row as a detail response.
    ///
    /// The ids in the fixture are not the ones a detail request asks
    /// for, and matching on them would only mean answering 404 to every link the
    /// demo offers. The first row is the honest stand-in.
    private static func firstResult(in name: String) -> Reply {
        guard let page = loadData(name),
              let object = try? JSONSerialization.jsonObject(with: page) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let first = results.first,
              let data = try? JSONSerialization.data(withJSONObject: first)
        else {
            // Not an empty page: the caller asked for one object, and an empty
            // `Page` is not one — it would reach the screen as a decoding error
            // whose text names a Swift type. This says which fixture had no
            // first row instead.
            return Reply(
                envelope(
                    "demo_fixture_unreadable",
                    "\(name).json has no first row to serve as a detail response."
                ),
                status: 500
            )
        }
        return Reply(data)
    }

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func experimentDetail(for path: String) -> Reply {
        if path.contains("/experiments/\(runningExperimentID)/") {
            return load("experiment_detail_running")
        }
        if path.contains("/experiments/\(completedExperimentID)/") {
            return load("experiment_detail_complete")
        }
        guard let page = loadData("experiments"),
              let object = try? JSONSerialization.jsonObject(with: page) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let row = results.first(where: { row in
                  guard let id = row["id"] as? Int else { return false }
                  return path.contains("/experiments/\(id)/")
              }) ?? results.first,
              let data = try? JSONSerialization.data(withJSONObject: row)
        else {
            return Reply(
                envelope(
                    "demo_fixture_unreadable",
                    "experiments.json has no row to serve as an experiment detail."
                ),
                status: 500
            )
        }
        return Reply(data)
    }

    /// One query item's value, decoded, from the raw query string.
    ///
    /// `URLComponents(string: "?\(query)")` rather than splitting on `&` and
    /// `=`, because several of these values are whole JSON blobs —
    /// `having_predicates` and `properties` both carry `[`, `{`, `"` and `:`
    /// percent-encoded — and only the components parser puts them back. A hand
    /// split would hand `filteredRecordings` a string `JSONSerialization`
    /// rejects, and the filter would silently stop filtering.
    private static func queryValue(_ name: String, in query: String) -> String? {
        guard !query.isEmpty else { return nil }
        return URLComponents(string: "?\(query)")?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func insightPage(query: String) -> Reply {
        let page = load("insights_list")
        guard let shortID = queryValue("short_id", in: query),
              var object = try? JSONSerialization.jsonObject(with: page.data) as? [String: Any],
              let rows = object["results"] as? [[String: Any]]
        else { return page }

        let matched = rows.filter { ($0["short_id"] as? String) == shortID }
        object["results"] = matched
        // Deterministic fixture routing preserves the response shape and status for this case.
        object["count"] = matched.count
        object["next"] = NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return page }
        return Reply(data)
    }

    /// One saved query in full, chosen by the id in the path.
    ///
    /// Each of the four demo views has its own file, and the reason is the same
    /// one `experimentDetail` gives: the detail serializer carries two fields the
    /// list one does not — `query`, the SQL, and `suspended`, the state the
    /// list-level banner structurally cannot see — and those two are what each
    /// row exists to demonstrate. A shared stand-in would show
    /// `example_moonbase_first_touch`'s SQL under `example_meteor_delivery_failures`, and a
    /// memory-limit suspension under a view that has none.
    ///
    /// An id in no fixture answers 501 rather than falling back to a first row.
    /// Nothing in the demo links to a fifth view, there is no deep link into one,
    /// and a borrowed definition here is precisely the wrong answer above.
    private static func savedQueryDetail(for path: String) -> Reply {
        if path.contains("/\(failedSavedQuery)/") { return load("warehouse_saved_query_failed") }
        if path.contains("/\(modifiedSavedQuery)/") { return load("warehouse_saved_query_modified") }
        if path.contains("/\(plainSavedQuery)/") { return load("warehouse_saved_query_plain") }
        if path.contains("/\(healthySavedQuery)/") { return load("warehouse_saved_query_healthy") }
        return unrouted(path)
    }

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func dataModelingJobs(path: String, query: String) -> Reply {
        switch queryValue("saved_query_id", in: query) {
        case failedSavedQuery: return load("data_modeling_jobs")
        case healthySavedQuery: return load("data_modeling_jobs_healthy")
        case plainSavedQuery: return Reply(emptyPage)
        default: return unrouted(path)
        }
    }

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static let demoPageRender: Data = {
        let width = 375
        let height = 4_000
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return emptyPage }

        context.setFillColor(gray: 0.96, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(gray: 0.78, alpha: 1)
        context.fill(CGRect(x: 0, y: height - 80, width: width, height: 80))

        for index in 0..<12 {
            let top = 160 + index * 300
            context.setFillColor(gray: index.isMultiple(of: 2) ? 0.86 : 0.90, alpha: 1)
            context.fill(CGRect(x: 20, y: height - top - 220, width: width - 40, height: 220))
        }

        guard let image = context.makeImage() else { return emptyPage }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return emptyPage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return emptyPage }
        return out as Data
    }()

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func recordingColumn(forPredicateKey key: String) -> String {
        key == "duration" ? "recording_duration" : key
    }

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static let emptyPlaylistRecordings =
        Data(#"{"results":[],"has_next":false,"version":4}"#.utf8)

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func filteredRecordings(query: String) -> Reply {
        // Deterministic fixture routing preserves the response shape and status for this case.
        let items = URLComponents(string: "?\(query)")?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        // Read out of the decoded `properties` blob rather than by scanning the
        // raw query for `$group_`. `URLComponents` leaves `$` unescaped and
        // escapes the braces around it, so a substring match would work today
        // and would depend on which characters Foundation happens to consider
        // query-safe — a match that quietly stops matching is exactly how the
        // trailing-slash bug at the top of this file survived.
        let isGroupScoped = value("properties")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { $0 as? [[String: Any]] }?
            .contains { ($0["key"] as? String)?.hasPrefix("$group_") == true } ?? false

        let page = load(isGroupScoped ? "group_session_recordings" : "session_recordings")
        guard !query.isEmpty,
              var object = try? JSONSerialization.jsonObject(with: page.data) as? [String: Any],
              var rows = object["results"] as? [[String: Any]]
        else { return page }

        if let raw = value("having_predicates"),
           let data = raw.data(using: .utf8),
           let predicates = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for predicate in predicates {
                guard let key = predicate["key"] as? String,
                      let op = predicate["operator"] as? String,
                      let threshold = Double("\(predicate["value"] ?? "")")
                else { continue }
                let column = recordingColumn(forPredicateKey: key)
                rows = rows.filter { row in
                    guard let actual = (row[column] as? NSNumber)?.doubleValue else { return false }
                    switch op {
                    // Deterministic fixture routing preserves the response shape and status for this case.
                    case "gte": return actual >= threshold
                    case "gt": return actual > threshold
                    case "lte": return actual <= threshold
                    case "lt": return actual < threshold
                    case "exact": return actual == threshold
                    default: return true
                    }
                }
            }
        }

        if let order = value("order") {
            let descending = value("order_direction")?.uppercased() != "ASC"
            rows.sort { a, b in
                let left = (a[order] as? NSNumber)?.doubleValue
                let right = (b[order] as? NSNumber)?.doubleValue
                // Deterministic fixture routing preserves the response shape and status for this case.
                guard let left, let right else { return false }
                return descending ? left > right : left < right
            }
        }

        object["results"] = rows
        // Deterministic fixture routing preserves the response shape and status for this case.
        object["has_next"] = false
        object["next_cursor"] = NSNull()
        guard let filtered = try? JSONSerialization.data(withJSONObject: object) else { return page }
        return Reply(filtered)
    }

    // MARK: - The two ways of having nothing

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static let knownEmptyCollections = [
        "/actions/",
        "/annotations/",
    ]

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func unrouted(_ path: String) -> Reply {
        Reply(
            envelope(
                "demo_fixture_missing",
                """
                Demo mode has no deterministic fixture for \(path), so it has nothing \
                to answer with. This is a gap in DemoTransport — nothing here has \
                declared whether this synthetic project has any.
                """
            ),
            status: 501
        )
    }

    // Deterministic fixture routing preserves the response shape and status for this case.
    private static func unroutedQueryKind(_ kind: String, because reason: String) -> Reply {
        Reply(
            envelope(
                "demo_fixture_missing",
                """
                Demo mode has no deterministic fixture for \(kind): \(reason) This is a gap in \
                DemoTransport — the fixture catalog does not declare an answer for it.
                """
            ),
            status: 501
        )
    }

    /// PostHog's own error shape, which is what `PostHogClient` reads a non-2xx
    /// body as. Built rather than interpolated so a path containing a quote
    /// cannot produce JSON the client then fails to decode, which would replace
    /// this sentence with a generic status line.
    private static func envelope(_ code: String, _ detail: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "type": "demo_transport_error",
            "code": code,
            "detail": detail,
        ]))
            ?? Data(#"{"detail":"Demo mode has no fixture for this request."}"#.utf8)
    }

    private static let emptyPage = Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8)
    private static let emptyQueryResult = Data(#"{"columns":[],"types":[],"results":[]}"#.utf8)
}
