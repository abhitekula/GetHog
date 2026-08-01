import Foundation
import Testing

@testable import GetHogKit

private extension Data {
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: self) as? [String: Any]) ?? [:]
    }
}

/// Setting and snoozing PostHog's own alerts.
///
/// The suite asserts deterministic request values without contacting a remote
/// project.
@Suite("Alert writes")
struct AlertWriteEndpointTests {

    private func draft(
        subscribers: [Int] = [710_001],
        name: String = "Harbor trials fell",
        threshold: AlertThreshold? = AlertThreshold(kind: .absolute, lower: 100, upper: nil),
        config: AlertConfig = .trends(seriesIndex: 0)
    ) -> AlertDraft {
        AlertDraft(
            insightID: 710_101,
            name: name,
            subscribedUserIDs: subscribers,
            threshold: threshold ?? AlertThreshold(kind: .absolute, lower: 1, upper: nil)!,
            condition: .absoluteValue,
            config: config,
            interval: .daily
        )
    }

    // MARK: - Listing

    @Test("narrows the alert list to one insight server-side")
    func listFilter() {
        let all = PostHogAPI.alerts(projectID: 1_001, insightID: nil)
        #expect(all.path == "/api/projects/1001/alerts/")
        #expect(all.query.first { $0.name == "insight_id" } == nil)

        let one = PostHogAPI.alerts(projectID: 1_001, insightID: 710_101)
        #expect(one.query.first { $0.name == "insight_id" }?.value == "710101")
        // Cheap listing, not a computation: it must not spend the query budget
        // the screens that actually compute depend on.
        #expect(one.category == .crud)
        #expect(one.method == "GET")
    }

    /// The pre-existing `alerts(projectID:limit:)` is what `AutomationRoot`
    /// calls; adding the filtered form must not have changed it.
    @Test("the unfiltered builder is unchanged")
    func existingBuilderIsIntact() {
        let endpoint = PostHogAPI.alerts(projectID: 1)
        #expect(endpoint.path == "/api/projects/1/alerts/")
        #expect(endpoint.category == .crud)
    }

    // MARK: - Create

    @Test("builds a create carrying every field the serializer requires")
    func createBody() throws {
        let endpoint = try #require(PostHogAPI.createAlert(projectID: 1_001, draft: draft()))
        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1001/alerts/")
        #expect(endpoint.category == .crud)

        let body = try #require(endpoint.body).json
        // `insight`, `subscribed_users` and `threshold` are the serializer's
        // three `required` fields.
        #expect(body["insight"] as? Int == 710_101)
        #expect(body["subscribed_users"] as? [Int] == [710_001])
        #expect(body["name"] as? String == "Harbor trials fell")
        #expect(body["calculation_interval"] as? String == "daily")
        #expect(body["enabled"] as? Bool == true)

        let threshold = try #require(body["threshold"] as? [String: Any])
        let configuration = try #require(threshold["configuration"] as? [String: Any])
        #expect(configuration["type"] as? String == "absolute")
        let bounds = try #require(configuration["bounds"] as? [String: Any])
        #expect(bounds["lower"] as? Double == 100)
        // Absent rather than null: the field is `lower/upper floats` and only one
        // of the two was asked for.
        #expect(bounds["upper"] == nil)

        let condition = try #require(body["condition"] as? [String: Any])
        #expect(condition["type"] as? String == "absolute_value")
    }

    @Test("the per-kind config is discriminated by type")
    func configArms() throws {
        let trends = try #require(
            PostHogAPI.createAlert(projectID: 1, draft: draft())?.body
        ).json["config"] as? [String: Any]
        #expect(trends?["type"] as? String == "TrendsAlertConfig")
        #expect(trends?["series_index"] as? Int == 0)

