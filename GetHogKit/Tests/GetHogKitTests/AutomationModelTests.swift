import Foundation
import Testing

@testable import GetHogKit

// The Tier-3 tail: notebooks, the operational automation resources, early access
// features, Max AI conversations and replay playlists.
//
// Every payload below is deterministic and fictional. The fixtures preserve the
// API's schema boundaries while using one coherent Example Company tenant.

// MARK: - Notebooks
//
// List and detail fixtures deliberately share an identity so navigation can be
// tested without relying on a live account.

@Suite("Notebooks")
struct NotebookTests {

    @Test("decodes the list page")
    func decodesList() throws {
        let page = try Page<Notebook>.decode(from: Fixture.data("notebooks.json"))
        #expect(page.results.count == 3)

        let first = try #require(page.results.first)
        #expect(first.id == "018f2000-0000-7000-8000-000000000001")
        #expect(first.shortID == "example-activation")
        #expect(first.title == "Example App activation notes")
        #expect(first.authorName == "Alex Example")
        #expect(first.lastModifiedAt != nil)
    }

    @Test("the list payload carries no note text at all")
    func listHasNoText() throws {
        // `GET /notebooks/` uses NotebookMinimalSerializer, whose field list has
        // neither `content` nor `text_content`. A row snippet is therefore not
        // available until the notebook itself is fetched, and the list must not
        // imply otherwise.
        let page = try Page<Notebook>.decode(from: Fixture.data("notebooks.json"))
        #expect(page.results.allSatisfy { $0.textContent == nil })
        #expect(page.results.allSatisfy { !$0.hasRichContent })
        #expect(page.results.allSatisfy { $0.snippet == nil })
    }

    @Test("names an untitled notebook rather than showing a blank row")
    func untitled() throws {
        let page = try Page<Notebook>.decode(from: Fixture.data("notebooks.json"))
        let second = try #require(page.results.first { $0.title == "Untitled notebook" })
        #expect(second.title == "Untitled notebook")
        #expect(second.authorName == nil)
        #expect(second.lastModifiedAt == nil)
    }

