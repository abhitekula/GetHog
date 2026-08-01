import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// The alert workflow, on this side of the wire.
///
/// The scripted transport pins everything the app controls: the request it
/// builds, the state it shows while the request is out, and what it does when
/// the answer comes back.
private actor ScriptedTransport: HTTPTransport {
    private var responses: [(Int, String)]
    private(set) var requests: [(method: String, url: String, body: String)] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(
            (
                method: request.httpMethod ?? "",
                // `absoluteString`, not `url.path`: the legacy accessor strips the
                // trailing slash every PostHog path ends in, and Django cares.
                url: request.url?.absoluteString ?? "",
                body: request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            )
        )
        let (status, body) = responses.count == 1 ? responses[0] : responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private struct StaticAuth: AuthProvider {
    let region = PostHogRegion.usCloud
    func authorizationHeader() async throws -> String { "Bearer test" }
    func handleUnauthorized() async throws {}
}

private let firingAlert = """
    {"id": "harbor-alert-a", "name": "Harbor trials fell", "state": "Firing", "enabled": true,
     "calculation_interval": "daily", "last_value": 12,
     "snoozed_until": null,
     "insight": {"id": 710101, "short_id": "example-meteor-report", "name": "Example meteor report"},
     "subscribed_users": [{"first_name": "Ada", "last_name": "Lovelace", "email": "alert.subscriber@example.org"}],
     "threshold": {"configuration": {"type": "absolute", "bounds": {"lower": 100}}}}
    """

private func alert(_ json: String = firingAlert) throws -> InsightAlert {
    try JSONDecoder().decode(InsightAlert.self, from: Data(json.utf8))
}

@MainActor
@Suite("Alert writes, app side")
struct AlertWriteControllerTests {

    private func client(_ responses: [(Int, String)]) -> (PostHogClient, ScriptedTransport) {
        let transport = ScriptedTransport(responses)
        return (PostHogClient(auth: StaticAuth(), transport: transport), transport)
    }

    // MARK: - Snooze

    @Test("a snooze sends one PATCH carrying only the relative duration")
    func snoozeSendsOnePatch() async throws {
        let (client, transport) = client([(200, firingAlert)])
        let controller = AlertWriteController()
        let subject = try alert()

        #expect(controller.isSnoozed(subject) == false)
        await controller.setSnoozed(.fourHours, alert: subject, client: client, projectID: 1_001)

        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].url.hasSuffix("/api/projects/1001/alerts/harbor-alert-a/"))
        #expect(requests[0].body.contains("\"snoozed_until\":\"4h\""))
        // The optimistic state is applied, so the row offers "Wake it up" without
        // waiting for a refetch.
        #expect(controller.isSnoozed(subject))
        #expect(controller.successCount == 1)
        #expect(controller.message == nil)
    }

    /// Rollback, which is the half of the optimistic pattern that is easy to
    /// leave out and impossible to notice until a write fails in production.
    @Test("a refused snooze rolls the state back and says which permission")
    func refusedSnoozeRollsBack() async throws {
        let body = #"{"type":"authentication_error","code":"permission_denied","detail":"You are missing the alert:write scope."}"#
        let (client, _) = client([(403, body)])
        let controller = AlertWriteController()
        let subject = try alert()

        await controller.setSnoozed(.oneHour, alert: subject, client: client, projectID: 1)

        #expect(controller.isSnoozed(subject) == false, "the alert is not snoozed, so nothing may say it is")
        #expect(controller.failureCount == 1)
        let message = try #require(controller.message)
        #expect(message.kind == .failure)
        // PostHog named the scope, so the message is entitled to name it too —
        // `WriteFailure` is where that reasoning lives and this asserts the
        // controller reaches it rather than inventing a sentence.
        #expect(message.text.contains("alert:write"))
        #expect(message.text.contains("snooze"))
    }

    /// The one request in this family whose obvious spelling is a silent no-op.
    @Test("an unsnooze sends an explicit null, not an absent key")
    func unsnoozeSendsNull() async throws {
        let (client, transport) = client([(200, firingAlert)])
        let controller = AlertWriteController()
        let subject = try alert()

        await controller.setSnoozed(nil, alert: subject, client: client, projectID: 1)

        let body = try #require(await transport.requests.first?.body)
        #expect(body.contains("\"snoozed_until\":null"))
        #expect(controller.isSnoozed(subject) == false)
    }

    /// A `Date??`, and the reason it has to be one: after an unsnooze the
    /// override says "we know this is not snoozed", which is a different state
    /// from "we never touched it" — and only the second may fall back to the
    /// server's stale end time.
    @Test("an unsnooze overrides a server-reported snooze rather than deferring to it")
    func unsnoozeBeatsTheServersStaleDate() async throws {
        let snoozedJSON = """
            {"id": "harbor-alert-a", "state": "Snoozed", "enabled": true,
             "snoozed_until": "2099-01-01T00:00:00Z"}
            """
        let subject = try alert(snoozedJSON)
        let controller = AlertWriteController()
        #expect(controller.isSnoozed(subject))

        let (client, _) = client([(200, snoozedJSON)])
        await controller.setSnoozed(nil, alert: subject, client: client, projectID: 1)

        #expect(controller.effectiveSnoozedUntil(subject) == nil)
        #expect(controller.isSnoozed(subject) == false)
    }

    // MARK: - Enable

    @Test("pausing sends only `enabled` and rolls back when refused")
    func enableRollsBack() async throws {
        let subject = try alert()

        let (ok, okTransport) = client([(200, firingAlert)])
        let controller = AlertWriteController()
        await controller.setEnabled(false, alert: subject, client: ok, projectID: 1)
        let body = try #require(await okTransport.requests.first?.body)
        #expect(body.contains("\"enabled\":false"))
        #expect(!body.contains("threshold"))
        #expect(controller.effectiveEnabled(subject) == false)

        let (bad, _) = client([(500, #"{"detail":"boom"}"#)])
        let failing = AlertWriteController()
        await failing.setEnabled(false, alert: subject, client: bad, projectID: 1)
        #expect(failing.effectiveEnabled(subject) == true, "the alert is still running")
        #expect(failing.failureCount == 1)
    }

    // MARK: - Create

    @Test("a created alert is adopted from the response, not from the request")
    func createAdoptsTheResponse() async throws {
        let (client, transport) = client([(201, firingAlert)])
        let controller = AlertWriteController()
        let draft = AlertDraft(
            insightID: 710101,
            name: "Harbor trials fell",
            subscribedUserIDs: [710_001],
            threshold: try #require(AlertThreshold(kind: .absolute, lower: 100, upper: nil)),
            condition: .absoluteValue,
            config: .trends(seriesIndex: 0),
            interval: .daily
        )

        let saved = await controller.create(
            draft, insightTitle: "Example meteor report", client: client, projectID: 1_001
        )
        #expect(saved)
        #expect(controller.created.count == 1)
        // The id, the subscriber names and the state are PostHog's, not this
        // app's guesses at them.
        #expect(controller.created.first?.id == "harbor-alert-a")
        #expect(controller.created.first?.subscribedUsers == ["Ada Lovelace"])

        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.hasSuffix("/api/projects/1001/alerts/"))
    }

    /// The one failure where "it wasn't saved" is the wrong thing to say.
    @Test("an unreadable create response does not claim the alert was not set")
    func unreadableCreateIsHedged() async throws {
        let (client, _) = client([(201, "{\"nope\":true}")])
        let controller = AlertWriteController()
        let draft = AlertDraft(
            insightID: 710101,
            name: "Harbor trials fell",
            subscribedUserIDs: [1],
            threshold: try #require(AlertThreshold(kind: .absolute, lower: 100, upper: nil)),
            condition: .absoluteValue,
            config: .trends(seriesIndex: 0),
            interval: .daily
        )

        let saved = await controller.create(
            draft, insightTitle: "Example meteor report", client: client, projectID: 1
        )
        #expect(!saved)
        #expect(controller.created.isEmpty)
        let text = try #require(controller.message?.text)
        #expect(text.contains("may have been set"))
        #expect(!text.contains("Couldn't"))
    }

    /// A draft the serializer would refuse never becomes a request.
    @Test("an unsendable draft spends nothing and says why")
    func unsendableDraftSpendsNothing() async throws {
        let (client, transport) = client([(201, firingAlert)])
        let controller = AlertWriteController()
        let draft = AlertDraft(
            insightID: 710101,
            name: "Harbor trials fell",
            subscribedUserIDs: [],
            threshold: try #require(AlertThreshold(kind: .absolute, lower: 100, upper: nil)),
            condition: .absoluteValue,
            config: .trends(seriesIndex: 0),
            interval: .daily
        )

        let saved = await controller.create(
            draft, insightTitle: "Example meteor report", client: client, projectID: 1
        )
        #expect(!saved)
        #expect(await transport.requests.isEmpty, "no request may be spent on a certain refusal")
        #expect(controller.message?.text.contains("at least one person to tell") == true)
    }

    // MARK: - Reconciliation

    /// Whoever changed the alert in the web console wins. A stale override that
    /// outlived its write would quietly misreport whether somebody is being
    /// e-mailed.
    @Test("a fresh fetch retires this session's overrides")
    func reconcileDropsSettledOverrides() async throws {
        let (client, _) = client([(200, firingAlert)])
        let controller = AlertWriteController()
        let subject = try alert()

        await controller.setEnabled(false, alert: subject, client: client, projectID: 1)
        #expect(controller.effectiveEnabled(subject) == false)

        controller.reconcile(with: [subject])
        #expect(controller.effectiveEnabled(subject) == true, "the server's answer wins")
    }

    @Test("an alert the server now lists is not also drawn as this session's creation")
    func reconcileDropsListedCreations() async throws {
        let (client, _) = client([(201, firingAlert)])
        let controller = AlertWriteController()
        let draft = AlertDraft(
            insightID: 42,
            name: "Harbor trials fell",
            subscribedUserIDs: [1],
            threshold: try #require(AlertThreshold(kind: .absolute, lower: 100, upper: nil)),
            condition: .absoluteValue,
            config: .trends(seriesIndex: 0),
            interval: .daily
        )
        await controller.create(draft, insightTitle: "x", client: client, projectID: 1)
        #expect(controller.created.count == 1)

        controller.reconcile(with: [try alert()])
        #expect(controller.created.isEmpty, "listing it twice is worse than listing it late")
    }
}

// MARK: - Narrowing

@MainActor
@Suite("Insight narrowing, app side")
struct InsightNarrowingScreenTests {

    private func client(_ responses: [(Int, String)]) -> (PostHogClient, ScriptedTransport) {
        let transport = ScriptedTransport(responses)
        return (PostHogClient(auth: StaticAuth(), transport: transport), transport)
    }

    private func trendsInsight() throws -> Insight {
        let json = """
            {"id": 710101, "short_id": "example-meteor-report", "name": "Example meteor report",
             "query": {"kind": "InsightVizNode",
                       "source": {"kind": "TrendsQuery",
                                  "series": [{"kind": "EventsNode", "event": "trial_started"}],
                                  "dateRange": {"date_from": "-21d"},
                                  "properties": []}},
             "result": null}
            """
        return try JSONDecoder().decode(Insight.self, from: Data(json.utf8))
    }

    private let trendsResult = """
        {"results": {"results": [{"label": "trial_started", "days": ["2026-01-17"], "data": [7]}]}}
        """

    private func store(_ insight: Insight) -> SavedInsightStore {
        let store = SavedInsightStore()
        store.seed(insight)
        return store
    }

    /// Asking for nothing spends nothing. The sheet's Apply is reachable with an
    /// empty draft — clearing every filter is a real change — so the store, not
    /// the button, is what decides whether a request happens.
    @Test("a narrowing that asks for nothing makes no request")
    func emptyNarrowingIsFree() async throws {
        let (client, transport) = client([(200, trendsResult)])
        let subject = store(try trendsInsight())

        await subject.applyNarrowing(
            dateFrom: nil, compare: false, filters: [], breakdown: .saved,
            client: client, projectID: 1
        )

        #expect(await transport.requests.isEmpty)
        #expect(subject.narrowed == nil)
        #expect(subject.narrowError == nil)
    }

    /// The whole feature in one assertion: one request, carrying the filter as a
    /// bare array and keeping the insight's own saved window.
    @Test("applying a filter runs the insight once, keeping its saved date range")
    func applyingAFilterRunsOnce() async throws {
        let (client, transport) = client([(200, trendsResult)])
        let subject = store(try trendsInsight())

        await subject.applyNarrowing(
            dateFrom: nil,
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .property(InsightBreakdown(scope: .event, property: "$os")),
            client: client, projectID: 1_001
        )

        let requests = await transport.requests
        #expect(requests.count == 1, "one query per Apply, never one per picker change")
        #expect(requests[0].url.hasSuffix("/api/projects/1001/query/"))

        let body = try #require(
            try JSONSerialization.jsonObject(with: Data(requests[0].body.utf8)) as? [String: Any]
        )
        let query = try #require(body["query"] as? [String: Any])
        // Bare array — the saved insight shape, and *not* the nested
        // `PropertyGroupFilter` that `TraceSpansQuery.filterGroup`
        // requires. Two differently-typed fields; this is the one that would 400
        // if they were confused.
        let properties = try #require(query["properties"] as? [[String: Any]])
        #expect(properties.count == 1)
        #expect(properties[0]["key"] as? String == "$browser")

        // The saved window survives. Defaulting to 30 days here would silently
        // move a 21-day insight and report the move as the filter's effect.
        let dateRange = try #require(query["dateRange"] as? [String: Any])
        #expect(dateRange["date_from"] as? String == "-21d")

        #expect(subject.narrowed != nil)
        #expect(subject.narrowError == nil)
    }

    /// The lie this feature exists to avoid: a chart still drawing the saved,
    /// unfiltered numbers while a caption says "Chrome". A refused request must
    /// clear the override *and* name itself.
    @Test("a refused narrowing clears the override and states the refusal")
    func refusedNarrowingIsNamed() async throws {
        let (client, _) = client([(400, #"{"type":"validation_error","detail":"Bad filter"}"#)])
        let subject = store(try trendsInsight())

        await subject.applyNarrowing(
            dateFrom: nil,
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .saved,
            client: client, projectID: 1
        )

        #expect(subject.narrowed == nil)
        #expect(subject.narrowError?.contains("Bad filter") == true)
    }

    /// The second path to the same lie, and the one no status code marks: a
    /// request that *succeeded* and produced nothing this build can draw.
    @Test("a successful response that decodes to nothing is not treated as success")
    func undrawableResponseIsNamed() async throws {
        let (client, _) = client([(200, "{\"unexpected\": true}")])
        let subject = store(try trendsInsight())

        await subject.applyNarrowing(
            dateFrom: nil,
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .saved,
            client: client, projectID: 1
        )

        #expect(subject.narrowed == nil)
        let error = try #require(subject.narrowError)
        #expect(error.contains("still the saved result"))
    }

    /// The third path: an insight whose saved query cannot be re-run at all. It
    /// must not spend a request, and it must not go quiet.
    @Test("an insight with no runnable source says so without spending a request")
    func unrunnableInsightIsNamed() async throws {
        let (client, transport) = client([(200, trendsResult)])
        let json = #"{"id": 43, "name": "Odd one", "query": null, "result": null}"#
        let subject = store(try JSONDecoder().decode(Insight.self, from: Data(json.utf8)))

        await subject.applyNarrowing(
            dateFrom: nil,
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .saved,
            client: client, projectID: 1
        )

        #expect(await transport.requests.isEmpty)
        #expect(subject.narrowed == nil)
        #expect(subject.narrowError?.contains("re-run") == true)
    }

    /// A failed narrowing must not leave the *previous* narrowing's rows on
    /// screen either — those answer a question nobody asked any more.
    @Test("a failed narrowing clears rows from the previous one")
    func failureClearsThePreviousOverride() async throws {
        let (client, _) = client([
            (200, trendsResult),
            (500, #"{"detail":"boom"}"#),
        ])
        let subject = store(try trendsInsight())
        let chrome = InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")
        let safari = InsightPropertyFilter(scope: .event, key: "$browser", value: "Safari")

        await subject.applyNarrowing(
            dateFrom: nil, compare: false, filters: [chrome], breakdown: .saved,
            client: client, projectID: 1
        )
        #expect(subject.narrowed != nil)

        await subject.applyNarrowing(
            dateFrom: nil, compare: false, filters: [safari], breakdown: .saved,
            client: client, projectID: 1
        )
        #expect(subject.narrowed == nil, "Chrome's rows must not stand in for Safari's")
        #expect(subject.narrowError != nil)
    }

    @Test("clearing the narrowing drops the override without a request")
    func clearingIsFree() async throws {
        let (client, transport) = client([(200, trendsResult)])
        let subject = store(try trendsInsight())

        await subject.applyNarrowing(
            dateFrom: nil,
            compare: false,
            filters: [InsightPropertyFilter(scope: .event, key: "$browser", value: "Chrome")],
            breakdown: .saved,
            client: client, projectID: 1
        )
        #expect(subject.narrowed != nil)

        subject.clearNarrowing()
        #expect(subject.narrowed == nil)
        #expect(subject.narrowError == nil)
        #expect(await transport.requests.count == 1, "clearing is a local drop, not a re-run")
    }
}