        let funnel = try #require(
            PostHogAPI.createAlert(
                projectID: 1,
                draft: draft(config: .funnel(metric: .fromStart, step: nil))
            )?.body
        ).json["config"] as? [String: Any]
        #expect(funnel?["type"] as? String == "FunnelsAlertConfig")
        #expect(funnel?["metric"] as? String == "conversion_from_start")
        // Explicit null, which the serializer documents as *the overall last
        // step*. Omitting the key leaves that choice to a default.
        #expect(funnel?["funnel_step"] is NSNull)

        let stepped = try #require(
            PostHogAPI.createAlert(
                projectID: 1,
                draft: draft(config: .funnel(metric: .fromPrevious, step: 2))
            )?.body
        ).json["config"] as? [String: Any]
        #expect(stepped?["funnel_step"] as? Int == 2)
    }

    /// Refusals, each one a request not spent on a certain rejection.
    @Test("declines to build a request the serializer would refuse")
    func refusesInvalidDrafts() {
        #expect(PostHogAPI.createAlert(projectID: 1, draft: draft(subscribers: [])) == nil)
        #expect(PostHogAPI.createAlert(projectID: 1, draft: draft(name: "   ")) == nil)
        // `name` is `max_length=255` server-side.
        #expect(
            PostHogAPI.createAlert(
                projectID: 1, draft: draft(name: String(repeating: "a", count: 256))
            ) == nil
        )
    }

    @Test("a threshold with neither bound cannot be built at all")
    func thresholdRequiresABound() {
        #expect(AlertThreshold(kind: .absolute, lower: nil, upper: nil) == nil)
        #expect(AlertThreshold(kind: .absolute, lower: .nan, upper: nil) == nil)
        #expect(AlertThreshold(kind: .absolute, lower: nil, upper: .infinity) == nil)
        #expect(AlertThreshold(kind: .percentage, lower: nil, upper: 0.2) != nil)
    }

    // MARK: - Snooze

    /// The one that has to be right, because getting it wrong answers **200 and
    /// changes nothing**: an unsnooze must send an explicit JSON null. The
    /// serializer distinguishes "key absent" from "key null" with a
    /// `serializers.empty` sentinel and only the second calls `apply_unsnooze`.
    @Test("unsnoozing sends an explicit null, never an absent key")
    func unsnoozeSendsNull() throws {
        let endpoint = try #require(
            PostHogAPI.setAlertSnoozed(projectID: 1_001, alertID: "harbor-alert-a", until: nil)
        )
        #expect(endpoint.method == "PATCH")
        #expect(endpoint.path == "/api/projects/1001/alerts/harbor-alert-a/")
        #expect(endpoint.category == .crud)

        let body = try #require(endpoint.body)
        #expect(body.json.keys.contains("snoozed_until"))
        #expect(body.json["snoozed_until"] is NSNull)
        // Belt and braces: the encoded bytes really do carry `null`.
        #expect(String(decoding: body, as: UTF8.self).contains("null"))
    }

    @Test("snoozing sends the relative duration string, not a datetime")
    func snoozeSendsRelativeString() throws {
        for snooze in AlertSnooze.allCases {
            let endpoint = try #require(
                PostHogAPI.setAlertSnoozed(projectID: 1, alertID: "abc", until: snooze)
            )
            let body = try #require(endpoint.body).json
            #expect(body["snoozed_until"] as? String == snooze.rawValue)
            // Nothing else may ride along: a PATCH that also carried `threshold`
            // would run `apply_threshold_change` and reset `next_check_at`.
            #expect(body.count == 1)
        }
    }

    /// `always_truncate` is why the day case is not called "24 hours". The titles
    /// are the user-facing consequence of a server-side parse, so they are pinned
    /// beside the strings that cause them.
    @Test("snooze titles name where the snooze lands, not how long it looks")
    func snoozeTitlesAreHonestAboutTruncation() {
        #expect(AlertSnooze.tomorrow.rawValue == "1d")
        #expect(AlertSnooze.tomorrow.title == "Until tomorrow")
        #expect(AlertSnooze.tomorrow.explanation.contains("not for a flat 24 hours"))
        #expect(AlertSnooze.fourHours.title.contains("About"))
    }

    // MARK: - Enable

    @Test("enabling and disabling is its own call, carrying only `enabled`")
    func enabledBody() throws {
        for enabled in [true, false] {
            let endpoint = try #require(
                PostHogAPI.setAlertEnabled(projectID: 1, alertID: "abc", enabled: enabled)
            )
            #expect(endpoint.method == "PATCH")
            #expect(endpoint.path == "/api/projects/1/alerts/abc/")
            let body = try #require(endpoint.body).json
            #expect(body["enabled"] as? Bool == enabled)
            #expect(body.count == 1)
        }
    }

    // MARK: - Composability

    @Test("only the kinds this app can build a config for are composable")
    func composableKinds() {
        #expect(AlertableInsight.isComposable(sourceKind: "TrendsQuery"))
        #expect(AlertableInsight.isComposable(sourceKind: "FunnelsQuery"))
        // Alertable by PostHog, not composable from a phone — and the difference
        // is stated rather than shown as a dead button.
        #expect(AlertableInsight.isAlertable(sourceKind: "HogQLQuery"))
        #expect(!AlertableInsight.isComposable(sourceKind: "HogQLQuery"))
        #expect(AlertableInsight.unavailableReason(sourceKind: "HogQLQuery")?.isEmpty == false)
        #expect(AlertableInsight.unavailableReason(sourceKind: "TrendsQuery") == nil)

        #expect(!AlertableInsight.isAlertable(sourceKind: "LifecycleQuery"))
        #expect(
            AlertableInsight.unavailableReason(sourceKind: "LifecycleQuery")?
                .contains("LifecycleQuery") == true
        )
    }

    /// The cadence list deliberately omits the two plan-gated choices. A create
    /// that fails because the organisation is not on Scale is a failure this app
    /// could not explain, because it cannot read the plan.
    @Test("no plan-gated cadence is offered")
    func cadencesAreUnrestricted() {
        let offered = Set(AlertCalculationInterval.allCases.map(\.rawValue))
        #expect(offered == ["hourly", "daily", "weekly", "monthly"])
        #expect(!offered.contains("real_time"))
        #expect(!offered.contains("every_15_minutes"))
    }

    // MARK: - Confirmation

    /// Every mutating call in this app names the object and the direction before
    /// it happens. This is that sentence for a create.
    @Test("the confirmation names the insight, the cadence and where it goes")
    func confirmationNamesTheObject() {
        let text = draft().confirmation(insightTitle: "Weekly signups")
        #expect(text.contains("Weekly signups"))
        #expect(text.contains("daily"))
        #expect(text.contains("Below 100".lowercased()))
        // The correction this whole feature turns on: nothing arrives here.
        #expect(text.contains("Nothing is sent to this phone"))
    }

    @Test("the composer's preview and a decoded row describe a threshold alike")
    func thresholdSummaryMatchesTheDecodedForm() throws {
        // `InsightAlert.summarise` is private and only reachable through a
        // decode, which is the point: the two implementations must agree.
        let json = """
        {"id":"a","state":"Firing","enabled":true,
         "threshold":{"configuration":{"type":"percentage","bounds":{"upper":0.2}}}}
        """
        let alert = try JSONDecoder().decode(InsightAlert.self, from: Data(json.utf8))
        let draftSummary = AlertThreshold(kind: .percentage, lower: nil, upper: 0.2)?.summary
        #expect(alert.thresholdSummary == draftSummary)
        #expect(draftSummary == "Above 20%")
    }
}

