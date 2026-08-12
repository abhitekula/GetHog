import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// What the demo fixtures actually serve.
///
/// Written after three `BackgroundRefreshTests` failures that looked like a
/// fixture problem and were not. `DemoTransport` routes on `request.url?.path`,
/// and Foundation's `URL.path` **normalises the trailing slash away**: a request
/// to `/api/projects/1001/feature_flags/` arrives here as
/// `/api/projects/1001/feature_flags`, so `contains("/feature_flags/")` was false
/// and every *collection* endpoint fell through to the empty-page fallback.
///
/// Detail paths kept working — `/dashboards/725101/` still contains `/dashboards/`
/// once its own trailing slash is dropped — which is why the app looked healthy
/// while lists came back empty, and why this went unnoticed: it is invisible
/// except where a list feeds something other than a screen.
///
/// The routing is asserted through the public `send` rather than by testing the
/// private matcher, so the test would still catch this if the dispatch were
/// rewritten.
@Suite("Demo fixtures")
struct DemoTransportTests {

    private func fixture(for path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await reply(for: path, query: query).0
    }

    /// The status as well as the bytes.
    ///
    /// Needed since the empty-page catch-all was replaced: "this path has no
    /// fixture" is now a status code, and a helper that threw it away could not
    /// tell the new answer from the old one.
    private func reply(
        for path: String, query: [URLQueryItem] = []
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: "https://app.example.com" + path)!
        if !query.isEmpty { components.queryItems = query }
        return try await DemoTransport().send(URLRequest(url: components.url!))
    }

    /// Routes an endpoint **as `PostHogAPI` builds it**, body and all.
    ///
    /// Every `/query/` assertion below goes through this rather than a
    /// hand-written JSON literal, because a hand-written body only proves the
    /// transport matches the string the test author typed. The kinds are chosen
    /// in `PostHogAPI`, so a rename there has to break the routing here — and
    /// with a literal it silently would not.
    private func fixture(for endpoint: Endpoint) async throws -> Data {
        try await reply(for: endpoint).0
    }

    /// The same, keeping the status — needed wherever the assertion is that a
    /// route *declines* to answer rather than what it answers with.
    private func reply(for endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: "https://app.example.com" + endpoint.path)!
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        return try await DemoTransport().send(request)
    }

    private static let projectID = 1001
    private static let failedSavedQueryID = "018f9000-0000-7000-8000-000000000400"
    private static let modifiedSavedQueryID = "018f9000-0000-7000-8000-000000000371"
    private static let healthySavedQueryID = "018f9000-0000-7000-8000-000000000243"
    private static let plainSavedQueryID = "018f9000-0000-7000-8000-000000000014"

    private func expectTerminalPage(
        _ data: Data,
        named name: String,
        expectedCount: Int
    ) throws {
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "\(name) must be a JSON object"
        )
        let results = try #require(envelope["results"] as? [Any])

        #expect(envelope["count"] as? Int == expectedCount, "\(name) advertises the wrong total")
        #expect(results.count == expectedCount, "\(name) serves a different number of rows")
        #expect(envelope["next"] is NSNull, "\(name) must remain a terminal page")
        #expect(envelope["previous"] is NSNull, "\(name) must remain the first page")
    }

    @Test("dashboard recompute failure leaves cached load and empty dashboard route intact")
    func dashboardConsistencyDemoRoutes() async throws {
        let transport = DemoTransport(dashboardRecomputeFailure: true)

        func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
            var components = URLComponents(string: "https://app.example.com" + endpoint.path)!
            components.queryItems = endpoint.query
            var request = URLRequest(url: components.url!)
            request.httpMethod = endpoint.method
            request.httpBody = endpoint.body
            return try await transport.send(request)
        }

        let cached = try await send(
            PostHogAPI.dashboard(
                projectID: Self.projectID,
                dashboardID: DemoTransport.dashboardID,
                refresh: false
            )
        )
        #expect(cached.1.statusCode == 200)
        #expect(try Dashboard.decode(from: cached.0).tiles.isEmpty == false)

        let recompute = try await send(
            PostHogAPI.dashboard(
                projectID: Self.projectID,
                dashboardID: DemoTransport.dashboardID,
                refresh: true
            )
        )
        #expect(recompute.1.statusCode == 503)

        let empty = try await send(
            PostHogAPI.dashboard(
                projectID: Self.projectID,
                dashboardID: DemoTransport.emptyDashboardID,
                refresh: false
            )
        )
        #expect(empty.1.statusCode == 200)
        #expect(try Dashboard.decode(from: empty.0).tiles.isEmpty)
    }

    /// This catches a demo transport that accepts generation but keeps the
    /// canonical synthetic replay in its initial missing-summary state.
    @Test("demo summary generation changes one transport from absent to stored")
    @MainActor
    func demoSummaryGenerationPersistsForTheRun() async {
        let transport = DemoTransport(summaryInitiallyAbsent: true)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: transport
        )
        let store = SessionSummaryStore()

        await store.load(
            client: client,
            projectID: Self.projectID,
            sessionID: "018f1000-0000-7000-8000-000000000001"
        )
        #expect(store.state == .absent)

        await store.generate(
            client: client,
            projectID: Self.projectID,
            sessionID: "018f1000-0000-7000-8000-000000000001"
        )
        #expect(store.detail?.chapters.count == 2)
    }

    @Test("a multi-session generation request does not store the canonical summary")
    @MainActor
    func multiSessionGenerationDoesNotChangeDemoSummary() async throws {
        let transport = DemoTransport(summaryInitiallyAbsent: true)
        let canonicalSessionID = "018f1000-0000-7000-8000-000000000001"
        let endpoint = Endpoint(
            path: "/api/projects/\(Self.projectID)/session_summaries/"
                + "create_session_summaries_individually/",
            method: "POST",
            body: try JSONSerialization.data(
                withJSONObject: ["session_ids": [canonicalSessionID, "other"]]
            ),
            category: .query
        )
        var request = URLRequest(url: URL(string: "https://app.example.com" + endpoint.path)!)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body

        let (_, response) = try await transport.send(request)
        #expect(response.statusCode == 501)

        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: transport
        )
        let store = SessionSummaryStore()
        await store.load(
            client: client,
            projectID: Self.projectID,
            sessionID: canonicalSessionID
        )
        #expect(store.state == .absent)
    }

    @Test(
        "the visual-verification seam empties its requested collection",
        arguments: [
            (DemoTransport.EmptyCollection.dashboards, PostHogAPI.dashboards(projectID: Self.projectID)),
            (.insights, PostHogAPI.insights(projectID: Self.projectID)),
            (.sessions, PostHogAPI.sessionRecordings(projectID: Self.projectID)),
            (.experiments, PostHogAPI.experiments(projectID: Self.projectID)),
            (.errorTracking, PostHogAPI.errorTrackingIssues(projectID: Self.projectID)),
        ]
    )
    func forcedEmptyCollection(
        collection: DemoTransport.EmptyCollection,
        endpoint: Endpoint
    ) async throws {
        var components = URLComponents(string: "https://app.example.com" + endpoint.path)!
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        let (data, response) = try await DemoTransport(emptyCollection: collection).send(request)
        #expect(response.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["results"] as? [Any])?.isEmpty == true)
    }

    /// The exact shape `AppModel.publish` asks for, trailing slash and all.
    @Test("a collection path serves its fixture page, not an empty one")
    func collectionPathsResolve() async throws {
        let dashboards: Page<DashboardSummary> = try JSONDecoder().decode(
            Page<DashboardSummary>.self,
            from: try await fixture(
                for: "/api/projects/1001/dashboards/",
                query: [URLQueryItem(name: "limit", value: "50")]
            )
        )
        #expect(!dashboards.results.isEmpty)

        let flags: Page<FeatureFlag> = try JSONDecoder().decode(
            Page<FeatureFlag>.self,
            from: try await fixture(
                for: "/api/projects/1001/feature_flags/",
                query: [URLQueryItem(name: "limit", value: "100")]
            )
        )
        #expect(!flags.results.isEmpty)
    }

    @Test("terminal fictional collection envelopes report exactly the rows they serve")
    func terminalCollectionEnvelopeTotalsAreTruthful() async throws {
        let me = try JSONDecoder().decode(
            MeResponse.self,
            from: try await fixture(for: "/api/users/@me/")
        )
        let currentOrganizationID = try #require(me.currentOrganizationID)

        try expectTerminalPage(
            try await fixture(for: PostHogAPI.notebooks(projectID: Self.projectID)),
            named: "notebooks",
            expectedCount: 2
        )
        try expectTerminalPage(
            try await fixture(
                for: PostHogAPI.organizationProjects(organizationID: currentOrganizationID)
            ),
            named: "organization projects",
            expectedCount: 2
        )
        try expectTerminalPage(
            try await fixture(for: PostHogAPI.savedHeatmaps(projectID: Self.projectID)),
            named: "saved heatmaps",
            expectedCount: 2
        )
    }

    /// The list/detail split is decided by the trailing slash, so it is the part
    /// most easily broken by a fix to the above.
    @Test("a detail path still serves the detail fixture")
    func detailPathResolves() async throws {
        let data = try await fixture(
            for: "/api/projects/1001/dashboards/725101/",
            query: [URLQueryItem(name: "refresh", value: "force_cache")]
        )
        let dashboard = try JSONDecoder().decode(Dashboard.self, from: data)
        #expect(dashboard.id == 725_101)
        #expect(!dashboard.tiles.isEmpty)
    }

    @Test("an unknown dashboard id is not served as the demo dashboard")
    func unknownDashboardIDIsUnrouted() async throws {
        let (_, response) = try await reply(
            for: "/api/projects/1001/dashboards/730199/"
        )
        #expect(response.statusCode == 501)
    }

    /// `/query/` is matched with `hasSuffix`, which the same normalisation
    /// defeats outright — every HogQL-backed screen would have fallen back to an
    /// empty page.
    @Test("the query endpoint serves a query result")
    func queryPathResolves() async throws {
        var components = URLComponents(string: "https://app.example.com/api/projects/1001/query/")!
        components.queryItems = nil
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"query":{"kind":"HogQLQuery"}}"#.utf8)

        let (data, _) = try await DemoTransport().send(request)
        let response = try JSONDecoder().decode(QueryResponse.self, from: data)
        #expect(!response.rows.isEmpty)
    }

    /// `@` is percent-encoded in the URL, so identity has its own decoding step
    /// that must survive any change to how the path is read.
    @Test("identity resolves despite the percent-encoded @")
    func identityResolves() async throws {
        let data = try await fixture(for: "/api/users/@me/")
        let me = try JSONDecoder().decode(MeResponse.self, from: data)
        #expect(me.userID == 710_031)
        #expect(me.email == "zadie.quell@example.net")
        #expect(me.displayName == "Zadie Quell")
        #expect(me.currentProject?.id == 1_001)
        #expect(me.currentProject?.name == "Starling Metrics Lab")
        // Raw summaries include duplicate current-organization entries so the
        // route test also pins the public, de-duplicated organization choices.
        #expect(me.organizations.count == 3)
        #expect(me.allOrganizations.map(\.name) == ["Northstar Sandbox", "Juniper Test Guild"])
    }

    /// The query kinds the **documented API would not answer** must come back empty,
    /// never as some other kind's payload.
    ///
    /// This test used to read "an unsupported query kind", over a list of three
    /// that included Web Vitals and Groups. Both have fixtures now, so the list
    /// has been narrowed and the name changed to say why these three are not:
    /// not oversight, refusal. The authored contract covers these responses:
    ///
    ///   `LogsQuery`              HTTP 400, "Access control failure. You don't
    ///                            have `viewer` access to the `logs` resource."
    ///   `TraceSpansQuery`        HTTP 400, the same denial for `tracing`
    ///   `SessionsTimelineQuery`  HTTP 200, but no screen sends it
    ///
    /// — so there is nothing honest to serve, and this stays the assertion that
    /// the fallback holds. It matters because the fallback used to be the HogQL
    /// fixture, whose `results` are positional *row arrays*: decoders written
    /// for object-shaped results reject that outright, and Web Vitals rendered
    /// `DecodingError.typeMismatch … Expected Dictionary but found an array`
    /// where the honest answer was "the fixture contains no rows".
    ///
    /// `TraceSpansQuery` also covers the sharpest naming hazard in the new
    /// routing: it and `TracesQuery` (LLM analytics, fixture-backed) differ only in the
    /// case of one letter, and a `contains` match on the wrong one would hand the
    /// tracing screen a page of LLM traces with no decoding error anywhere to
    /// give it away.
    ///
    /// Deliberately built from kinds that still have a builder. Two further
    /// tracing kinds were measured the same day — the aggregated tree and the
    /// attribute breakdown, both answered 400 "Unsupported query kind" — and have
    /// since been deleted from `PostHogAPI` outright. Naming them here would have
    /// tied this assertion's life to theirs; `DemoTransport` needs no route for
    /// them either, because nothing can construct one.
    @Test("a query kind the documented API refused returns an empty result, not another kind's data")
    func refusedQueryKindIsEmpty() async throws {
        let refused: [(String, Endpoint)] = [
            ("LogsQuery", PostHogAPI.logs(projectID: Self.projectID)),
            ("TraceSpansQuery", PostHogAPI.traceSpans(projectID: Self.projectID)),
            ("SessionsTimelineQuery", PostHogAPI.sessionsTimeline(projectID: Self.projectID)),
        ]

        for (kind, endpoint) in refused {
            let response = try QueryResponse.decode(from: try await fixture(for: endpoint))
            #expect(response.rows.isEmpty, "\(kind) should be empty, not another kind's rows")
            #expect(response.columns.isEmpty, "\(kind) should carry no columns")
        }
    }

    /// Web analytics loads six sections from six kinds against one path, so this
    /// is where a `contains` match that is too loose shows up: every one of them
    /// starts with `Web`, and two of the six end in `TableQuery`.
    ///
    /// Each section is decoded with the decoder its own screen uses, because the
    /// point of authoring these was that the shapes differ — pairs and dotted
    /// column paths for the tables, three named buckets for vitals, bare objects
    /// with no `columns` at all for notable changes.
    @Test("each web analytics query kind serves its own fixture")
    func webAnalyticsQueryKindsResolve() async throws {
        let overview = try WebOverviewResponse.decode(
            from: try await fixture(for: PostHogAPI.webOverview(projectID: Self.projectID))
        )
        #expect(!overview.metrics.isEmpty)

        let stats = WebStatsRow.rows(
            from: try QueryResponse.decode(
                from: try await fixture(for: PostHogAPI.webStats(projectID: Self.projectID))
            )
        )
        #expect(stats.count == 7)
        #expect(stats.first?.breakdownValue == "/harbor")
        #expect(stats.first?.visitors == 418)
        #expect(stats.first?.views == 922)

        let vitals = try WebVitalsBreakdown.decode(
            from: try await fixture(for: PostHogAPI.webVitals(projectID: Self.projectID))
        )
        // All three bands are populated in the fixture, which is the reason it
        // was worth taking: a fixture with only `good` rows would let a bug that
        // drops the poor bucket pass.
        #expect(!vitals.good.isEmpty)
        #expect(!vitals.needsImprovement.isEmpty)
        #expect(!vitals.poor.isEmpty)

        let clicks = WebExternalClickRow.rows(
            from: try QueryResponse.decode(
                from: try await fixture(
                    for: PostHogAPI.webExternalClicks(projectID: Self.projectID)
                )
            )
        )
        #expect(!clicks.isEmpty)

        let changes = try WebNotableChangesResponse.decode(
            from: try await fixture(for: PostHogAPI.webNotableChanges(projectID: Self.projectID))
        )
        #expect(!changes.changes.isEmpty)
    }

    /// Query recordings preserve their distinct response shapes.
    ///
    /// The marketing table is intentionally empty but still carries columns.
    /// Endpoint usage carries authored fictional traffic so the demo exercises
    /// both the no-endpoints and traffic readings without a network tenant.
    @Test("the zero-row recordings still carry their columns and metric keys")


    func emptyButRecordedQueryKindsKeepTheirShape() async throws {
        let marketing = try QueryResponse.decode(
            from: try await fixture(for: PostHogAPI.marketingAnalytics(projectID: Self.projectID))
        )
        #expect(marketing.rows.isEmpty)
        #expect(!MarketingTable.columns(from: marketing).isEmpty)

        let overview = try EndpointUsageOverview.decode(
            from: try await fixture(
                for: PostHogAPI.endpointsUsageOverview(projectID: Self.projectID)
            )
        )
        #expect(overview.metrics.map(\.key) == [
            "example_orbit_requests",
            "example_telescope_failures",
            "example_starlight_cache_hits",
            "example_constellation_rows",
            "example_observation_duration_ms",
            "example_lens_cpu_seconds",
        ])
        #expect(overview.reading(endpointCount: 0) == .noEndpointsDefined)
        #expect(overview.reading(endpointCount: 3) == .traffic)

        let table = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.endpointsUsageTable(
                    projectID: Self.projectID, breakdownBy: .endpoint
                )
            )
        )
        #expect(EndpointUsageBreakdownRow.rows(from: table).isEmpty)
        #expect(!table.columns.isEmpty)
    }

    /// Taxonomy is the one screen that merges a `/query/` node with a plain CRUD
    /// listing, so it is the one place a missing route on **either** side reads
    /// as a data problem rather than a routing one.
    ///
    /// With only volume rows in the fixture, `TaxonomyEvent.merge` finds no definition
    /// for any row: every event shows as uncurated and the "defined" total reads
    /// 0 next to 100 rows of authored volume. Both halves are asserted here for that
    /// reason, and the counts are asserted as *different* — they answer different
    /// questions (30-day volume versus every name ever ingested) and a route that
    /// served one fixture to both paths would make them agree.
    @Test("taxonomy resolves both its volume query and its definitions listing")
    func taxonomyResolves() async throws {
        let volumes = try Page<TaxonomyEventVolume>.decode(
            from: try await fixture(for: PostHogAPI.teamTaxonomy(projectID: Self.projectID))
        )
        #expect(volumes.results.count == 10)
        #expect(volumes.results.first?.event == "feature_used")
        #expect(volumes.results.first?.count == 2_041)
        // The runner pads its last page with well-known names at zero, which is
        // exactly the distinction the screen has to draw.
        #expect(volumes.results.contains { !$0.wasSeen })

        let definitions = try Page<EventDefinitionSummary>.decode(
            from: try await fixture(for: PostHogAPI.eventDefinitions(projectID: Self.projectID))
        )
        #expect(!definitions.results.isEmpty)
        #expect(definitions.count == 4)
        #expect(definitions.results.count != volumes.results.count)

        let properties = try Page<TaxonomyPropertySample>.decode(
            from: try await fixture(
                for: PostHogAPI.eventTaxonomy(projectID: Self.projectID, event: "$pageview")
            )
        )
        #expect(properties.results.count == 8)
        #expect(properties.results.first?.property == "$fixture_channel")
        #expect(properties.results.first?.sampleValues.count == 4)
        #expect(properties.results.contains { !$0.sampleValues.isEmpty })
    }

    /// Groups is the awkward one: `group_name` is an **object** inside a
    /// positional row, so a fixture of the wrong shape does not fail loudly — it
    /// yields rows whose display name is the cuid echoed twice.
    @Test("the groups query serves rows with real display names")
    func groupsQueryResolves() async throws {
        let response = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.groups(projectID: Self.projectID, groupTypeIndex: 0)
            )
        )
        let groups = response.rows.compactMap(GroupRow.init(row:))
        #expect(groups.count == 7)
        #expect(groups.first?.key == "group-harbor-3101")
        #expect(groups.first?.displayName == "Harbor Analytics Lab")
        #expect(groups.contains { $0.hasDisplayName })
        // Properties arrive as a JSON *string* that `GroupRow` has to re-parse;
        // a row that kept them as an opaque string would report zero.
        #expect(groups.contains { $0.propertyCount > 0 })
    }

    /// `TracesQuery` is built in `LLMAnalyticsStore`, not `PostHogAPI`, and it is
    /// the one query node whose `results` are camelCase objects that do not match
    /// its own `columns` — so it must reach `llm_traces` and nothing else.
    @Test("the LLM traces query serves the trace fixture")
    @MainActor
    func llmTracesQueryResolves() async throws {
        let response = try LLMTracesResponse.decode(
            from: try await fixture(
                for: LLMAnalyticsStore.tracesEndpoint(
                    projectID: Self.projectID, range: .week, limit: 50
                )
            )
        )
        #expect(!response.traces.isEmpty)
        #expect(response.traces.count == 18)
        #expect(response.hasCostData)
    }

    /// Ingestion warnings answer a **bare JSON array**, and the fallback for an
    /// unrouted path is an empty `Page`. Those two shapes are incompatible: if
    /// this route were ever dropped, the demo would serve `{"results":[]}` to a
    /// decoder expecting `[…]` and the screen would show a decoding error where
    /// the honest answer is an empty state.
    @Test("ingestion warnings serve a bare array, not a page")
    func ingestionWarningsResolve() async throws {
        let data = try await fixture(
            for: "/api/projects/1001/ingestion_warnings_v2/",
            query: [URLQueryItem(name: "date_from", value: "-7d")]
        )
        let rows = try IngestionWarning.decodeList(from: data)
        #expect(rows.count == 6)
        #expect(rows.first?.type == "quota_limited_wandering_hedgehog")
        #expect(rows.first?.count == 17)
    }

    /// The same trap as ingestion warnings: the `groups_types`
    /// had no route, so the fallback served `{"count":0,…,"results":[]}` to a
    /// `[GroupType]` decode and the Groups screen showed
    /// "DecodingError.typeMismatch … Expected to decode Array<Any> but found a
    /// dictionary instead" — a Swift type name, in front of a user, on the one
    /// screen in the app that failed this way.
    @Test("group types serve a bare array, not a page")
    func groupTypesResolve() async throws {
        let data = try await fixture(for: "/api/projects/1001/groups_types/")
        let types = try JSONDecoder().decode([GroupType].self, from: data)
        #expect(!types.isEmpty)
    }

    @Test("dashboard templates serve the synthetic library")
    func dashboardTemplatesResolve() async throws {
        let data = try await fixture(
            for: "/api/projects/1001/dashboard_templates/",
            query: [URLQueryItem(name: "limit", value: "50")]
        )
        let page = try Page<DashboardTemplate>.decode(from: data)
        #expect(!page.results.isEmpty)
        #expect(page.results.contains { $0.tileCount != nil })
    }

    /// Two paths share the `/comments/` prefix and answer different envelopes.
    /// The count sub-resource has to be matched first, or a badge asking for a
    /// total is handed a page of comments.
    @Test("the comment count sub-resource does not fall through to the thread")
    func commentPathsResolve() async throws {
        let thread = try await fixture(
            for: "/api/projects/1001/comments/",
            query: [URLQueryItem(name: "scope", value: "insight")]
        )
        // Cursor-paginated with no `count` at all — the shape this decoder has
        // to survive on the documented API too.
        let page = try Page<GetHogKit.Comment>.decode(from: thread)
        #expect(page.count == nil)
        #expect(!page.results.isEmpty)

        let counted = try await fixture(for: "/api/projects/1001/comments/count/")
        let total = try JSONDecoder().decode(CommentCount.self, from: counted)
        #expect(total.count == 4)
    }

    /// The sharpest prefix collision in the app, and the reason this test exists
    /// rather than an equivalent assertion living only in the kit.
    ///
    /// `/conversations/tickets/` is **Support** — customer tickets.
    /// `/conversations/` is **Max** — the AI assistant's threads. Two unrelated
    /// products under one namespace, and both answer a well-formed `Page`, so a
    /// route matching the shorter path would serve Support's fixture to the Max
    /// screen (or the reverse) with no decoding error anywhere to give it away:
    /// the reader would simply see the wrong product's rows under the right
    /// screen's title. That is the same class of failure as `/comments/count/`
    /// falling through to the comment thread, and worse, because these two
    /// screens look alike.
    ///
    /// Asserted in both directions on purpose. One direction catches a Support
    /// route that is too greedy; the other catches a Max route added later above
    /// it that swallows Support.
    @Test("support tickets and Max threads do not shadow each other")
    func conversationPrefixesDoNotCollide() async throws {
        let tickets = try Page<SupportTicket>.decode(
            from: try await fixture(
                for: "/api/projects/1001/conversations/tickets/",
                query: [URLQueryItem(name: "limit", value: "50")]
            )
        )
        #expect(!tickets.results.isEmpty)
        #expect(tickets.results.contains { $0.ticketNumber == 7_407 })

        // Max's own collection is explicitly authored empty. It must not reach
        // the ticket fixture, and the exact collection route must not make an
        // unknown Max detail look like an empty list.
        let (maxBody, maxResponse) = try await reply(
            for: PostHogAPI.conversations(projectID: Self.projectID)
        )
        #expect(!String(decoding: maxBody, as: UTF8.self).contains("ticket_number"))
        #expect(maxResponse.statusCode == 200)
        #expect((try? Page<MaxConversation>.decode(from: maxBody))?.results.isEmpty == true)
    }

    /// UI geometry needs real Max rows, but ordinary demo mode must keep its
    /// authored empty state. The opt-in transport seam supplies a separate,
    /// deterministic page without making the Support prefix any less exact.
    @Test("Max conversations can opt into deterministic populated rows")
    func populatedMaxConversationSeam() async throws {
        let transport = DemoTransport(populatedMaxConversations: true)
        let endpoint = PostHogAPI.conversations(projectID: Self.projectID)
        var components = URLComponents(string: "https://app.example.com" + endpoint.path)!
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        var request = URLRequest(url: try #require(components.url))
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        let (data, response) = try await transport.send(request)
        let page = try Page<MaxConversation>.decode(from: data)

        #expect(response.statusCode == 200)
        #expect(page.results.count == 2)
        #expect(page.results.map { $0.title } == [
            "Reviewing fictional observatory navigation",
            "Comparing synthetic meteor report paths",
        ])
        #expect(page.results.map(\.id) == [
            "018f3000-0000-7000-8000-000000000701",
            "018f3000-0000-7000-8000-000000000702",
        ])
        #expect(page.results.map(\.lastActivityAt) == [
            try Date("2026-02-12T14:30:00.000Z", strategy: .iso8601),
            try Date("2026-02-11T16:45:00.000Z", strategy: .iso8601),
        ])
    }

    /// The ticket thread is a sub-resource of a path that already matches, so it
    /// has the same ordering hazard one level down: `/tickets/{id}/messages/`
    /// contains `/conversations/tickets/` too, and would otherwise be handed the
    /// ticket list.
    @Test("a ticket's messages resolve to the thread, not to the ticket list")
    func ticketMessagesResolve() async throws {
        let thread = try Page<TicketMessage>.decode(
            from: try await fixture(
                for: "/api/projects/1001/conversations/tickets/"
                    + "018f9000-0000-7000-8000-000000000001/messages/"
            )
        )
        #expect(!thread.results.isEmpty)
        #expect(thread.results.contains { $0.isPrivate })

        // And the detail path between them serves one ticket, not a page — the
        // same list-versus-detail split dashboards and recordings have.
        let detail = try await fixture(
            for: "/api/projects/1001/conversations/tickets/"
                + "018f9000-0000-7000-8000-000000000001/"
        )
        let ticket = try JSONDecoder().decode(SupportTicket.self, from: detail)
        #expect(ticket.ticketNumber != nil)
    }

    /// A message collection belongs to one ticket, even though every endpoint
    /// shares the same `/messages/` suffix. The authored five-message archive
    /// is ticket #7407's thread; serving it for another id is valid JSON and is
    /// therefore a particularly quiet demo-truth failure.
    @Test("every support ticket resolves an identity-specific message page")
    func ticketMessagePagesKeepTicketIdentity() async throws {
        let tickets = try Page<SupportTicket>.decode(
            from: try await fixture(for: PostHogAPI.supportTickets(projectID: Self.projectID))
        )
        let ticket7407 = try #require(tickets.results.first { $0.ticketNumber == 7_407 })
        let authored = try Page<TicketMessage>.decode(
            from: try await fixture(
                for: PostHogAPI.supportTicketMessages(
                    projectID: Self.projectID,
                    ticketID: ticket7407.id
                )
            )
        )
        let authoredIDs = Set(authored.results.map(\.id))
        #expect(authored.results.count == 5)

        for ticket in tickets.results where ticket.id != ticket7407.id {
            let page = try Page<TicketMessage>.decode(
                from: try await fixture(
                    for: PostHogAPI.supportTicketMessages(
                        projectID: Self.projectID,
                        ticketID: ticket.id
                    )
                )
            )

            #expect(page.count == ticket.messageCount)
            #expect(!page.results.isEmpty, "\(ticket.reference) advertises a non-empty thread")
            #expect(
                authoredIDs.isDisjoint(with: page.results.map(\.id)),
                "\(ticket.reference) must not receive ticket #7407's archive"
            )
            #expect(page.results.last?.text == ticket.snippet)
        }

        let ticket7413 = try #require(tickets.results.first { $0.ticketNumber == 7_413 })
        let blankPreview = try Page<TicketMessage>.decode(
            from: try await fixture(
                for: PostHogAPI.supportTicketMessages(
                    projectID: Self.projectID,
                    ticketID: ticket7413.id
                )
            )
        )
        #expect(blankPreview.count == 723)
        #expect(blankPreview.results.last?.text == nil)
        #expect(blankPreview.results.last?.hasRichContent == false)
    }

    /// The counterpart: HogQL has a fixture and must keep resolving to it.
    @Test("HogQL still resolves to its fixture rows")
    func hogQLStillResolves() async throws {
        var request = URLRequest(
            url: URL(string: "https://app.example.com/api/projects/1001/query/")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"query":{"kind":"HogQLQuery","query":"select 1"}}"#.utf8)

        let (data, _) = try await DemoTransport().send(request)
        let response = try JSONDecoder().decode(QueryResponse.self, from: data)
        #expect(!response.rows.isEmpty)
    }

    @Test("a session timeline stays inside the canonical replay window")
    func sessionTimelineUsesCanonicalFixture() async throws {
        let start = Date(timeIntervalSince1970: 1_768_478_400)
        let end = start.addingTimeInterval(10)
        let data = try await fixture(
            for: PostHogAPI.sessionEvents(
                projectID: Self.projectID,
                sessionID: "018f1000-0000-7000-8000-000000000001",
                within: start...end
            )
        )
        let response = try JSONDecoder().decode(QueryResponse.self, from: data)
        let events = response.rows.compactMap(EventRow.init(row:))

        #expect(events.count == 4)
        #expect(events.map(\.event) == [
            "$pageview",
            "harbor_filter_changed",
            "harbor_dashboard_opened",
            "harbor_report_downloaded",
        ])
        #expect(events.compactMap(\.timestamp).map { $0.timeIntervalSince(start) } == [1, 3, 5, 7])
        #expect(events.allSatisfy { event in
            guard let timestamp = event.timestamp else { return false }
            return start...end ~= timestamp
        })
    }

    @Test("a SQL-console session predicate does not claim the canonical timeline fixture")
    func sessionPredicateNearMissStaysOnGenericHogQL() async throws {
        let data = try await fixture(
            for: PostHogAPI.hogql(
                projectID: Self.projectID,
                sql: "SELECT event FROM events WHERE $session_id = '018f1000-0000-7000-8000-000000000001'"
            )
        )
        let response = try JSONDecoder().decode(QueryResponse.self, from: data)

        #expect(response.columns == ["event", "timestamp", "distinct_id", "$current_url"])
    }
}