    @Test("decodes the detail payload with its plain text")
    func decodesDetail() throws {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_detail.json")
        )
        #expect(notebook.shortID == "example-activation")
        #expect(notebook.hasRichContent)
        #expect(notebook.textContent?.hasPrefix("Example App activation notes") == true)
        #expect(notebook.snippet == "Example App activation notes Trial starts increased after the fictional onboarding copy test.")
    }

    @Test("flags a notebook whose blocks have no text equivalent")
    func richContentWithoutText() throws {
        // A notebook made entirely of query and image blocks serialises with a
        // populated `content` tree and an empty `text_content`. Rendering nothing
        // would read as an empty notebook, so the two cases stay distinguishable.
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Data(#"""
            {"id":"n1","short_id":"s1","title":"Charts","content":{"type":"doc","content":[]},
             "text_content":"   "}
            """#.utf8)
        )
        #expect(notebook.hasRichContent)
        #expect(notebook.textContent == nil)
        #expect(notebook.isRichContentOnly)
    }
}

// MARK: - Workflows (hog flows)
//
// The fictional rows cover every workflow state and both trigger nullability
// branches.

@Suite("Workflows")
struct WorkflowTests {

    @Test("decodes name, status and trigger kind")
    func decodes() throws {
        let page = try Page<Workflow>.decode(from: Fixture.data("hog_flows.json"))
        #expect(page.results.count == 4)
        #expect(page.results.map(\.version) == [7, 8, 9, 10])

        let raw = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("hog_flows.json"))
                as? [String: Any]
        )
        let results = try #require(raw["results"] as? [[String: Any]])
        let trigger = try #require(results.first?["trigger"] as? [String: Any])
        let filters = try #require(trigger["filters"] as? [String: Any])
        #expect((filters["events"] as? [Any])?.count == 2)

        let first = try #require(page.results.first)
        #expect(first.name == "Example trial follow-up")
        #expect(first.status == .active)
        #expect(first.triggerKind == "event")
        #expect(first.description == "Sends a fictional follow-up after trial_started")
    }

    @Test("maps PostHog's three workflow states and nothing else")
    func states() throws {
        let page = try Page<Workflow>.decode(from: Fixture.data("hog_flows.json"))
        #expect(page.results.map(\.status) == [.active, .draft, .archived, .active])

        // The choice list has grown before; an unrecognised state must not read
        // as live.
        let odd = try JSONDecoder().decode(
            Workflow.self,
            from: Data(#"{"id":"x","name":"n","status":"paused"}"#.utf8)
        )
        #expect(odd.status == .unknown)
    }

    @Test("names an untitled workflow and tolerates a missing trigger")
    func untitled() throws {
        let page = try Page<Workflow>.decode(from: Fixture.data("hog_flows.json"))
        let draft = page.results[1]
        #expect(draft.name == "Untitled workflow")
        #expect(draft.triggerKind == nil)
        #expect(draft.description == nil)
    }
}

// MARK: - Query endpoints
//
// The two fictional endpoints distinguish materialized HogQL from a disabled
// trends endpoint that has never executed.

@Suite("Query endpoints")
struct QueryEndpointTests {

    @Test("decodes name, description and query kind")
    func decodes() throws {
        let page = try Page<QueryEndpoint>.decode(from: Fixture.data("query_endpoints.json"))
        let first = try #require(page.results.first)

        #expect(first.name == "example_weekly_activation")
        #expect(first.description == "Weekly fictional activation by browser")
        #expect(first.queryKind == "HogQLQuery")
        #expect(first.isActive)
        #expect(first.isMaterialized)
        #expect(first.lastExecutedAt != nil)
        #expect(first.columnCount == 2)
    }

    @Test("reports an endpoint that has never been executed as never, not zero")
    func neverExecuted() throws {
        let page = try Page<QueryEndpoint>.decode(from: Fixture.data("query_endpoints.json"))
        let second = page.results[1]
        #expect(second.lastExecutedAt == nil)
        #expect(!second.isActive)
        #expect(second.description == nil)
        #expect(second.queryKind == "TrendsQuery")
    }
}

// MARK: - Alerts
//
// Alert rows cross-link to the subscription fixture by insight id and short id.

@Suite("Insight alerts")
struct InsightAlertTests {

    @Test("decodes the alert and the insight it watches")
    func decodes() throws {
        // `insight` is a full InsightBasicSerializer object, not the id the field
        // name suggests — decoding it as an Int throws.
        let page = try Page<InsightAlert>.decode(from: Fixture.data("alerts.json"))
        let first = try #require(page.results.first)

        #expect(first.id == "018f3300-0000-7000-8000-000000000801")
        #expect(first.name == "Harbor trials below floor")
        #expect(first.insightName == "Example meteor report")
        #expect(first.insightID == 710101)
        #expect(first.enabled)
        #expect(first.lastValue == 18.75)
    }

    @Test("reads PostHog's human-worded alert states")
    func states() throws {
        // `state` is "Firing" / "Not firing" / "Errored" / "Snoozed" — spaced,
        // capitalised prose, not an enum slug.
        let page = try Page<InsightAlert>.decode(from: Fixture.data("alerts.json"))
        #expect(page.results.map(\.state) == [.firing, .notFiring, .notFiring])

        func state(_ raw: String) throws -> AlertState {
            try JSONDecoder().decode(
                InsightAlert.self,
                from: Data(#"{"id":"a","state":"\#(raw)"}"#.utf8)
            ).state
        }
        #expect(try state("Errored") == .errored)
        #expect(try state("Snoozed") == .snoozed)
        #expect(try state("Something new") == .unknown)
    }

    @Test("summarises the threshold in words")
    func threshold() throws {
        let page = try Page<InsightAlert>.decode(from: Fixture.data("alerts.json"))
        #expect(page.results.first?.thresholdSummary == "Below 25")
        #expect(page.results[1].thresholdSummary == "Above 7,220%")
    }

    @Test("falls back to the insight name when the alert is unnamed")
    func unnamed() throws {
        let page = try Page<InsightAlert>.decode(from: Fixture.data("alerts.json"))
        let second = page.results[1]
        // The insight has no `name`, only a `derived_name`.
        #expect(second.insightName == "Example constellation journey")
        #expect(second.displayTitle == "Example constellation journey")
        #expect(second.lastValue == nil)
    }

    @Test("every alert points to the exact saved insight in the fixture graph")
    func alertInsightCrossLinks() throws {
        let alerts = try Page<InsightAlert>.decode(from: Fixture.data("alerts.json"))
        let insights = try Page<Insight>.decode(from: Fixture.data("insights_list.json"))

        #expect(insights.results.map(\.id) == [710101, 710102, 710103, 710104])
        #expect(insights.results.map(\.shortID) == [
            "example-meteor-report",
            "example-nebula-export",
            "example-orbit-checkout",
            "example-constellation-journey",
        ])

        for alert in alerts.results {
            let insight = try #require(insights.results.first { $0.id == alert.insightID })
            #expect(alert.insightName == insight.title)
        }
    }
    @Test("fixture metadata is independently fictional, not merely the visible alert graph")
    func exactSyntheticMetadata() throws {
        let insightObject = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("insights_list.json")) as? [String: Any]
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

        #expect(dashboardIDs == [722101, 722104])
        #expect(creatorIDs == Array(repeating: 722001, count: 4))
        #expect(modifierIDs == Array(repeating: 722002, count: 4))

        let alertObject = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("alerts.json")) as? [String: Any]
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

        #expect(alertCreatorIDs == [722011])
        #expect(subscriberIDs == [722021, 722022])
    }
}

// MARK: - Subscriptions
//
// The fictional subscriptions exercise each delivery target and title fallback.

@Suite("Subscriptions")
struct SubscriptionTests {

    @Test("decodes destination, schedule and target resource")
    func decodes() throws {
        let page = try Page<InsightSubscription>.decode(from: Fixture.data("subscriptions.json"))
        #expect(page.results.count == 4)
        #expect(page.results.map(\.id) == [700401, 700402, 700403, 700404])

        let first = try #require(page.results.first)
        #expect(first.title == "Weekly example trials")
        #expect(first.target == .email)
        #expect(first.resourceName == "Example meteor report")
        #expect(first.scheduleSummary == "Authored example 6c9b3336")
        #expect(first.enabled)
        #expect(first.nextDeliveryDate != nil)
    }

    @Test("classifies each authored delivery target")
    func targets() throws {
        let page = try Page<InsightSubscription>.decode(from: Fixture.data("subscriptions.json"))
        #expect(page.results.map(\.target) == [.email, .slack, .webhook, .webhook])

        let odd = try JSONDecoder().decode(
            InsightSubscription.self,
            from: Data(#"{"id":1,"target_type":"teams"}"#.utf8)
        )
        #expect(odd.target == .unknown)
    }

    @Test("falls back to the frequency when the API sends no summary")
    func scheduleFallback() throws {
        // `summary` is a SerializerMethodField and has been null on older rows.
        // Showing nothing would leave the row without its most useful fact.
        let page = try Page<InsightSubscription>.decode(from: Fixture.data("subscriptions.json"))
        #expect(page.results[2].scheduleSummary == "sent monthly")
    }

    @Test("titles a row from the resource when the subscription is unnamed")
    func titleFallback() throws {
        let page = try Page<InsightSubscription>.decode(from: Fixture.data("subscriptions.json"))
        #expect(page.results[1].displayTitle == "Example growth dashboard")
        #expect(page.results[2].displayTitle == "Untitled subscription")
    }
}

// MARK: - Batch exports
//
// Export fixtures use reserved names and retain successful, failed and never-run
// health branches.

@Suite("Batch exports")
struct BatchExportTests {

    @Test("decodes destination, interval and pause state")
    func decodes() throws {
        let page = try Page<BatchExport>.decode(from: Fixture.data("batch_exports.json"))
        #expect(page.results.count == 3)
        let first = try #require(page.results.first)

        #expect(first.name == "Example events archive")
        #expect(first.destinationType == "S3")
        #expect(first.interval == "hour")
        #expect(!first.paused)
        #expect(first.model == "sessions")

        let raw = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("batch_exports.json"))
                as? [String: Any]
        )
        let results = try #require(raw["results"] as? [[String: Any]])
        #expect(results.compactMap { ($0["latest_runs"] as? [Any])?.count } == [3, 2, 0])
    }

    @Test("surfaces the newest run and its error")
    func latestRun() throws {
        let page = try Page<BatchExport>.decode(from: Fixture.data("batch_exports.json"))
        #expect(page.results.first?.lastRunHealth == .healthy)

        let failing = page.results[1]
        #expect(failing.paused)
        #expect(failing.lastRunHealth == .failed)
        #expect(failing.lastRunError == "Synthetic dataset example_app rejected the test write")
        #expect(failing.lastRunAt != nil)
    }

    @Test("says never run rather than inventing a status")
    func neverRun() throws {
        let export = try JSONDecoder().decode(
            BatchExport.self,
            from: Data(#"{"id":"b","name":"New","interval":"day","paused":false,"latest_runs":[]}"#.utf8)
        )
        #expect(export.lastRunHealth == .unknown)
        #expect(export.lastRunAt == nil)
        #expect(export.destinationType == nil)
    }
}

// MARK: - Early access features
//
// Feature rows cover an attached flag, a not-yet-attached flag and general
// availability using reserved documentation URLs.

@Suite("Early access features")
struct EarlyAccessFeatureTests {

    @Test("decodes the feature and the flag behind it")
    func decodes() throws {
        let page = try Page<EarlyAccessFeature>.decode(
            from: Fixture.data("early_access_features.json")
        )
        #expect(page.results.count == 4)

        let first = try #require(page.results.first)
        #expect(first.name == "Example navigation preview")
        #expect(first.stage == .beta)
        #expect(first.flagKey == "example-navigation")
        #expect(first.flagID == 710301)
        #expect(first.documentationURL?.absoluteString == "https://app.example.com/docs/example-navigation")
    }

    @Test("covers every stage PostHog defines, including draft")
    func stages() throws {
        // The model's Stage choices are draft, concept, alpha, beta,
        // general-availability and archived. `draft` is easy to miss and would
        // otherwise fall through to unknown when the API adds a newer feature.
        #expect(EarlyAccessStage(rawValue: "draft") == .draft)
        #expect(EarlyAccessStage(rawValue: "concept") == .concept)
        #expect(EarlyAccessStage(rawValue: "alpha") == .alpha)
        #expect(EarlyAccessStage(rawValue: "beta") == .beta)
        #expect(EarlyAccessStage(rawValue: "general-availability") == .generalAvailability)
        #expect(EarlyAccessStage(rawValue: "archived") == .archived)
        #expect(EarlyAccessStage(rawValue: "retired") == nil)

        let page = try Page<EarlyAccessFeature>.decode(
            from: Fixture.data("early_access_features.json")
        )
        #expect(page.results.map(\.stage) == [
            .beta, .concept, .generalAvailability, .generalAvailability,
        ])
    }

    @Test("tolerates a feature with no flag attached yet")
    func noFlag() throws {
        let page = try Page<EarlyAccessFeature>.decode(
            from: Fixture.data("early_access_features.json")
        )
        let concept = page.results[1]
        #expect(concept.flagKey == nil)
        #expect(concept.flagID == nil)
        #expect(concept.description == nil)
        #expect(concept.documentationURL == nil)
    }
}

// MARK: - Max AI conversations
//
// The list and detail fixtures share one fictional assistant thread. Their
// timestamps intentionally make the Slack thread newest.

@Suite("Max conversations")
struct MaxConversationTests {

    @Test("decodes the conversation list")
    func decodesList() throws {
        let page = try Page<MaxConversation>.decode(from: Fixture.data("max_conversations.json"))
        #expect(page.results.count == 4)

        let first = try #require(page.results.first)
        #expect(first.title == "Choosing observatory activation events")
        #expect(first.status == .idle)
        #expect(first.kind == .assistant)
        #expect(first.authorName?.isEmpty == false)
        #expect(first.createdAt != nil)
    }

    @Test("falls back to the email when a user has no name")
    func authorFallback() throws {
        let page = try Page<MaxConversation>.decode(from: Fixture.data("max_conversations.json"))
        #expect(page.results[2].authorName == "sample.analyst@example.com")
    }

    @Test("sorts newest first")
    func sorting() throws {
        let page = try Page<MaxConversation>.decode(from: Fixture.data("max_conversations.json"))
        let sorted = MaxConversation.newestFirst(page.results)
        #expect(sorted.map(\.title).first == "Reviewing telescope navigation feedback")
    }

    @Test("classifies the conversation kinds Max can produce")
    func kinds() throws {
        let page = try Page<MaxConversation>.decode(from: Fixture.data("max_conversations.json"))
        #expect(page.results.map(\.kind) == [.assistant, .deepResearch, .slack, .slack])

        let odd = try JSONDecoder().decode(
            MaxConversation.self,
            from: Data(#"{"id":"c","title":"t","type":"tool_call"}"#.utf8)
        )
        #expect(odd.kind == .other)
    }

    @Test("decodes a thread's messages from the retrieve payload")
    func decodesDetail() throws {
        // Only `GET /conversations/{id}/` carries `messages`; the list serializer
        // omits them entirely.
        let detail = try JSONDecoder().decode(
            MaxConversationThread.self,
            from: Fixture.data("max_conversation_detail.json")
        )
        #expect(detail.conversation.title == "Choosing observatory activation events")
        #expect(detail.messages.count == 6)
        #expect(detail.messages[0].role == .person)
        #expect(detail.messages[0].text == "Which fictional events should define observatory activation?")
        #expect(detail.messages[2].role == .assistant)
    }

    @Test("labels a message it cannot render as text instead of dropping it")
    func unrenderableMessage() throws {
        // Messages are pydantic dumps of a growing union; `ai/viz` carries an
        // `answer` query object and no prose. Silently skipping it would make the
        // thread look like it is missing a reply.
        let detail = try JSONDecoder().decode(
            MaxConversationThread.self,
            from: Fixture.data("max_conversation_detail.json")
        )
        let viz = detail.messages[3]
        #expect(viz.text == nil)
        #expect(viz.role == .visualization)
        #expect(detail.messages[1].role == .reasoning)
        #expect(detail.messages[4].role == .failure)
    }
}

// MARK: - Session recording playlists
//
// Pinned to the synthetic fixture for project 1001: thirteen playlists, seven of
// them synthetic rows PostHog injects into the page.

@Suite("Replay playlists")
struct SessionRecordingPlaylistTests {

    @Test("decodes the whole page including the synthetic rows")
    func decodesPage() throws {
        // Synthetic rows carry `created_at: null` and `created_by: null`. A
        // non-optional decode of either throws and takes the entire page with it.
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        #expect(page.count == 13)
        #expect(page.results.count == 13)
        #expect(page.results.filter(\.isSynthetic).count == 7)
        #expect(page.results.filter(\.isSynthetic).allSatisfy { $0.createdAt == nil })

        let authored = page.results.filter { !$0.isSynthetic }
        #expect(authored.compactMap(\.numericID) == [700541, 700553, 700567, 700579, 700593, 700607])
        #expect(authored.map(\.shortID) == [
            "example-long-orbit-sessions",
            "example-console-signal-sessions",
            "example-campaign-meteor-sessions",
            "example-rapid-click-sessions",
            "example-mobile-orbit-sessions",
            "example-cohort-lab-sessions",
        ])
        #expect(authored.allSatisfy { $0.createdAt == authored.first?.createdAt })
    }

    @Test("identifies a playlist by its short id, not its numeric id")
    func identity() throws {
        // Synthetic playlists use negative numeric ids assigned per synthetic
        // kind. `short_id` is the stable string the console itself routes on, so
        // it is what Identifiable keys off.
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        let ids = page.results.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("example-reviewed-orbits"))
        #expect(page.results.first?.numericID == -101)
    }

    @Test("reads counts from the bucket matching the playlist type")
    func counts() throws {
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        let watchHistory = try #require(page.results.first { $0.shortID == "example-reviewed-orbits" })
        #expect(watchHistory.kind == .collection)
        #expect(watchHistory.recordingCount == 4)
        #expect(watchHistory.watchedCount == 4)
        #expect(watchHistory.watchedProgress == 1)
    }

    @Test("treats an uncounted saved filter as unknown, not empty")
    func unknownCount() throws {
        // Saved-filter playlists report `count: null` until PostHog refreshes
        // them. Rendering "0 recordings" would claim an empty filter that in fact
        // matches plenty.
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        let saved = try #require(page.results.first { $0.shortID == "example-long-orbit-sessions" })
        #expect(saved.kind == .filters)
        #expect(saved.recordingCount == nil)
        #expect(saved.watchedProgress == nil)
        #expect(saved.countSummary == "Count not reported")
    }

    @Test("reports watch progress only when the total is known")
    func progress() throws {
        let page = try Page<SessionRecordingPlaylist>.decode(
            from: Fixture.data("session_recording_playlists.json")
        )
        let exported = try #require(page.results.first { $0.shortID == "example-exported-stars" })
        #expect(exported.recordingCount == 5)
        #expect(exported.watchedCount == 3)
        #expect(exported.watchedProgress == 3.0 / 5.0)
        #expect(exported.countSummary == "5 recordings · 3 watched")

        let commented = try #require(page.results.first { $0.shortID == "example-noted-comets" })
        #expect(commented.recordingCount == nil)
        #expect(commented.watchedProgress == nil)
    }
}

// MARK: - Endpoint catalog

@Suite("Automation endpoints")
struct AutomationAPITests {

    @Test("builds the list paths")
    func paths() {
        #expect(PostHogAPI.notebooks(projectID: 1_001).path == "/api/projects/1001/notebooks/")
        #expect(PostHogAPI.hogFlows(projectID: 1_001).path == "/api/projects/1001/hog_flows/")
        #expect(PostHogAPI.queryEndpoints(projectID: 1_001).path == "/api/projects/1001/endpoints/")
        #expect(PostHogAPI.alerts(projectID: 1_001).path == "/api/projects/1001/alerts/")
        #expect(PostHogAPI.subscriptions(projectID: 1_001).path == "/api/projects/1001/subscriptions/")
        #expect(PostHogAPI.batchExports(projectID: 1_001).path == "/api/projects/1001/batch_exports/")
        #expect(PostHogAPI.conversations(projectID: 1_001).path == "/api/projects/1001/conversations/")
        #expect(
            PostHogAPI.sessionRecordingPlaylists(projectID: 1_001).path
                == "/api/projects/1001/session_recording_playlists/"
        )
    }

    @Test("uses the singular early access path PostHog actually serves")
    func earlyAccessPathIsSingular() {
        // `/early_access_feature/` — no trailing "s". The plural 404s.
        #expect(
            PostHogAPI.earlyAccessFeatures(projectID: 1_001).path
                == "/api/projects/1001/early_access_feature/"
        )
    }

    @Test("looks a notebook up by short id, not by uuid")
    func notebookLookup() {
        // The viewset sets `lookup_field = "short_id"`.
        #expect(
            PostHogAPI.notebook(projectID: 1_001, shortID: "aBcD1234").path
                == "/api/projects/1001/notebooks/aBcD1234/"
        )
    }

    @Test("fetches one conversation for its messages")
    func conversationDetail() {
        #expect(
            PostHogAPI.conversation(projectID: 1_001, conversationID: "c1").path
                == "/api/projects/1001/conversations/c1/"
        )
    }

    @Test("bills every one of these against the CRUD budget")
    func categories() {
        // None of these run a query; charging them to the analytics or query
        // budget would starve the screens that actually compute something.
        let all = [
            PostHogAPI.notebooks(projectID: 1_001),
            PostHogAPI.hogFlows(projectID: 1_001),
            PostHogAPI.queryEndpoints(projectID: 1_001),
            PostHogAPI.alerts(projectID: 1_001),
            PostHogAPI.subscriptions(projectID: 1_001),
            PostHogAPI.batchExports(projectID: 1_001),
            PostHogAPI.earlyAccessFeatures(projectID: 1_001),
            PostHogAPI.conversations(projectID: 1_001),
            PostHogAPI.sessionRecordingPlaylists(projectID: 1_001),
        ]
        #expect(all.allSatisfy { $0.category == .crud })
        #expect(all.allSatisfy { $0.method == "GET" })
    }
}