/// Decoding the fields the alert workflow added.
@Suite("Alert row decoding")
struct AlertRowDecodingTests {

    private func alert(_ json: String) throws -> InsightAlert {
        try JSONDecoder().decode(InsightAlert.self, from: Data(json.utf8))
    }

    @Test("reads who PostHog e-mails, from the objects the response carries")
    func subscribedUsers() throws {
        // `subscribed_users` is ids on the way in and `UserBasicSerializer`
        // objects on the way out — the same asymmetry `insight` has.
        let decoded = try alert("""
        {"id":"a","state":"Firing","enabled":true,"subscribed_users":[
          {"first_name":"Ada","last_name":"Lovelace","email":"alert.recipient@example.org"},
          {"first_name":"","last_name":"","email":"alert.recipient@example.org"}
        ]}
        """)
        #expect(decoded.subscribedUsers == ["Ada Lovelace", "alert.recipient@example.org"])
        #expect(decoded.deliverySummary.contains("Ada Lovelace"))
    }

    @Test("an empty subscriber list is hedged, not reported as nobody")
    func noSubscribers() throws {
        let decoded = try alert(#"{"id":"a","state":"Not firing","enabled":true,"subscribed_users":[]}"#)
        #expect(decoded.subscribedUsers.isEmpty)
        // This client never fetches an alert's Slack/webhook destinations, so it
        // cannot say nobody is told — only that no e-mail recipient is set.
        #expect(decoded.deliverySummary.contains("destination GetHog can't see"))
    }

    @Test("a subscriber of an unexpected shape does not take the row down")
    func malformedSubscriber() throws {
        let decoded = try alert(#"{"id":"a","state":"Firing","enabled":true,"subscribed_users":"nope"}"#)
        #expect(decoded.id == "a")
        #expect(decoded.subscribedUsers.isEmpty)
    }

    /// `state` is written when a check runs and a snoozed alert is not checked,
    /// so an expired snooze can still read `Snoozed`. The date is what decides
    /// whether "Unsnooze" is offered.
    @Test("a snooze is judged by its end date, not by the reported state")
    func snoozeExpiryBeatsState() throws {
        let past = try alert(#"{"id":"a","state":"Snoozed","enabled":true,"snoozed_until":"2020-01-01T00:00:00Z"}"#)
        #expect(past.state == .snoozed)
        #expect(past.isSnoozed(now: Date()) == false)

        let future = try alert(#"{"id":"a","state":"Snoozed","enabled":true,"snoozed_until":"2099-01-01T00:00:00Z"}"#)
        #expect(future.isSnoozed(now: Date()))

        let never = try alert(#"{"id":"a","state":"Firing","enabled":true}"#)
        #expect(never.snoozedUntil == nil)
        #expect(never.isSnoozed(now: Date()) == false)
    }
}