// MARK: - Routes added after the first fixture pass

extension DemoTransportTests {

    /// Every one of these drives the real `PostHogAPI` builder, for the reason
    /// the `fixture(for:)` overload above documents: a hand-written path only
    /// proves the transport matches the string the test author typed.
    @Test("a chart drill-down reaches people rather than an empty result")
    func actorsQueryResolves() async throws {
        let endpoint = try #require(
            PostHogAPI.insightActors(
                projectID: Self.projectID,
                source: .object(["kind": .string("TrendsQuery")]),
                drill: InsightDrill(
                    kind: .trendsPoint(series: 0, day: "2026-01-12"),
                    title: "28 Jul",
                    expectedCount: 19
                )
            )
        )
        let page = try JSONDecoder().decode(ActorsPage.self, from: try await fixture(for: endpoint))

        #expect(!page.actors.isEmpty)
        // Both authored person shapes must survive the fixture: a resolved person,
        // and one carrying `is_unresolved` with no properties at all. The sheet
        // draws them differently, so a fixture holding only the tidy shape
        // would leave the other path untested.
        let hasUnresolved = page.actors.contains { $0.isUnresolved }
        let hasResolved = page.actors.contains { !$0.isUnresolved }
        #expect(hasUnresolved)
        #expect(hasResolved)
        // Non-zero on the wire, and the sheet's footer reports it. Zero here
        // would quietly retire that line.
        #expect(page.missingActorsCount > 0)
    }

    /// The stack trace, which is a **HogQL** query and therefore one line away
    /// from being answered by the events fixture.
    ///
    /// Built through `PostHogAPI.errorIssueOccurrence` rather than a literal
    /// body for the reason this extension's header gives, and with a real issue
    /// id from `error_tracking.json` rather than an invented one — the route is
    /// keyed on the id, so an invented one would assert nothing about the
    /// pairing between an issue row and the fixture that belongs to it.
    ///
    /// The window is deliberately the one `ExceptionStackStore.window(for:)`
    /// computes, so a change to how the app bounds this query keeps the test
    /// honest instead of quietly diverging from it.
    @Test("an issue's stack trace resolves to its own fixture, not to the HogQL response")
    @MainActor
    func exceptionOccurrenceResolves() async throws {
        let issues = try JSONDecoder().decode(
            ErrorTrackingResponse.self,
            from: try await fixture(for: PostHogAPI.errorTrackingIssues(projectID: Self.projectID))
        ).issues
        let unresolved = try #require(issues.first { $0.name == "HarborRenderFault" })
        #expect(unresolved.id == "018f3300-0000-7000-8000-000000000901")
        #expect(unresolved.issueDescription == "Harbor card state was unavailable.")

        let response = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.errorIssueOccurrence(
                    projectID: Self.projectID,
                    issueID: unresolved.id,
                    within: ExceptionStackStore.window(for: unresolved)
                )
            )
        )
        // The failure this guards against is silent: `query_hogql.json` decodes
        // as a perfectly good `QueryResponse`, carries no `exception_list`, and
        // therefore yields no occurrence at all — which the screen reports as
        // "no stored exception event was found" over an issue that has one.
        let occurrence = try #require(ExceptionOccurrence.first(in: response))
        let entry = try #require(occurrence.chain.orderedForDisplay.first)
        #expect(entry.type == "HarborRenderFault")
        #expect(entry.frames.count == 23)

        // The shape that makes this screen worth having, and the reason this
        // fixture was chosen over the tidier one beside it: the stacktrace
        // container's own `type` says "resolved" while all but one of its frames
        // carry `resolved: false`. "We have a frame and cannot resolve it to
        // source" is a first-class rendering state — the Minified pill, the
        // once-only caveat, the disclosure of PostHog's own reason — and a
        // fixture without it would leave every one of those undrawn.
        #expect(entry.frames.filter(\.isMinified).count == 22)
        #expect(entry.frames.contains { $0.resolveFailure?.isEmpty == false })
        // And the issue's own description must match the frames', because both
        // render on the same screen; they were scrubbed independently and were
        // aligned in the demo copy for exactly this reason.
        #expect(entry.value == unresolved.issueDescription)

        // The second issue is the counterpart: one frame, symbolication
        // succeeded. Serving one fixture to every id would make that half of the
        // fork unreachable.
        let second = try #require(issues.first { $0.function == "fetchHarborLedger" })
        #expect(second.id == "018f3300-0000-7000-8000-000000000902")
        let resolved = try #require(
            ExceptionOccurrence.first(
                in: try QueryResponse.decode(
                    from: try await fixture(
                        for: PostHogAPI.errorIssueOccurrence(
                            projectID: Self.projectID,
                            issueID: second.id,
                            within: ExceptionStackStore.window(for: second)
                        )
                    )
                )
            )
        )
        let resolvedEntry = try #require(resolved.chain.orderedForDisplay.first)
        #expect(resolvedEntry.frames.allSatisfy { !$0.isMinified })

        // A third issue has no stored event, and that is the fixture's majority
        // case rather than a gap — PostHog keeps issues longer than the events
        // behind them. `ErrorIssueDetailView` has copy for it that would be
        // unreachable if every id answered frames.
        let third = try #require(
            issues.first { $0.id != unresolved.id && $0.id != second.id }
        )
        let empty = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.errorIssueOccurrence(
                    projectID: Self.projectID,
                    issueID: third.id,
                    within: ExceptionStackStore.window(for: third)
                )
            )
        )
        #expect(ExceptionOccurrence.first(in: empty) == nil)
        #expect(empty.rows.isEmpty)
    }

    @Test("a collection serves its pinned rows and a saved filter serves none")
    func playlistRecordingsSplitByKind() async throws {
        let collection = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: PostHogAPI.playlistRecordings(projectID: Self.projectID, shortID: "example-orbit-overview")
            )
        )
        #expect(!collection.results.isEmpty)

        // The documented API answers a saved filter `{"results": []}` on this path.
        // Reading that as "empty collection" is exactly the bug that would show
        // a populated saved filter as permanently blank, so the demo has to be
        // able to reproduce it.
        let savedFilter = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: PostHogAPI.playlistRecordings(projectID: Self.projectID, shortID: "example-console-observatory")
            )
        )
        #expect(savedFilter.results.isEmpty)
    }

    @Test("the playlists page carries both kinds and marks the synthetic ones")
    func playlistsPageCarriesBothKinds() async throws {
        let page = try JSONDecoder().decode(
            Page<SessionRecordingPlaylist>.self,
            from: try await fixture(for: "/api/projects/1001/session_recording_playlists/")
        )
        #expect(page.results.contains { $0.kind == .collection })
        #expect(page.results.contains { $0.kind == .filters })
        let hasSynthetic = page.results.contains { $0.isSynthetic }
        #expect(hasSynthetic)
        #expect(page.results.map(\.shortID) == [
            "example-orbit-overview",
            "example-console-observatory",
            "example-long-observations",
            "example-reviewed-orbits",
        ])
        let authored = page.results.filter { !$0.isSynthetic }
        #expect(authored.compactMap(\.numericID) == [700521, 700537, 700558])
        #expect(authored.allSatisfy { $0.createdAt == authored.first?.createdAt })
    }

    /// Experiments, which are the one product surface whose demo data is
    /// **schema-derived** rather than fixture-backed — the authored demo has none.
    ///
    /// The routing is what this pins, and it has three parts that can each fail
    /// silently. The list must keep the leaner serializer's shape; the detail
    /// must not be served from the list, because that shape has no metrics and
    /// the sheet would say an experiment has none when metrics are configured; and results
    /// must be matched per metric rather than shared, because two metrics under
    /// one fixture would show identical numbers under different names.
    @Test("the experiments list serves the lean shape and the detail serves the metrics")
    func experimentRoutesSplitListFromDetail() async throws {
        let page = try Page<Experiment>.decode(
            from: try await fixture(for: PostHogAPI.experiments(projectID: Self.projectID))
        )
        #expect(page.results.count == 4)
        // Every lifecycle state the list screen groups by is present. Identical
        // states would leave the grouping untested; the extra completed row also
        // proves a page count is not copied from the three-row source snapshot.
        #expect(Set(page.results.map(\.statusText)) == ["Running", "Draft", "Complete"])
        #expect(page.results.contains { $0.id == 71_104 && $0.name == "Example notification cadence trial" })
        // The list endpoint defers the metric columns, and that absence is why
        // `ExperimentResultsStore` re-fetches. A fixture that carried them would
        // let a regression dropping the re-fetch pass unnoticed.
        #expect(page.results.allSatisfy { $0.metrics.isEmpty && $0.secondaryMetrics.isEmpty })

        let running = try #require(page.results.first { $0.id == 71_101 })
        #expect(running.name == "Example cache strategy trial")
        let detail: Experiment = try JSONDecoder().decode(
            Experiment.self,
            from: try await fixture(
                for: PostHogAPI.experiment(projectID: Self.projectID, experimentID: running.id)
            )
        )
        #expect(detail.id == running.id)
        #expect(detail.metrics.count == 2)
        #expect(detail.secondaryMetrics.count == 2)
        #expect(detail.configuredStatsMethod == .bayesian)
        // Needed to build an exposure query at all — `experimentExposures`
        // returns nil without the whole flag object echoed back.
        #expect(detail.featureFlagRaw != nil)

        // The completed one runs the other statistical engine, which the screen
        // is deliberately written never to relabel as the first.
        let complete: Experiment = try JSONDecoder().decode(
            Experiment.self,
            from: try await fixture(
                for: PostHogAPI.experiment(projectID: Self.projectID, experimentID: 71_103)
            )
        )
        #expect(complete.id == 71_103)
        #expect(complete.name == "Example export format trial")
        #expect(complete.configuredStatsMethod == .frequentist)
        #expect(complete.conclusion == .won)
        #expect(complete.metrics.count == 2)

        // The draft answers from its own row, and needs nothing more: it has
        // never launched, so the sheet returns before requesting any results.
        let draft: Experiment = try JSONDecoder().decode(
            Experiment.self,
            from: try await fixture(
                for: PostHogAPI.experiment(projectID: Self.projectID, experimentID: 71_102)
            )
        )
        #expect(draft.id == 71_102)
        #expect(draft.name == "Example onboarding hints trial")
        #expect(draft.hasLaunched == false)
    }

    /// Catches a detail metric overwriting another result in the UUID-keyed
    /// store, or a routed result naming an arm the experiment cannot assign.
    @Test("the demo experiment routes form one coherent graph")
    func demoExperimentRouteGraphIsCoherent() async throws {
        let page = try Page<Experiment>.decode(
            from: try await fixture(for: PostHogAPI.experiments(projectID: Self.projectID))
        )
        #expect(page.count == 4)
        #expect(page.results.map(\.id) == [71_101, 71_102, 71_103, 71_104])
        #expect(page.results.map(\.name) == [
            "Example cache strategy trial",
            "Example onboarding hints trial",
            "Example export format trial",
            "Example notification cadence trial",
        ])
        #expect(page.results.map { $0.featureFlagKey ?? "<missing>" } == [
            "example-cache-strategy",
            "example-onboarding-hints",
            "example-export-format",
            "example-notification-cadence",
        ])
        #expect(page.results.map { $0.featureFlagRaw?["key"]?.stringValue ?? "<missing>" } == [
            "example-cache-strategy",
            "example-onboarding-hints",
            "example-export-format",
            "example-notification-cadence",
        ])

        let running = try JSONDecoder().decode(
            Experiment.self,
            from: try await fixture(
                for: PostHogAPI.experiment(projectID: Self.projectID, experimentID: 71_101)
            )
        )
        #expect(running.name == "Example cache strategy trial")
        #expect(running.featureFlagKey == "example-cache-strategy")
        #expect(running.featureFlagRaw?["key"]?.stringValue == "example-cache-strategy")
        #expect(running.status == .running)
        #expect(running.startDate == PostHogDate.parse("2026-01-27T09:14:00.000Z"))
        #expect(running.endDate == nil)
        #expect(running.conclusion == nil)
        #expect(running.variants.map(\.key) == [
            "reference-cache-71101", "guided-cache-71101", "synthetic-observer-71101",
        ])
        #expect((running.metrics + running.secondaryMetrics).map { $0.uuid ?? "<missing>" } == [
            "018f9000-0000-7000-8000-000000000268",
            "018f9000-0000-7000-8000-000000000272",
            "018f9000-0000-7000-8000-000000000269",
            "018f9000-0000-7000-8000-000000000273",
        ])

        let complete = try JSONDecoder().decode(
            Experiment.self,
            from: try await fixture(
                for: PostHogAPI.experiment(projectID: Self.projectID, experimentID: 71_103)
            )
        )
        #expect(complete.name == "Example export format trial")
        #expect(complete.featureFlagKey == "example-export-format")
        #expect(complete.featureFlagRaw?["key"]?.stringValue == "example-export-format")
        #expect(complete.status == .stopped)
        #expect(complete.startDate == PostHogDate.parse("2026-01-11T10:02:00.000Z"))
        #expect(complete.endDate == PostHogDate.parse("2026-01-24T18:41:00.000Z"))
        #expect(complete.conclusion == .won)
        #expect(complete.variants.map(\.key) == [
            "reference-export-71103", "focused-export-71103", "synthetic-observer-71103",
        ])
        #expect((complete.metrics + complete.secondaryMetrics).map { $0.uuid ?? "<missing>" } == [
            "018f9000-0000-7000-8000-000000000270",
            "018f9000-0000-7000-8000-000000000274",
            "018f9000-0000-7000-8000-000000000271",
        ])

        let runningPrimary = try #require(running.metrics.first)
        let funnelEndpoint = try #require(
            PostHogAPI.experimentResult(
                projectID: Self.projectID,
                experimentID: running.id,
                metric: runningPrimary
            )
        )
        let funnel = try ExperimentMetricResult.decode(
            from: try await fixture(for: funnelEndpoint)
        )
        #expect([funnel.baseline?.key ?? "<missing>"] + funnel.variants.map(\.key) == [
            "reference-cache-71101", "guided-cache-71101", "synthetic-observer-71101",
        ])

        let runningSecondary = try #require(running.secondaryMetrics.first)
        let meanEndpoint = try #require(
            PostHogAPI.experimentResult(
                projectID: Self.projectID,
                experimentID: running.id,
                metric: runningSecondary
            )
        )
        let mean = try ExperimentMetricResult.decode(
            from: try await fixture(for: meanEndpoint)
        )
        #expect([mean.baseline?.key ?? "<missing>"] + mean.variants.map(\.key) == [
            "reference-cache-71101", "guided-cache-71101", "synthetic-observer-71101",
        ])

        let completedPrimary = try #require(complete.metrics.first)
        let shippedEndpoint = try #require(
            PostHogAPI.experimentResult(
                projectID: Self.projectID,
                experimentID: complete.id,
                metric: completedPrimary
            )
        )
        let shipped = try ExperimentMetricResult.decode(
            from: try await fixture(for: shippedEndpoint)
        )
        #expect([shipped.baseline?.key ?? "<missing>"] + shipped.variants.map(\.key) == [
            "reference-export-71103", "focused-export-71103", "synthetic-observer-71103",
        ])

        let runningExposures = try ExperimentExposures.decode(
            from: try await fixture(
                for: try #require(
                    PostHogAPI.experimentExposures(projectID: Self.projectID, experiment: running)
                )
            )
        )
        let runningStartDate = try #require(running.startDate)
        #expect(runningExposures.timeseries.flatMap(\.days).allSatisfy { $0 >= runningStartDate })

        let completeExposures = try ExperimentExposures.decode(
            from: try await fixture(
                for: try #require(
                    PostHogAPI.experimentExposures(projectID: Self.projectID, experiment: complete)
                )
            )
        )
        let completeStartDate = try #require(complete.startDate)
        let completeEndDate = try #require(complete.endDate)
        #expect(completeExposures.timeseries.flatMap(\.days).allSatisfy {
            $0 >= completeStartDate && $0 <= completeEndDate
        })
    }

    /// Each metric answers with *its own* numbers, and each experiment with its
    /// own arms.
    ///
    /// The failure both halves guard against is the quiet kind: a shared fixture
    /// decodes perfectly and shows the wrong experiment's variant keys, or the
    /// funnel's conversion numbers under the mean metric's name. Nothing throws,
    /// nothing is empty, and the screen states something false.
    @Test("experiment results and exposures are matched per metric and per experiment")
    func experimentResultsAreMatchedNotShared() async throws {
        let detail: Experiment = try JSONDecoder().decode(
            Experiment.self,
            from: try await fixture(
                for: PostHogAPI.experiment(projectID: Self.projectID, experimentID: 71_101)
            )
        )
        let primary = try #require(detail.metrics.first)
        let secondary = try #require(detail.secondaryMetrics.first)

        let funnel = try ExperimentMetricResult.decode(
            from: try await fixture(
                for: try #require(
                    PostHogAPI.experimentResult(
                        projectID: Self.projectID, experimentID: detail.id, metric: primary
                    )
                )
            )
        )
        #expect(funnel.metric?.uuid == primary.uuid)
        #expect(funnel.metric?.uuid == "018f9000-0000-7000-8000-000000000268")
        #expect(funnel.method == .bayesian)
        #expect(funnel.significant == true)
        // Bayesian rows carry a chance to win and no p-value; the labels on
        // screen are read off exactly this.
        let guidedFunnel = try #require(funnel.variants.first { $0.key == "guided-cache-71101" })
        #expect(guidedFunnel.chanceToWin != nil)
        #expect(guidedFunnel.pValue == nil)
        // A funnel metric has step counts. The mean one below must not.
        #expect(guidedFunnel.stepCounts?.count == 2)
        #expect(funnel.baseline?.numberOfSamples == 12_431)
        #expect(guidedFunnel.numberOfSamples == 12_587)

        let mean = try ExperimentMetricResult.decode(
            from: try await fixture(
                for: try #require(
                    PostHogAPI.experimentResult(
                        projectID: Self.projectID, experimentID: detail.id, metric: secondary
                    )
                )
            )
        )
        #expect(mean.metric?.uuid == secondary.uuid)
        #expect(mean.metric?.uuid == "018f9000-0000-7000-8000-000000000269")
        #expect(mean.metric?.uuid != primary.uuid)
        let guidedMean = try #require(mean.variants.first { $0.key == "guided-cache-71101" })
        #expect(guidedMean.stepCounts == nil)
        // Deliberately undecided. Every other readout in the demo is a called
        // result, and "no clear winner" is the state the screen spends most of
        // its life in.
        #expect(mean.significant == false)
        #expect(ExperimentReadout(result: mean, isRunning: true).verdict.isDecided == false)

        // The completed experiment's metric is the frequentist branch: p-value
        // and confidence interval, no chance to win.
        let complete: Experiment = try JSONDecoder().decode(
            Experiment.self,
            from: try await fixture(
                for: PostHogAPI.experiment(projectID: Self.projectID, experimentID: 71_103)
            )
        )
        let shippedMetric = try #require(complete.metrics.first)
        let shippedEndpoint = try #require(
            PostHogAPI.experimentResult(
                projectID: Self.projectID, experimentID: complete.id, metric: shippedMetric
            )
        )
        let shipped = try ExperimentMetricResult.decode(
            from: try await fixture(for: shippedEndpoint)
        )
        #expect(shipped.method == .frequentist)
        #expect(shipped.metric?.uuid == "018f9000-0000-7000-8000-000000000270")
        #expect(shipped.baseline?.numberOfSamples == 14_207)
        let focusedExport = try #require(shipped.variants.first { $0.key == "focused-export-71103" })
        #expect(focusedExport.numberOfSamples == 14_399)
        #expect(focusedExport.pValue != nil)
        #expect(focusedExport.chanceToWin == nil)
        // The statistical verdict must agree with the conclusion the team
        // stored on the row; a demo where the two contradicted each other
        // would read as a bug in one of them.
        #expect(ExperimentReadout(result: shipped, isRunning: true).verdict.isDecided)

        // Exposures are per experiment, because the payload names the arms.
        let runningExposures = try ExperimentExposures.decode(
            from: try await fixture(
                for: try #require(
                    PostHogAPI.experimentExposures(projectID: Self.projectID, experiment: detail)
                )
            )
        )
        let completeExposures = try ExperimentExposures.decode(
            from: try await fixture(
                for: try #require(
                    PostHogAPI.experimentExposures(projectID: Self.projectID, experiment: complete)
                )
            )
        )
        #expect(Set(runningExposures.totals.keys) == [
            "reference-cache-71101", "guided-cache-71101", "synthetic-observer-71101",
        ])
        #expect(Set(completeExposures.totals.keys) == [
            "reference-export-71103", "focused-export-71103", "synthetic-observer-71103",
        ])
        // Every arm named in the exposures must be an arm the experiment
        // actually has — this is the assertion a shared fixture fails.
        #expect(Set(runningExposures.totals.keys) == Set(detail.variants.map(\.key)))
        #expect(Set(completeExposures.totals.keys) == Set(complete.variants.map(\.key)))
        // And the counts must match the metric's sample sizes, or the exposure
        // section and the metric section disagree on the same screen.
        #expect(runningExposures.totals["reference-cache-71101"] == Double(funnel.baseline?.numberOfSamples ?? 0))
        #expect(completeExposures.totals["reference-export-71103"] == Double(shipped.baseline?.numberOfSamples ?? 0))
        // Both splits read healthy, so no mismatch banner is drawn over numbers
        // the demo is asking a reader to trust.
        #expect(!runningExposures.hasSampleRatioMismatch)
        #expect(!completeExposures.hasSampleRatioMismatch)
    }

    /// Synthetic fixtures must not carry a provenance note that can drift back
    /// toward tenant-specific language.
    @Test("synthetic fixtures omit provenance metadata")
    func syntheticFixturesOmitProvenanceMetadata() async throws {
        let paths = [
            "experiments", "experiment_detail_running", "experiment_detail_complete",
            "experiment_result_funnel", "experiment_result_mean", "experiment_result_shipped",
            "experiment_exposures_running", "experiment_exposures_complete",
            "conversations_tickets", "conversations_ticket_messages",
            "survey_results_summary", "survey_answers",
            "organization_projects", "organization_projects_second",
            "warehouse_saved_queries",
            "warehouse_saved_query_failed", "warehouse_saved_query_modified",
            "warehouse_saved_query_healthy", "warehouse_saved_query_plain",
            "data_modeling_jobs", "data_modeling_jobs_healthy",
            "notebooks_list", "notebook_detail", "notebook_detail_plain",
        ]
        for name in paths {
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "json")
                    ?? Bundle.main.url(forResource: "DemoData/\(name)", withExtension: "json")
            )
            let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            #expect((object as? [String: Any])?["_note"] == nil)
        }
    }

    /// Files that previously carried edit history follow the same no-provenance contract.
    @Test("formerly edited fixtures omit provenance metadata")
    func editedFixturesOmitProvenanceMetadata() throws {
        for name in ["surveys", "users_me"] {
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "json")
                    ?? Bundle.main.url(forResource: "DemoData/\(name)", withExtension: "json")
            )
            let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            #expect((object as? [String: Any])?["_note"] == nil)
        }
    }

    /// The priority correction in this pass: a path with no fixture must be
    /// distinguishable from a collection that is genuinely empty.
    ///
    /// `Page<T>` has no custom `init(from:)`, its three metadata fields are all
    /// `Optional`, and an empty `results` array never has to decode an element —
    /// so the old catch-all decoded cleanly as **any** `Page`, for every `T`.
    /// That made a missing route and an empty project byte-identical, and the
    /// screens that word an empty state as a finding stated the second as the
    /// first: Health's "PostHog hasn't flagged any problems with this project's
    /// instrumentation", Automation's "Nothing is leaving this project in bulk",
    /// and the `RenderLookup.loaded([])`-versus-`.failed` machinery in Heatmaps
    /// that exists for precisely this distinction and was walked straight past,
    /// because a 200 throws nothing.
    ///
    /// Asserted through the real `PostHogAPI` builders, so a route added for one
    /// of these later breaks this test rather than passing it by coincidence of
    /// a hand-typed path.
    @Test("a path with no fixture fails loudly instead of answering an empty page")
    func unroutedPathsAreNotEmptyPages() async throws {
        let unrouted: [(String, Endpoint)] = [
            (
                "unknown Max detail",
                PostHogAPI.conversation(
                    projectID: Self.projectID,
                    conversationID: "not-authored"
                )
            ),
            (
                "unknown saved clickmap detail",
                PostHogAPI.savedHeatmap(projectID: Self.projectID, shortID: "not-authored")
            ),
        ]

        for (name, endpoint) in unrouted {
            var components = URLComponents(string: "https://app.example.com" + endpoint.path)!
            if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
            var request = URLRequest(url: components.url!)
            request.httpMethod = endpoint.method
            request.httpBody = endpoint.body
            let (data, response) = try await DemoTransport().send(request)

            #expect(response.statusCode == 501, "\(name) should not answer 200")
            // Not a `Page` at all — the shape is what stops a caller reading it
            // as zero rows even if it ignored the status.
            #expect(throws: (any Error).self) { try Page<FeatureFlag>.decode(from: data) }
            // And the sentence has to name the path, because "no fixture" is
            // only actionable if the reader knows which one. Read through the
            // envelope rather than off the bytes: `JSONSerialization` escapes
            // the slashes, so a raw `contains` on the path never matches — and
            // the envelope is also the shape `PostHogClient` reads to build
            // `PostHogError.http(detail:)`, which is what the reader sees.
            let detail = try #require(
                (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
                    as? String
            )
            #expect(detail.contains(endpoint.path), "\(name) should name its own path")
        }
    }

    /// The other half of the same rule, and the reason it is an allow-list
    /// rather than a blanket failure.
    ///
    /// Actions and annotations are intentional authored empty states, so these
    /// routes must keep answering 200 — a demo that
    /// errored here would be trading one wrong answer for another.
    @Test("collections modeled as empty still answer an empty page")
    func authoredEmptyCollectionsStayEmpty() async throws {
        for path in ["/api/projects/1001/actions/", "/api/projects/1001/annotations/"] {
            let (data, response) = try await reply(for: path)
            #expect(response.statusCode == 200, "\(path) is an intentional empty fixture, not a gap")
            #expect(try Page<Annotation>.decode(from: data).results.isEmpty)
        }
    }

    /// These two routes are the terminal empty states rendered by the Vision
    /// catalog sweep. Exercise the production endpoint builders so a path rename
    /// cannot leave the test passing against a hand-written URL the app no
    /// longer sends.
    @Test("empty Inbox and Signals routes decode as authored empty pages")
    func authoredEmptyMonitorCollectionsStayEmpty() async throws {
        let (tasksData, tasksResponse) = try await reply(
            for: PostHogAPI.tasks(projectID: Self.projectID)
        )
        #expect(tasksResponse.statusCode == 200)

        let (reportsData, reportsResponse) = try await reply(
            for: PostHogAPI.signalReports(projectID: Self.projectID)
        )
        #expect(reportsResponse.statusCode == 200)

        // Decode independently after both requests. A 501 envelope is not a
        // Page and must fail both expectations without its first decoding error
        // preventing the Signals endpoint from being exercised.
        #expect((try? Page<AgentTask>.decode(from: tasksData))?.results.isEmpty == true)
        #expect((try? Page<SignalReport>.decode(from: reportsData))?.results.isEmpty == true)
    }

    /// Every collection this rendered Vision catalog sweep reaches must have an
    /// authored demo answer. Drive the production builders independently so an
    /// early 501 cannot prevent later routes from being exercised, and decode
    /// each body using the concrete type its screen consumes.
    @Test("rendered catalog collections have typed authored demo answers")
    @MainActor
    func renderedCatalogCollectionsResolve() async throws {
        let (heatmapData, heatmapResponse) = try await reply(
            for: PostHogAPI.heatmap(projectID: Self.projectID)
        )
        let (elementsData, elementsResponse) = try await reply(
            for: PostHogAPI.elementStats(projectID: Self.projectID)
        )
        let (savedData, savedResponse) = try await reply(
            for: PostHogAPI.savedHeatmaps(projectID: Self.projectID)
        )
        let (pipelinesData, pipelinesResponse) = try await reply(
            for: PipelinesStore.hogFunctionsEndpoint(projectID: Self.projectID)
        )
        let (workflowsData, workflowsResponse) = try await reply(
            for: PostHogAPI.hogFlows(projectID: Self.projectID)
        )
        let (endpointsData, endpointsResponse) = try await reply(
            for: PostHogAPI.queryEndpoints(projectID: Self.projectID)
        )
        let (subscriptionsData, subscriptionsResponse) = try await reply(
            for: PostHogAPI.subscriptions(projectID: Self.projectID)
        )
        let (exportsData, exportsResponse) = try await reply(
            for: PostHogAPI.batchExports(projectID: Self.projectID)
        )
        let (earlyAccessData, earlyAccessResponse) = try await reply(
            for: PostHogAPI.earlyAccessFeatures(projectID: Self.projectID)
        )
        let (maxData, maxResponse) = try await reply(
            for: PostHogAPI.conversations(projectID: Self.projectID)
        )

        #expect(heatmapResponse.statusCode == 200, "heatmap coordinates need an authored answer")
        #expect(elementsResponse.statusCode == 200, "element stats need an authored answer")
        #expect(savedResponse.statusCode == 200, "saved clickmaps need their fixture")
        #expect(pipelinesResponse.statusCode == 200, "pipelines need an authored empty page")
        #expect(workflowsResponse.statusCode == 200, "workflows need an authored empty page")
        #expect(endpointsResponse.statusCode == 200, "endpoints need an authored empty page")
        #expect(subscriptionsResponse.statusCode == 200, "subscriptions need an authored empty page")
        #expect(exportsResponse.statusCode == 200, "batch exports need an authored empty page")
        #expect(earlyAccessResponse.statusCode == 200, "early access needs an authored empty page")
        #expect(maxResponse.statusCode == 200, "Max needs an authored empty page")

        #expect((try? HeatmapResponse.decode(from: heatmapData))?.results.isEmpty == true)
        #expect((try? Page<ElementStat>.decode(from: elementsData))?.results.isEmpty == true)
        let saved = try? Page<SavedHeatmap>.decode(from: savedData)
        #expect(saved?.results.isEmpty == false)
        #expect(saved?.results.contains(where: \.isRenderable) == true)
        #expect((try? Page<HogFunction>.decode(from: pipelinesData))?.results.isEmpty == true)
        #expect((try? Page<Workflow>.decode(from: workflowsData))?.results.isEmpty == true)
        #expect((try? Page<QueryEndpoint>.decode(from: endpointsData))?.results.isEmpty == true)
        #expect(
            (try? Page<InsightSubscription>.decode(from: subscriptionsData))?.results.isEmpty
                == true
        )
        #expect((try? Page<BatchExport>.decode(from: exportsData))?.results.isEmpty == true)
        #expect(
            (try? Page<EarlyAccessFeature>.decode(from: earlyAccessData))?.results.isEmpty == true
        )
        #expect((try? Page<MaxConversation>.decode(from: maxData))?.results.isEmpty == true)
    }

    /// Survey results, which are two HogQL queries and were therefore answered
    /// by the events fixture.
    ///
    /// The failure was silent in the way this file keeps finding: the events
    /// fixture decodes as a perfectly good `QueryResponse` and simply carries no
    /// `impressions` column, so every counter read zero, `SurveyResultsSummary`
    /// came back `isEmpty`, and the sheet settled on a state whose words are
    /// "Ran and returned nothing". The whole results screen — the funnel, the
    /// rating distribution, the answers list and the on-device summary card
    /// above it — was unreachable in demo mode.
    ///
    /// Driven through `PostHogAPI.surveyResultsSummary` and `surveyResponses`
    /// with the demo's own `Survey`, so the routing keys on the SQL those
    /// builders actually emit for that survey's question ids.
    @Test("a launched survey's results resolve to survey fixtures, not the events fixture")
    func surveyResultsResolve() async throws {
        let surveys = try Page<Survey>.decode(
            from: try await fixture(for: "/api/projects/1001/surveys/")
        ).results
        // Exactly one demo survey carries a start date, and that is what makes
        // the queries happen at all — `SurveyResultsStore` returns without
        // spending one when it is absent. Both states have to stay reachable.
        let launched = surveys.filter { $0.startDate != nil }
        #expect(launched.count == 1)
        #expect(surveys.contains { $0.startDate == nil })
        let survey = try #require(launched.first)

        let summary = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.surveyResultsSummary(projectID: Self.projectID, survey: survey)
            )
        )
        let answers = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.surveyResponses(projectID: Self.projectID, survey: survey)
            )
        )

        // The column the events fixture does not have, and the reason this
        // route exists. Asserting the state rather than the row count, because
        // the state is what the screen draws.
        let state = SurveyResults.state(survey: survey, summary: summary, answers: answers)
        guard case .measured(let results) = state else {
            Issue.record("expected a measured survey, got \(state)")
            return
        }
        #expect(results.summary.impressions > 0)
        // The number a naive reading gets wrong, and the one the fixtures were
        // written to disagree on: more submissions carry an answer than the
        // funnel calls "responses", because dismissals can be partial. A fixture
        // where the two matched would let the aggregation regress unnoticed.
        #expect(results.summary.answeringSubmissions > results.summary.responses)
        #expect(results.questions.count == survey.questions.count)
        #expect(results.questions.contains { if case .rating = $0.breakdown { true } else { false } })
        #expect(results.questions.contains { if case .text = $0.breakdown { true } else { false } })
        // 16 rows against LIMIT 500, so the answers are the whole set and the
        // screen must not claim otherwise.
        #expect(results.isTruncated == false)

        // A draft must still answer nothing rather than borrowing these numbers.
        let draft = try #require(surveys.first { $0.startDate == nil })
        let borrowed = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.surveyResultsSummary(projectID: Self.projectID, survey: draft)
            )
        )
        #expect(borrowed.rows.isEmpty)
    }

    /// Organization switching, which had no route and no control to reach one.
    ///
    /// Two halves, and the demo needed both. `RootView.organizationList` is
    /// drawn only for `AppModel.isMultiOrganization`, and the fixture identity
    /// belongs to one organization — so the switch could not be invoked at all;
    /// and `/api/organizations/:id/projects/` had no route, so invoking it would
    /// have reached the empty page. That second failure was the worse one:
    /// `selectOrganization` is the one place in the app already written not to
    /// read zero results as success, and its refusal names the reader's API key
    /// as the likely cause — a plausible sentence about a credential the demo
    /// does not have.
    @Test("organization switching finds two organizations and each one's projects")
    func organizationProjectsResolve() async throws {
        let me = try JSONDecoder().decode(
            MeResponse.self, from: try await fixture(for: "/api/users/@me/")
        )
        let organizations = me.allOrganizations
        #expect(organizations.count == 2, "the switcher is not drawn for a single organization")

        var seen: [String: [Int]] = [:]
        for organization in organizations {
            let page = try Page<Project>.decode(
                from: try await fixture(
                    for: PostHogAPI.organizationProjects(organizationID: organization.id)
                )
            )
            #expect(!page.results.isEmpty, "\(organization.name) must not come back empty")
            seen[organization.id] = page.results.map(\.id)
        }

        // Disjoint, because one fixture serving both would land every switch on
        // the same project and make a switch that did nothing look like one that
        // worked. A project belongs to one organization.
        let all = seen.values.flatMap { $0 }
        #expect(Set(all).count == all.count)
        // The current organization must answer the canonical fictional project,
        // or switching away and back would arrive somewhere else.
        #expect(seen[try #require(me.currentOrganizationID)]?.contains(1_001) == true)
        #expect(seen["018f9000-0000-7000-8000-000000000443"] == [1_301])
    }

    @Test("a duration filter actually removes recordings in demo mode")
    func recordingFiltersAreNotInert() async throws {
        let unfiltered = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(for: "/api/projects/1001/session_recordings/")
        )

        // 765s sits between the 4s session and the 2075s one, so this is a
        // boundary the fixture data can actually answer.
        let filtered = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: "/api/projects/1001/session_recordings/",
                query: [URLQueryItem(
                    name: "having_predicates",
                    value: #"[{"key":"recording_duration","type":"recording","value":"765","operator":"gte"}]"#
                )]
            )
        )

        #expect(filtered.results.count < unfiltered.results.count)
        #expect(!filtered.results.isEmpty)
        // `gte`, so the recording *at* the threshold is kept — the same
        // boundary the documented API was checked against.
        #expect(filtered.results.contains { $0.recordingDuration == 765 })
        #expect(filtered.results.allSatisfy { ($0.recordingDuration ?? 0) >= 765 })
        // A cursor from the unfiltered page would page the excluded
        // sessions straight back in.
        #expect(filtered.hasNext == false)
    }
}

