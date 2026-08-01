import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// Replays scripted HTTP responses so session state can be tested without network.
private actor ScriptedTransport: HTTPTransport {
    private var responses: [(Int, String)]
    private(set) var requestPaths: [String] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestPaths.append(request.url?.path ?? "")
        let (status, body) = responses.count == 1 ? responses[0] : responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private let meJSON = """
{"email":"a@example.com","first_name":"Ada","distinct_id":"d1",
 "team":{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"},
 "organization":{"id":"org1","name":"Acme",
   "teams":[{"id":42,"name":"Prod","api_token":"phc_x","timezone":"UTC"},
            {"id":43,"name":"Staging","api_token":"phc_y","timezone":"UTC"}]},
 "organizations":[{"id":"org1","name":"Acme"}]}
"""

/// Serialized because the selected project is persisted to
/// `UserDefaults.standard` — that is the whole point of it, so a relaunch and an
/// out-of-process intent agree on which project is live — and these tests
/// therefore share one piece of global state. Run in parallel, a test that
/// switches projects can be in flight while another is asserting which project a
/// fresh connection restores.
@Suite("AppModel session", .serialized)
@MainActor
struct AppModelTests {

    @Test("starts in onboarding when no credential is stored")
    func noCredentialMeansOnboarding() async {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        await model.bootstrap()
        #expect(model.phase == .onboarding)
    }

    @Test("connecting loads identity, projects and a selected project")
    func connectPopulatesSession() async throws {
        let store = InMemoryTokenStore()
        let model = AppModel(
            store: store,
            transport: ScriptedTransport([(200, meJSON)])
        )

        try await model.connect(key: "phx_abc", region: .usCloud)

        #expect(model.phase == .ready)
        #expect(model.me?.email == "a@example.com")
        #expect(model.projects.count == 2)
        #expect(model.selectedProject?.id == 42)
        // The key must be persisted so the next launch skips onboarding.
        #expect(try store.load()?.key == "phx_abc")
    }

    @Test("a rejected key does not persist a credential")
    func rejectedKeyIsNotStored() async throws {
        let store = InMemoryTokenStore()
        let body = #"{"type":"authentication_error","code":"not_authenticated","detail":"nope"}"#
        let model = AppModel(store: store, transport: ScriptedTransport([(401, body)]))

        await #expect(throws: (any Error).self) {
            try await model.connect(key: "phx_bad", region: .usCloud)
        }
        #expect(model.phase != .ready)
        #expect(try store.load() == nil)
    }

    @Test("a stored credential that no longer works falls back to onboarding with a reason")
    func staleCredentialExplainsItself() async {
        let store = InMemoryTokenStore(
            credential: StoredCredential(key: "phx_stale", region: .usCloud)
        )
        let model = AppModel(store: store, transport: ScriptedTransport([(401, "{}")]))

        await model.bootstrap()

        // Landing on an empty dashboard with no explanation would be worse than
        // sending the user back to onboarding.
        #expect(model.phase == .onboarding)
        #expect(model.connectionError != nil)
    }

    @Test("signing out clears the credential and the session")
    func signOutClearsEverything() async throws {
        let store = InMemoryTokenStore()
        let model = AppModel(store: store, transport: ScriptedTransport([(200, meJSON)]))
        try await model.connect(key: "phx_abc", region: .usCloud)

        model.signOut()

        #expect(model.phase == .onboarding)
        #expect(model.me == nil)
        #expect(model.projects.isEmpty)
        #expect(try store.load() == nil)
    }

    @Test("self-hosted regions are preserved, since OAuth can never reach them")
    func selfHostedRegionSurvives() async throws {
        let store = InMemoryTokenStore()
        let host = URL(string: "https://ph.internal.example")!
        let model = AppModel(store: store, transport: ScriptedTransport([(200, meJSON)]))

        try await model.connect(key: "phx_abc", region: .selfHosted(host))

        #expect(try store.load()?.region == .selfHosted(host))
        #expect(model.client?.host == host)
    }

    // MARK: - Links naming another project

    @Test("a link for another accessible project switches to it")
    func linkSwitchesProject() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        try await model.connect(key: "phx_abc", region: .usCloud)
        let current = try #require(model.selectedProject)
        let other = try #require(model.projects.first { $0.id != current.id })

        #expect(model.selectProject(id: other.id) == .switched(name: other.name))
        #expect(model.selectedProject?.id == other.id)

        // Left as it was found: the selection outlives this model in shared
        // defaults, and the next test connects expecting the same project a
        // real relaunch would restore.
        #expect(model.selectProject(id: current.id) == .switched(name: current.name))
    }

    @Test("a link for the project already on screen moves nothing")
    func linkForCurrentProject() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        try await model.connect(key: "phx_abc", region: .usCloud)
        let current = try #require(model.selectedProject?.id)

        #expect(model.selectProject(id: current) == .current)
        #expect(model.selectedProject?.id == current)
    }

    @Test("a link for a project this key cannot see is refused, not redirected")
    func linkForInaccessibleProject() async throws {
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: ScriptedTransport([(200, meJSON)])
        )
        try await model.connect(key: "phx_abc", region: .usCloud)

        // The failure this guards against: resolving the link's object id
        // against whichever project happened to be selected, which would put
        // one project's numbers on screen under another project's name.
        #expect(model.selectProject(id: 999) == .inaccessible)
        #expect(model.selectedProject?.id == 42)
    }
}