/// The demo Health screen's complete success path.
///
/// This is its own suite so a fixture-routing failure can be selected without
/// running the rest of the large demo transport catalog. It deliberately drives
/// `PostHogAPI.healthIssues`, not a hand-written path: a builder change must
/// break the fixture contract rather than silently leaving the app unrouted.
@Suite("Demo health fixture")
@MainActor
struct DemoHealthFixtureTests {

    private static let projectID = 1001

    @Test("health issues serve scrollable active and resolved data with freshness")
    func healthIssuesResolveForTheRenderedScreen() async throws {
        let endpoint = PostHogAPI.healthIssues(projectID: Self.projectID)
        var components = try #require(
            URLComponents(string: "https://app.example.com" + endpoint.path)
        )
        components.queryItems = endpoint.query
        var request = URLRequest(url: try #require(components.url))
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body

        let transport = DemoTransport()
        let (data, response) = try await transport.send(request)
        #expect(response.statusCode == 200)

        let page = try Page<HealthIssue>.decode(from: data)
        #expect(page.results.count >= 12, "Health needs enough cards to exercise its scroll end")
        #expect(page.results.contains { $0.status == .active })
        #expect(page.results.contains { $0.status == .resolved })
        #expect(page.results.contains { $0.createdAt != nil })

        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: transport
        )
        let store = HealthStore()
        await store.load(client: client, projectID: Self.projectID)

        #expect(store.error == nil)
        #expect(store.issues.count >= 12)
        #expect(!store.active.isEmpty)
        #expect(!store.resolved.isEmpty)
        #expect(store.loadedAt != nil, "FreshnessLabel must receive a successful-load date")
    }
}

// MARK: - Groups, taxonomy, warehouse and notebooks

/// The three feature areas whose fixtures shipped without routes, and the one
/// route that was answering the wrong thing rather than nothing.
///
/// Every assertion here drives the real `PostHogAPI` builder, for the reason the
/// extension above documents and with one extra edge in this batch: four of
/// these routes are keyed on **the SQL a builder emits**, not on a query kind,
/// so a rewritten `SELECT` list has to break this file rather than silently
/// re-route four screens onto the events fixture.
extension DemoTransportTests {

    /// A fixed instant for the `since` floor, so the SQL these builders emit is
    /// stable and the routing is what varies.
    ///
    /// The value is irrelevant — no route reads the timestamp — but a `Date()`
    /// here would put a moving string into every request body, which is the kind
    /// of detail that makes a failure hard to reproduce.
    private static let since = Date(timeIntervalSince1970: 1_785_000_000)
    private static let demoGroupKey = "group-harbor-3101"

    /// The group screen makes three requests and two of them are HogQL, so both
    /// were being answered by the events fixture — silently, because
    /// `query_hogql.json` decodes as a perfectly good `QueryResponse` and simply
    /// lacks their columns.
    ///
    /// Asserted through the row models rather than on the raw response, because
    /// the columns are the whole point: a wrongly-routed answer yields *zero*
    /// rows from `compactMap(init(row:))`, which on screen is an empty state
    /// over a group that did two thousand things.
    @Test("a group's activity and people resolve to their own recordings")
    func groupQueriesResolveSeparately() async throws {
        let breakdown = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.groupEventBreakdown(
                    projectID: Self.projectID,
                    groupTypeIndex: 0,
                    groupKey: Self.demoGroupKey,
                    since: Self.since
                )
            )
        ).rows.compactMap(GroupEventBreakdownRow.init(row:))
        #expect(breakdown.count == 7)
        #expect(breakdown.first?.event == "harbor_dashboard_opened")
        #expect(breakdown.first?.occurrences == 620)
        // The window totals are what let the screen say "top twelve of
        // seventeen" truthfully. A fixture without them would leave every share
        // on the screen computed against the visible rows.
        #expect(breakdown.first?.totalOccurrences ?? 0 > 0)
        #expect(breakdown.first?.distinctEvents ?? 0 > breakdown.count)

        let people = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.groupPeople(
                    projectID: Self.projectID,
                    groupTypeIndex: 0,
                    groupKey: Self.demoGroupKey,
                    since: Self.since
                )
            )
        ).rows.compactMap(GroupPersonRow.init(row:))
        #expect(people.count == 4)
        #expect(people.first?.personID == "person-harbor-401")
        #expect(people.first?.name == "Mira Lane")
        #expect(people.first?.distinctPeople == 7)
        // The two must not be the same fixture: they answer different questions
        // and a route serving one to both would make the group's event names and
        // its people identical lists.
        #expect(people.contains { $0.hasHumanName })
    }

    /// The pair that share a marker, and the only pair in this batch that a
    /// single sloppy `contains` could merge.
    ///
    /// Both compute `distinct_values`; what separates them is `GROUP BY value`
    /// against `GROUP BY event`, which is also the difference in what they mean.
    /// Serving the distribution to the carrier list would head a column "Event"
    /// and fill it with browser names — plausible, decodable, false.
    @Test("the two property-depth queries are told apart by what they group by")
    func propertyDepthQueriesDoNotShareAFixture() async throws {
        let values = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.propertyValueDistribution(
                    projectID: Self.projectID, property: "$browser", since: Self.since
                )
            )
        ).rows.compactMap(PropertyValueShare.init(row:))
        #expect(values.count == 5)
        #expect(values.first?.value == "FixtureFox")
        #expect(values.first?.occurrences == 310)
        #expect(values.first?.totalOccurrences == 940)
        #expect(values.first?.distinctValues == 9)
        #expect(values.first?.totalOccurrences ?? 0 > values.first?.occurrences ?? 0)

        let carriers = try QueryResponse.decode(
            from: try await fixture(
                for: PostHogAPI.propertyCarrierEvents(
                    projectID: Self.projectID, property: "$browser", since: Self.since
                )
            )
        ).rows.compactMap(PropertyCarrierEvent.init(row:))
        #expect(carriers.count == 7)
        #expect(carriers.first?.event == "example_orbit_viewed")
        #expect(carriers.first?.occurrences == 610)
        #expect(carriers.first?.totalOccurrences == 2_830)
        #expect(carriers.first?.distinctEvents == 13)
        #expect(carriers.map(\.distinctValues) == [41, 53, 67, 79, 83, 97, 109])
        // The assertion a merged route fails: one lists values, the other lists
        // event names, and no browser is an event.
        #expect(!carriers.contains { $0.event == "FixtureFox" })
        #expect(!values.contains { $0.value == "example_orbit_viewed" })
    }

    /// The actor-side taxonomy, which is the whole of the property screen for a
    /// property that lives on a group rather than on an event.
    @Test("a group property's values resolve to the actors taxonomy fixture")
    func actorsPropertyTaxonomyResolves() async throws {
        let page = try Page<TaxonomyPropertySample>.decode(
            from: try await fixture(
                for: PostHogAPI.actorsPropertyTaxonomy(
                    projectID: Self.projectID, properties: ["name"], groupTypeIndex: 0
                )
            )
        )
        // Positional and parallel to the `properties` array that was sent — the
        // response carries no `property` key at all, so the pairing is by index
        // and a second row would be attributed to a property nobody asked for.
        #expect(page.results.count == 1)
        let sample = try #require(TaxonomyPropertySample.zip(["name"], with: page.results).first)
        #expect(sample.property == "name")
        #expect(!sample.sampleValues.isEmpty)
        #expect(sample.sampleCount > sample.sampleValues.count)
    }

    /// Property definitions, which two screens ask for at two different scopes
    /// and which had no route at all.
    @Test("property definitions resolve project-wide and scoped to one event")
    func propertyDefinitionsResolve() async throws {
        let all = try Page<PropertyDefinitionSummary>.decode(
            from: try await fixture(for: PostHogAPI.propertyDefinitions(projectID: Self.projectID))
        )
        #expect(!all.results.isEmpty)
        // The fixture page is the first 200 of 779, and the count is what the
        // Taxonomy header reports. An empty page here used to be a 501, so the
        // whole Properties tab was a failure state.
        #expect(all.count == 779)

        // The event-scoped call is the join `TaxonomyEventDetailView` reads as a
        // *lookup table*, keyed by property name — so serving the project-wide
        // page to it is safe in a way that iterating it as "this event's
        // properties" would not be. Asserted here so that stays checked.
        let scoped = try Page<PropertyDefinitionSummary>.decode(
            from: try await fixture(
                for: PostHogAPI.propertyDefinitions(
                    projectID: Self.projectID, eventNames: ["$pageview"]
                )
            )
        )
        let byName = Dictionary(scoped.results.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["$browser"] != nil)
    }

    /// The route that was a **wrong** answer rather than an empty one.
    ///
    /// `groupRecordings` narrows the ordinary recordings list with a `$group_N`
    /// event property, and `filteredRecordings` ignored `properties` entirely —
    /// so every group in the demo was handed the project's whole recording list
    /// under a heading saying the sessions belonged to that group. Nothing threw,
    /// nothing was empty, and it was false in the direction a reader cannot
    /// check.
    ///
    /// Asserted as a strict subset rather than by a row count, because a count
    /// would still pass if the two fixtures were swapped.
    @Test("a group's recordings are scoped to the group, not the whole project")
    func groupRecordingsAreNotTheWholeProject() async throws {
        let everything = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(for: PostHogAPI.sessionRecordings(projectID: Self.projectID))
        )
        let scoped = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: PostHogAPI.groupRecordings(
                    projectID: Self.projectID, groupTypeIndex: 0, groupKey: Self.demoGroupKey
                )
            )
        )

        #expect(!scoped.results.isEmpty)
        #expect(scoped.results.count < everything.results.count)
        #expect(everything.results.count == 5)
        #expect(scoped.results.map(\.id) == [
            "018f1000-0000-7000-8000-000000000002",
            "018f1000-0000-7000-8000-000000000004",
        ])
        let all = Set(everything.results.map(\.id))
        #expect(scoped.results.allSatisfy { all.contains($0.id) })

        // The second group type has to be scoped too — the clause is `$group_1`
        // there, and a check keyed on `$group_0` would leave it unnarrowed.
        let secondType = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: PostHogAPI.groupRecordings(
                    projectID: Self.projectID, groupTypeIndex: 1, groupKey: Self.demoGroupKey
                )
            )
        )
        #expect(secondType.results.count == scoped.results.count)

        // And the ordinary filter sheet must still reach the project-wide
        // fixture, or fixing the group case would have blanked every other
        // narrowing on the recordings screen.
        var duration = SessionRecordingFilter()
        duration.minimumDuration = 100
        let byDuration = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: PostHogAPI.sessionRecordings(projectID: Self.projectID, filter: duration)
            )
        )
        #expect(!byDuration.results.isEmpty)
        #expect(byDuration.results.allSatisfy { ($0.recordingDuration ?? 0) >= 100 })
        #expect(byDuration.results.count < everything.results.count)
    }

    /// The filter sheet's **own** encoding, which nothing had ever run through
    /// this transport.
    ///
    /// `recordingFiltersAreNotInert` above builds `having_predicates` as a
    /// literal keyed on `recording_duration`, which is the column name in the
    /// *response*. The sheet does not send that: `DurationMetric.total` — the
    /// default, and the control a reader actually reaches for — encodes
    /// `"key": "duration"`, and no fixture row carries a `duration` key at all.
    /// So the filter matched nothing, removed every row, and the demo answered
    /// "no recordings" for any minimum duration a reader chose. A hand-written
    /// literal could not have caught that, which is the whole reason this suite
    /// drives the real builders.
    @Test("the sheet's own duration filter narrows rather than emptying the list")
    func recordingFiltersHonourTheSheetsOwnKeys() async throws {
        let everything = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(for: PostHogAPI.sessionRecordings(projectID: Self.projectID))
        )

        var total = SessionRecordingFilter()
        total.minimumDuration = 1_000
        total.durationMetric = .total
        let byTotal = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: PostHogAPI.sessionRecordings(projectID: Self.projectID, filter: total)
            )
        )
        #expect(!byTotal.results.isEmpty, "a total-length floor must not empty the list")
        #expect(byTotal.results.count < everything.results.count)
        #expect(byTotal.results.allSatisfy { ($0.recordingDuration ?? 0) >= 1_000 })

        // The other metric needs no translation — its predicate key and its
        // column are both `active_seconds` — and asserting it here is what keeps
        // the map from being "rename everything".
        var active = SessionRecordingFilter()
        active.minimumDuration = 40
        active.durationMetric = .active
        let byActive = try JSONDecoder().decode(
            RecordingList.self,
            from: try await fixture(
                for: PostHogAPI.sessionRecordings(projectID: Self.projectID, filter: active)
            )
        )
        #expect(!byActive.results.isEmpty)
        // The two metrics must not select the same rows, or one of them is
        // reading the other's column.
        #expect(byActive.results.map(\.id) != byTotal.results.map(\.id))
    }

    /// The warehouse's imported-data half: two independent collections whose
    /// absence must remain distinguishable from a successfully empty project.
    @Test("warehouse collection routes serve the source and table catalogues")
    @MainActor
    func warehouseCollectionRoutes() async throws {
        let sourceReply = try await reply(
            for: WarehouseStore.sourcesEndpoint(projectID: Self.projectID)
        )
        #expect(sourceReply.1.statusCode == 200)
        let sources = try Page<ExternalDataSource>.decode(from: sourceReply.0)
        #expect(sources.count == 2)
        #expect(sources.results.map(\.id) == [
            "018f9000-0000-7000-8000-000000000222",
            "018f9000-0000-7000-8000-000000000223",
        ])
        #expect(sources.results.map(\.displayName) == ["S3", "Github (example_)"])

        let tableReply = try await reply(
            for: WarehouseStore.tablesEndpoint(projectID: Self.projectID)
        )
        #expect(tableReply.1.statusCode == 200)
        let tables = try Page<WarehouseTable>.decode(from: tableReply.0)
        #expect(tables.count == tables.results.count)
        #expect(tables.count == 2)
        #expect(tables.results.map(\.id) == [
            "018f9000-0000-7000-8000-000000000264",
            "018f9000-0000-7000-8000-000000000265",
        ])
        #expect(tables.results.map(\.name) == [
            "demo_accounts", "example_pull_requests",
        ])
        for table in tables.results where table.isManaged {
            let sourceID = try #require(table.sourceID)
            let schemaName = try #require(table.schemaName)
            let source = try #require(sources.results.first { $0.id == sourceID })
            #expect(
                source.schemas.contains { $0.name == schemaName },
                "\(table.name) references a schema absent from source \(sourceID)"
            )
        }

        // These are list-only demo declarations. Matching `contains` instead of
        // the collection suffix would turn every invented child into the list,
        // hiding the same missing-fixture class this test is here to prevent.
        for path in [
            "/api/projects/\(Self.projectID)/external_data_sources/not-authored/",
            "/api/projects/\(Self.projectID)/warehouse_tables/not-authored/",
        ] {
            let (_, response) = try await reply(for: Endpoint(path: path, category: .crud))
            #expect(response.statusCode == 501, "\(path) must remain an undeclared detail")
        }
        for path in [
            WarehouseStore.sourcesEndpoint(projectID: Self.projectID).path,
            WarehouseStore.tablesEndpoint(projectID: Self.projectID).path,
        ] {
            for method in ["POST", "PATCH", "DELETE"] {
                let endpoint = Endpoint(path: path, method: method, category: .crud)
                let (_, response) = try await reply(for: endpoint)
                #expect(
                    response.statusCode == 501,
                    "\(method) \(path) must not receive the GET collection fixture"
                )
            }
        }
    }

    /// The warehouse's modelling half: one list, four details, and a run history
    /// that answers three different ways.
    @Test("each saved query serves its own definition and its own run history")
    func warehouseRoutesSplitPerView() async throws {
        let list = try Page<SavedQuery>.decode(
            from: try await fixture(for: PostHogAPI.savedQueries(projectID: Self.projectID))
        )
        #expect(list.results.count == 4)
        // One row per materialisation state the screen has to tell apart. Four
        // identical states would leave the banner and the tinting untested.
        #expect(
            Set(list.results.map(\.materialization))
                == [.failed, .editedSinceRun, .upToDate, .notMaterialized]
        )
        // The list serializer drops the SQL, and that absence is why the detail
        // request exists at all.
        #expect(list.results.allSatisfy { $0.query == nil })

        for row in list.results {
            let detail = try JSONDecoder().decode(
                SavedQuery.self,
                from: try await fixture(
                    for: PostHogAPI.savedQuery(projectID: Self.projectID, id: row.id)
                )
            )
            // The assertion a shared stand-in fails: each view's SQL must arrive
            // under that view's own name.
            #expect(detail.id == row.id)
            #expect(detail.name == row.name)
            #expect(detail.query != nil, "\(row.name) came back with no definition")
        }

        // Suspension is on the detail serializer and not on the list one, so it
        // is only reachable this way — and it is the worst state this screen can
        // report, the one that means there is no next run rather than that the
        // last one failed.
        let failed = try JSONDecoder().decode(
            SavedQuery.self,
            from: try await fixture(
                for: PostHogAPI.savedQuery(
                    projectID: Self.projectID, id: Self.failedSavedQueryID
                )
            )
        )
        #expect(failed.isSuspended)
        #expect(try #require(list.results.first { $0.id == failed.id }).isSuspended == false)

        // An id in no fixture is a gap, not a fifth view, and must say so rather
        // than borrow one of the four.
        let unknown = try await reply(
            for: PostHogAPI.savedQuery(
                projectID: Self.projectID, id: "018f0000-0000-7000-8000-999999999999"
            )
        )
        #expect(unknown.1.statusCode == 501)
    }

    /// The run history, which is the one route in this batch that deliberately
    /// answers three different ways for four views.
    @Test("a run history belongs to its own view, and says so when there is none")
    func dataModelingJobsAreMatchedPerView() async throws {
        let failing = try Page<DataModelingJob>.decode(
            from: try await fixture(
                for: PostHogAPI.dataModelingJobs(
                    projectID: Self.projectID,
                    savedQueryID: Self.failedSavedQueryID
                )
            )
        )
        #expect(failing.results.contains { $0.didFail })
        #expect(failing.results.allSatisfy { $0.savedQueryID == Self.failedSavedQueryID })

        let healthy = try Page<DataModelingJob>.decode(
            from: try await fixture(
                for: PostHogAPI.dataModelingJobs(
                    projectID: Self.projectID,
                    savedQueryID: Self.healthySavedQueryID
                )
            )
        )
        // The whole reason there are two files: a healthy history has to be
        // seeable, or the section only ever ships in its failure state.
        #expect(!healthy.results.isEmpty)
        #expect(healthy.results.allSatisfy { !$0.didFail })

        // The view with no stored table answers an empty page, and that is a
        // derivation rather than a stand-in — `is_materialized: false` means it
        // has no runs by construction, and the screen has a sentence for it.
        let plain = try await reply(
            for: PostHogAPI.dataModelingJobs(
                projectID: Self.projectID, savedQueryID: Self.plainSavedQueryID
            )
        )
        #expect(plain.1.statusCode == 200)
        #expect(try Page<DataModelingJob>.decode(from: plain.0).results.isEmpty)

        // The materialised view with no fixture history answers 501 instead,
        // because an empty page there would contradict the `last_run_at` its own
        // row carries — one screen disagreeing with itself.
        let modified = try await reply(
            for: PostHogAPI.dataModelingJobs(
                projectID: Self.projectID, savedQueryID: Self.modifiedSavedQueryID
            )
        )
        #expect(modified.1.statusCode == 501)
    }

    /// Notebooks, which had no route at all — so the list was a failure state
    /// and the detail screen was the one place in the app that printed a
    /// `DecodingError` dump at the reader.
    @Test("each notebook serves its own body, and an unknown handle says so")
    func notebookRoutesSplitPerShortID() async throws {
        let page = try Page<Notebook>.decode(
            from: try await fixture(for: PostHogAPI.notebooks(projectID: Self.projectID))
        )
        #expect(page.results.count == 2)
        // The list serializer carries neither `content` nor `text_content`, and
        // that absence is why the detail request exists. A list fixture that
        // carried a body would let a regression dropping the fetch pass.
        #expect(page.results.allSatisfy { $0.document == nil && $0.textContent == nil })

        for row in page.results {
            let detail = try JSONDecoder().decode(
                Notebook.self,
                from: try await fixture(
                    for: PostHogAPI.notebook(projectID: Self.projectID, shortID: row.shortID)
                )
            )
            // `NotebookDetailView` re-titles itself from whatever comes back, so
            // one fixture serving both handles would rename the document the
            // reader opened as it loaded.
            #expect(detail.shortID == row.shortID)
            #expect(detail.title == row.title)
        }

        // The two read two different ways, and that is what two files buy.
        let rich = try JSONDecoder().decode(
            Notebook.self,
            from: try await fixture(
                for: PostHogAPI.notebook(projectID: Self.projectID, shortID: "synthetic-id-0050")
            )
        )
        #expect(rich.readingStrategy == .richContent)
        // Every renderer path plus two node types this build cannot draw, so
        // `NotebookUnsupportedBlock` and the footer that names them are both
        // reachable rather than theoretical.
        #expect(try #require(rich.document).unsupportedTypeNames.count == 2)
        // The embedded chart's handle has to be an insight the demo can answer,
        // or the block draws its "no such insight" state on a working notebook.
        #expect(
            try #require(rich.document).embeds.contains {
                $0.savedInsightShortID == "example-constellation-journey"
            }
        )

        let plain = try JSONDecoder().decode(
            Notebook.self,
            from: try await fixture(
                for: PostHogAPI.notebook(projectID: Self.projectID, shortID: "synthetic-id-0049")
            )
        )
        #expect(plain.readingStrategy == .plainTextFallback)

        // A third handle is a gap, and must answer as one. This is also the only
        // way the detail screen's own `LoadFailureState` stays reachable, and it
        // exists because this exact path used to fall through unrouted.
        let unknown = try await reply(
            for: PostHogAPI.notebook(projectID: Self.projectID, shortID: "nOsUcH99")
        )
        #expect(unknown.1.statusCode == 501)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Notebook.self, from: unknown.0)
        }
    }

    /// The embedded chart, and the reason the notebook needed a fourth route it
    /// did not obviously need.
    ///
    /// `PostHogAPI.insight(projectID:shortID:)` is a *collection* request
    /// filtered to one row, so it lands on the same path as the library's list
    /// and used to be answered with every fixture insight. Both callers read
    /// `results.first`, so a notebook drew one insight's chart under another
    /// insight's title and every insight deep link landed on the same insight.
    @Test("an insight asked for by handle is the insight that comes back")
    func insightByShortIDIsFiltered() async throws {
        let embedded = try Page<Insight>.decode(
            from: try await fixture(
                for: PostHogAPI.insight(projectID: Self.projectID, shortID: "example-meteor-report")
            )
        )
        let insight = try #require(embedded.results.first)
        #expect(insight.id == 710101)
        #expect(insight.shortID == "example-meteor-report")
        #expect(insight.title == "Example meteor report")
        // It also has to carry a computed `result`, or the notebook block draws
        // its "not computed yet" card instead of a chart — which is a real state
        // and the wrong one to make the demo's only embedded chart.
        #expect(insight.hasDrawableResult)

        // A handle the fixture does not hold is an **empty page, not a 404** —
        // which is what the documented API does, and what
        // `NotebookInsightStore` words as "That insight no longer exists".
        let missing = try await reply(
            for: PostHogAPI.insight(projectID: Self.projectID, shortID: "nOtHeRe1")
        )
        #expect(missing.1.statusCode == 200)
        #expect(try Page<Insight>.decode(from: missing.0).results.isEmpty)

        // The library's own paged list must be untouched: it asks without a
        // handle, and `InsightsStore` is deliberately written to survive this
        // fixture repeating its page.
        let library = try Page<Insight>.decode(
            from: try await fixture(for: PostHogAPI.insights(projectID: Self.projectID))
        )
        #expect(library.results.count == 4)
    }

    @Test("an insight kind filter returns only that kind")
    func insightKindIsFiltered() async throws {
        let funnels = try Page<Insight>.decode(
            from: try await fixture(
                for: PostHogAPI.insights(projectID: Self.projectID, kind: .funnels)
            )
        )

        #expect(funnels.count == 1)
        #expect(funnels.results.map(\.id) == [710104])
        #expect(funnels.results.allSatisfy { $0.sourceKind == InsightKind.funnels.sourceKind })

        let library = try Page<Insight>.decode(
            from: try await fixture(for: PostHogAPI.insights(projectID: Self.projectID))
        )
        #expect(library.count == 4)
        #expect(library.results.count == 4)
    }

    @Test("graph metadata is exact, fictional, and independent of earlier fixtures")
    func graphMetadataIsExact() async throws {
        let insightData = try await fixture(for: PostHogAPI.insights(projectID: Self.projectID))
        let insightObject = try #require(
            JSONSerialization.jsonObject(with: insightData) as? [String: Any]
        )
        let insights = try #require(insightObject["results"] as? [[String: Any]])
        let dashboardIDs = insights.compactMap { insight in
            ((insight["dashboard_tiles"] as? [[String: Any]])?.first?["id"] as? NSNumber)?.intValue
        }
        let creatorIDs = insights.compactMap { insight in
            ((insight["created_by"] as? [String: Any])?["id"] as? NSNumber)?.intValue
        }
        let modifierIDs = insights.compactMap { insight in
            ((insight["last_modified_by"] as? [String: Any])?["id"] as? NSNumber)?.intValue
        }
        let firstAction = try #require(
            (insights[0]["result"] as? [[String: Any]])?.first?["action"] as? [String: Any]
        )
        let secondAction = try #require(
            (insights[1]["result"] as? [[String: Any]])?.first?["action"] as? [String: Any]
        )
        let journeySeries = try #require(
            (insights[3]["result"] as? [[[String: Any]]])?.first
        )

        #expect(dashboardIDs == [721101, 721104])
        #expect(creatorIDs == Array(repeating: 721001, count: 4))
        #expect(modifierIDs == Array(repeating: 721002, count: 4))
        #expect((firstAction["id"] as? NSNumber)?.intValue == 721201)
        #expect(firstAction["name"] as? String == "Harbor chart launch")
        #expect((secondAction["id"] as? NSNumber)?.intValue == 721202)
        #expect(secondAction["name"] as? String == "Harbor ledger refresh")
        #expect(journeySeries.compactMap { $0["name"] as? String } == [
            "Harbor journey opened",
            "Harbor journey completed",
            "Harbor journey revisited",
            "Harbor journey paused",
        ])

        let alertData = try await fixture(
            for: PostHogAPI.alerts(projectID: Self.projectID, insightID: nil)
        )
        let alertObject = try #require(
            JSONSerialization.jsonObject(with: alertData) as? [String: Any]
        )
        let alerts = try #require(alertObject["results"] as? [[String: Any]])
        let alertCreatorIDs = alerts.compactMap { alert in
            ((alert["created_by"] as? [String: Any])?["id"] as? NSNumber)?.intValue
        }
        let subscriberIDs = alerts.flatMap { alert in
            (alert["subscribed_users"] as? [[String: Any]] ?? []).compactMap {
                ($0["id"] as? NSNumber)?.intValue
            }
        }

        #expect(alertCreatorIDs == [721011, 721012, 721012])
        #expect(subscriberIDs == [721021, 721022, 721024, 721023, 721025, 721023, 721025])
    }

    // MARK: - Alerts

    /// The alert list, and the server-side `insight_id` filter the app relies on.
    ///
    /// The filter is not a nicety: `limit` truncates *before* a client-side filter
    /// would run, so an insight whose alert sits past the first page would be
    /// reported as having none. A demo that ignored the parameter would show the
    /// funnel's alert on the trends insight's screen and nothing would fail.
    @Test("alerts are served and narrowed by insight the way the endpoint narrows them")
    func alertsResolveAndFilter() async throws {
        let all = try Page<InsightAlert>.decode(
            from: try await fixture(
                for: PostHogAPI.alerts(projectID: Self.projectID, insightID: nil)
            )
        )
        #expect(all.results.count == 3)

        // Both rows have to survive the decoder's optional-heavy path with the
        // fields the workflow actually reads.
        let firing = try #require(all.results.first { $0.state == .firing })
        #expect(firing.subscribedUsers.count == 3)
        #expect(firing.deliverySummary.contains("Alex Example"))
        let fixtureNow = try #require(Date("2026-01-15T12:00:00.000Z", strategy: .iso8601) as Date?)
        #expect(firing.isSnoozed(now: fixtureNow) == false)
        #expect(firing.id == "018f3300-0000-7000-8000-000000000801")
        #expect(firing.name == "Harbor trials below floor")
        #expect(firing.insightID == 710101)

        let snoozed = try #require(all.results.first { $0.state == .snoozed })
        #expect(snoozed.isSnoozed(now: fixtureNow))
        #expect(snoozed.enabled == false)

        let filtered = try Page<InsightAlert>.decode(
            from: try await fixture(
                for: PostHogAPI.alerts(projectID: Self.projectID, insightID: 710104)
            )
        )
        #expect(filtered.results.count == 2)
        #expect(filtered.results.first?.insightID == 710104)
        #expect(filtered.results.first?.insightName == "Example constellation journey")
        // `count` has to move with `results`, or a caller learns to distrust both.
        #expect(filtered.count == 2)

        // An insight with no alert is an empty page, not the whole list.
        let none = try Page<InsightAlert>.decode(
            from: try await fixture(
                for: PostHogAPI.alerts(projectID: Self.projectID, insightID: 1)
            )
        )
        #expect(none.results.isEmpty)
    }

    /// The create, which must answer as **one alert** rather than as the
    /// collection's page.
    ///
    /// The failure this catches is the one `createdAnnotation` documents: a create
    /// answered with a `Page` envelope fails to decode as one object, and
    /// `AlertWriteController` reports that as "PostHog answered, but not in a
    /// shape this app could read" — a demo saying that about its own fixture is
    /// worse than one with no route at all.
    @Test("creating an alert answers with the alert, in the response's own shapes")
    func createdAlertIsOneObject() async throws {
        let draft = AlertDraft(
            insightID: 710101,
            name: "Demo alert",
            subscribedUserIDs: [710_001],
            threshold: try #require(AlertThreshold(kind: .absolute, lower: 10, upper: nil)),
            condition: .absoluteValue,
            config: .trends(seriesIndex: 0),
            interval: .daily
        )
        let endpoint = try #require(
            PostHogAPI.createAlert(projectID: Self.projectID, draft: draft)
        )
        let (data, response) = try await reply(for: endpoint)
        #expect(response.statusCode == 201)

        let alert = try JSONDecoder().decode(InsightAlert.self, from: data)
        #expect(alert.name == "Demo alert")
        // The request sends `insight` as an id and `subscribed_users` as ids; the
        // response returns objects for both. A demo that echoed the request
        // exactly would decode as an alert watching nothing and telling nobody,
        // which is exactly the shape this asserts against.
        #expect(alert.insightID == 710101)
        #expect(alert.insightName == "Example meteor report")
        #expect(alert.subscribedUsers == ["Zadie Quell"])
        // Never evaluated, so nothing may claim it was.
        #expect(alert.lastValue == nil)
        #expect(alert.lastCheckedAt == nil)
        #expect(alert.snoozedUntil == nil)
    }

    /// Snoozing and unsnoozing, including the distinction the whole snooze path
    /// turns on: an unsnooze is the key **present and null**, not the key absent.
    @Test("a snooze moves the date and an unsnooze clears it")
    func alertSnoozeRoundTrip() async throws {
        let alertID = "018f3300-0000-7000-8000-000000000801"

        let snoozed = try JSONDecoder().decode(
            InsightAlert.self,
            from: try await fixture(
                for: try #require(
                    PostHogAPI.setAlertSnoozed(
                        projectID: Self.projectID, alertID: alertID, until: .fourHours
                    )
                )
            )
        )
        let until = try #require(snoozed.snoozedUntil)
        #expect(snoozed.isSnoozed(now: Date()))
        // Truncated to the start of the hour, which is what
        // `relative_date_parse(…, always_truncate: true)` does to an `h` unit — so
        // the end is at most four hours out and at least three.
        let hours = until.timeIntervalSinceNow / 3600
        #expect(hours > 2.9 && hours <= 4.01, "landed \(hours)h out")

        let woken = try JSONDecoder().decode(
            InsightAlert.self,
            from: try await fixture(
                for: try #require(
                    PostHogAPI.setAlertSnoozed(
                        projectID: Self.projectID, alertID: alertID, until: nil
                    )
                )
            )
        )
        #expect(woken.snoozedUntil == nil)
        #expect(woken.isSnoozed(now: Date()) == false)

        // And the row that comes back is the one that was asked for, not the
        // first in the file — the failure `surveyAfterWrite` documents.
        #expect(woken.id == alertID)
        #expect(woken.insightID == 710101)
    }

    @Test("pausing an alert answers with that alert, paused")
    func alertEnabledWrite() async throws {
        let alertID = "018f3300-0000-7000-8000-000000000801"
        let paused = try JSONDecoder().decode(
            InsightAlert.self,
            from: try await fixture(
                for: try #require(
                    PostHogAPI.setAlertEnabled(
                        projectID: Self.projectID, alertID: alertID, enabled: false
                    )
                )
            )
        )
        #expect(paused.id == alertID)
        #expect(paused.enabled == false)
    }

    // MARK: - The narrowing vocabulary

    /// One kind name, two queries, and only one of them has a fixture.
    ///
    /// `EventTaxonomyQuery` without `properties` is the discovery form and is
    /// modeled. Naming the properties takes a different server path and returns
    /// **positional** rows with no `property` key, and no fixture covers that
    /// for this project. Serving the discovery fixture would put row 0's values
    /// under whatever key was asked for; answering an empty 200 would make the
    /// filter picker state "PostHog returned no values for …" from a request that
    /// measured nothing. So it 501s, and this pins that it does.
    @Test("the named-properties taxonomy query 501s rather than borrowing the discovery fixture")
    func namedPropertyTaxonomyIsUnrecorded() async throws {
        let discovery = try Page<TaxonomyPropertySample>.decode(
            from: try await fixture(
                for: PostHogAPI.eventTaxonomy(projectID: Self.projectID, event: "$pageview")
            )
        )
        #expect(!discovery.results.isEmpty)

        let (data, response) = try await reply(
            for: PostHogAPI.eventTaxonomy(
                projectID: Self.projectID, event: "task_completed", properties: ["$browser"]
            )
        )
        #expect(response.statusCode == 501)
        // The sentence names the **kind**, not the path: `/query/` is routed
        // fifteen ways here, and naming it would send a reader hunting a routing
        // bug that is not there.
        let detail = try #require(
            (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
        )
        #expect(detail.contains("EventTaxonomyQuery"))
        #expect(!detail.contains("/query/"))
    }

    /// The filter and breakdown pickers read from `/property_definitions/`, which
    /// already has a fixture — asserted here through the builder the sheet actually
    /// calls, so a scope parameter change breaks this rather than passing by
    /// coincidence.
    @Test("property definitions answer for every scope the narrowing sheet offers")
    func propertyDefinitionsForNarrowing() async throws {
        for scope: PropertyScope in [.event, .person, .session] {
            let page = try Page<PropertyDefinitionSummary>.decode(
                from: try await fixture(
                    for: PostHogAPI.propertyDefinitions(projectID: Self.projectID, scope: scope)
                )
            )
            #expect(!page.results.isEmpty, "\(scope) produced no property names")
        }
    }
}