// MARK: - Reducing a tile to a widget metric

/// Pins `AppModel.metric(from:on:)`, which reduces one dashboard tile to the
/// value the widgets, Smart Stack and metric alerts all read.
///
/// This function was `private static` and had no test at all, and that is
/// exactly how a permanent false decline reached the Lock Screen: the funnel
/// branch filled `SharedSnapshot.Metric.previous` — documented as "the
/// comparison-period value, nil means not known" — with the funnel's *step-1
/// count*. `SharedSnapshotTests` already pinned how `previous` is turned into a
/// delta, so the arithmetic was covered and the *input* was not, and a covered
/// derivation over a poisoned input is still wrong on screen.
///
/// Tiles are built by decoding JSON rather than by a memberwise initialiser
/// because `Tile` and `Insight` only have `Decodable` ones — which is the
/// better test anyway: it drives the real decoder, so a change to how PostHog's
/// funnel payload is read breaks these rather than passing them by coincidence
/// of a hand-built value.
/// `@MainActor` because `AppModel` is, so its statics are too — matching
/// `AppModelTests` above. Unlike that suite this one holds no shared state, so
/// it does not need `.serialized`.
@Suite("Dashboard tile to widget metric")
@MainActor
struct TileMetricTests {

    private static func tile(_ json: String) throws -> Tile {
        try JSONDecoder().decode(Tile.self, from: Data(json.utf8))
    }

    /// A two-step funnel, 5,000 → 750. The numbers from the audit, so the
    /// −85% this used to report is what fails if the fix is reverted.
    private static let funnelJSON = """
        {"id": 1, "insight": {"id": 77, "name": "Signup funnel",
          "query": {"source": {"kind": "FunnelsQuery"}},
          "result": [{"name": "Visited", "count": 5000, "order": 0},
                     {"name": "Signed up", "count": 750, "order": 1}]}}
        """

    @Test("a funnel headline carries no comparison, because a funnel has none")
    func funnelHasNoBaseline() throws {
        let metric = try #require(
            AppModel.metric(from: Self.tile(Self.funnelJSON), on: 9)
        )

        // The last step is the headline, and that part was always right.
        #expect(metric.value == 750)

        // The whole defect, in one assertion. `previous` was `5000` — step 1 of
        // the same funnel, a different axis entirely. A funnel is monotonically
        // non-increasing and its steps arrive step-1-first, so this was
        // negative with a guaranteed sign and a large magnitude, forever.
        #expect(metric.previous == nil)
        #expect(metric.delta == nil)
        #expect(metric.deltaFraction == nil)

        // What the widget and VoiceOver actually branch on. `.down` here used
        // to produce "−85%" beside a down arrow and "down 85%" read aloud.
        #expect(metric.direction == .unknown)

        // `sparkline` documents "oldest to newest"; a funnel's step profile is
        // not a time axis, and `MetricWidget.legend` labels its ends
        // "low"/"high" next to a legend item named `prev`.
        #expect(metric.sparkline.isEmpty)
    }

    /// The end of the chain, and the one that reached the Lock Screen.
    ///
    /// `MetricWatch.verdict` carries a comment refusing to invent a baseline
    /// for precisely this reason — and was being handed one from `AppModel`,
    /// one layer up. This drives the real evaluator over a real snapshot, so it
    /// pins the seam rather than either side of it.
    @Test("a funnel cannot fire a percentage-change notification")
    func funnelNeverFiresAChangeAlert() throws {
        let metric = try #require(
            AppModel.metric(from: Self.tile(Self.funnelJSON), on: 9)
        )
        let snapshot = SharedSnapshot(
            projectID: 42, projectName: "Prod",
            metrics: [metric], flags: [], capturedAt: Date()
        )
        let watch = MetricWatch(
            id: "w1", metricID: metric.id, title: metric.title,
            condition: .changesByPercent(10)
        )

        let evaluation = MetricWatchEvaluator.evaluate(
            snapshot: snapshot, watches: [watch], breaching: []
        )

        // Before the fix this produced a local notification reading
        // "Signup funnel is 750, down 85% from 5,000." — a claim about a
        // change that never happened, pushed to the Lock Screen.
        #expect(evaluation.alerts.isEmpty)
        #expect(evaluation.breaching.isEmpty)
    }

    /// A threshold watch still works. The fix removes an invented comparison,
    /// and must not quietly remove the two conditions that never needed one.
    @Test("a funnel still fires an absolute threshold notification")
    func funnelStillFiresThresholdAlerts() throws {
        let metric = try #require(
            AppModel.metric(from: Self.tile(Self.funnelJSON), on: 9)
        )
        let snapshot = SharedSnapshot(
            projectID: 42, projectName: "Prod",
            metrics: [metric], flags: [], capturedAt: Date()
        )
        let watch = MetricWatch(
            id: "w1", metricID: metric.id, title: metric.title,
            condition: .below(1000)
        )

        let evaluation = MetricWatchEvaluator.evaluate(
            snapshot: snapshot, watches: [watch], breaching: []
        )

        #expect(evaluation.alerts.count == 1)
        #expect(evaluation.alerts.first?.body.contains("750") == true)
    }

    /// The branch the funnel one should have matched all along.
    @Test("a big number carries no comparison either")
    func bigNumberHasNoBaseline() throws {
        let tile = try Self.tile("""
            {"id": 2, "insight": {"id": 78, "name": "Total signups",
              "query": {"source": {"kind": "TrendsQuery",
                        "trendsFilter": {"display": "BoldNumber"}}},
              "result": [{"label": "signups", "aggregated_value": 1234}]}}
            """)

        let metric = try #require(AppModel.metric(from: tile, on: 9))
        #expect(metric.value == 1234)
        #expect(metric.previous == nil)
        #expect(metric.direction == .unknown)
    }

    /// The one branch entitled to a baseline, kept as the contrast case: a
    /// trends series *is* a time axis, so its second-to-last point really is
    /// the comparison period and `.down` really means down.
    @Test("a time series does carry a real comparison")
    func timeSeriesKeepsItsBaseline() throws {
        let tile = try Self.tile("""
            {"id": 3, "insight": {"id": 79, "name": "Daily signups",
              "query": {"source": {"kind": "TrendsQuery"}},
              "result": [{"label": "signups", "data": [10, 20, 15],
                          "days": ["2026-01-01", "2026-01-02", "2026-01-03"]}]}}
            """)

        let metric = try #require(AppModel.metric(from: tile, on: 9))
        #expect(metric.value == 15)
        #expect(metric.previous == 20)
        #expect(metric.direction == .down)
        #expect(metric.sparkline == [10, 20, 15])
    }

    /// Retention, paths and stickiness have no single headline figure and are
    /// deliberately not offered as widget metrics. Pinned so a future display
    /// type cannot fall into the funnel branch's old habit of inventing one.
    @Test("a shape with no single headline figure is offered no metric")
    func unsupportedShapesAreNotOffered() throws {
        let tile = try Self.tile("""
            {"id": 4, "insight": {"id": 80, "name": "Retention",
              "query": {"source": {"kind": "RetentionQuery"}},
              "result": [{"date": "2026-01-01", "label": "Day 0",
                          "values": [{"count": 10}, {"count": 4}]}]}}
            """)

        #expect(AppModel.metric(from: tile, on: 9) == nil)
    }
}
