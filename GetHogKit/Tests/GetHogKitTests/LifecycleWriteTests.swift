import Foundation
import Testing

@testable import GetHogKit

/// The respond-half writes: end/pause/resume an experiment, stop/launch/resume a
/// survey, set a release-condition group's rollout percentage, and the 409 that
/// means "filed for approval".
///
/// These tests never send a network request. Every assertion is on an inert
/// `Endpoint` path, method and body, or on `PostHogClient` handling an authored
/// synthetic response envelope. They establish that the app builds the public
/// contract; they do not make a claim about a particular deployment.
///
/// Same construction as `AnnotationAPITests` and `ErrorTrackingAPITests`, which
/// pin the app's other two write families the same way and for the same reason.
@Suite("Lifecycle writes")
struct LifecycleWriteTests {

    private func json(_ endpoint: Endpoint?) throws -> [String: Any] {
        let built = try #require(endpoint)
        let data = try #require(built.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func text(_ endpoint: Endpoint?) throws -> String {
        let built = try #require(endpoint)
        return String(decoding: try #require(built.body), as: UTF8.self)
    }

    // MARK: - Experiments

    @Test("ends an experiment with the conclusion the user chose")
    func endExperiment() throws {
        let endpoint = PostHogAPI.endExperiment(
            projectID: 1_001,
            experimentID: 4103,
            conclusion: .won,
            comment: "Shipping the new step order."
        )

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1001/experiments/4103/end/")
        #expect(endpoint.query.isEmpty)
        // `.crud`, not `.query`: a lifecycle action is a REST write and must not
        // spend the scarce analytics budget.
        #expect(endpoint.category == .crud)

        let body = try json(endpoint)
        #expect(body["conclusion"] as? String == "won")
        #expect(body["conclusion_comment"] as? String == "Shipping the new step order.")
    }

    /// The field whose blast radius is a git repository. `EndExperimentSerializer`
    /// accepts `open_cleanup_pr`, which starts a task that opens a draft pull
    /// request deleting the flag's code from the experiment's linked GitHub
    /// repository. It is not a parameter of `endExperiment`, so no caller — now or
    /// later — can produce it; this pins that it never appears on the wire.
    @Test("never sends open_cleanup_pr, whatever the caller asks for")
    func endNeverOpensAPullRequest() throws {
        for conclusion in ExperimentConclusion.allCases {
            let body = try text(
                PostHogAPI.endExperiment(projectID: 1, experimentID: 1, conclusion: conclusion)
            )
            #expect(!body.contains("open_cleanup_pr"))
            #expect(!body.contains("cleanup"))
        }
    }

    /// `end_experiment` assigns `experiment.conclusion = conclusion`
    /// *unconditionally*, and the serializer defaults an absent field to `None` —
    /// so an end without a conclusion writes `null` over whatever was recorded.
    /// The API's optionality is not repeated in this signature, and this is the
    /// test that says so: every conclusion is expressible and the absence of one
    /// is not.
    @Test("cannot end an experiment without naming a conclusion")
    func endAlwaysCarriesAConclusion() throws {
        let wire = try ExperimentConclusion.allCases.map { conclusion in
            try json(PostHogAPI.endExperiment(projectID: 1, experimentID: 1, conclusion: conclusion))["conclusion"] as? String
        }
        #expect(wire == ["won", "lost", "inconclusive", "stopped_early", "invalid"])
        #expect(!wire.contains(nil))
    }

    /// A blank comment is not sent, for the same reason a missing conclusion is
    /// not allowed: `conclusion_comment` is assigned unconditionally too, so
    /// writing `""` where the user typed nothing erases whatever was there.
    @Test("omits an empty comment rather than blanking the recorded one")
    func endOmitsBlankComment() throws {
        for empty in [nil, "", "   ", "\n\t"] {
            let body = try json(
                PostHogAPI.endExperiment(
                    projectID: 1, experimentID: 1, conclusion: .lost, comment: empty
                )
            )
            #expect(body["conclusion_comment"] == nil)
            #expect(body["conclusion"] as? String == "lost")
        }
    }

    /// `end/` and `pause/` are separate calls because they have different blast
    /// radii — `end/` freezes the results window and does not touch the feature
    /// flag, `pause/` calls `set_flag_active` on it. Pinning the three paths apart
    /// is what keeps a future refactor from folding them into one `stop(…)`.
    @Test("pauses and resumes through their own actions, carrying no state")
    func pauseAndResume() throws {
        let pause = PostHogAPI.pauseExperiment(projectID: 1_001, experimentID: 4101)
        #expect(pause.method == "POST")
        #expect(pause.path == "/api/projects/1001/experiments/4101/pause/")
        #expect(pause.category == .crud)
        // `request=None` server-side. `{}` is sent so the request carries a
        // Content-Type; it must carry no *fields*, because there is no field on
        // this action that would mean anything.
        #expect(try json(pause).isEmpty)

        let resume = PostHogAPI.resumeExperiment(projectID: 1_001, experimentID: 4101)
        #expect(resume.method == "POST")
        #expect(resume.path == "/api/projects/1001/experiments/4101/resume/")
        #expect(try json(resume).isEmpty)

        // Three distinct paths, so "stop" can never be one call with a flag.
        let end = PostHogAPI.endExperiment(projectID: 1_001, experimentID: 4101, conclusion: .stoppedEarly)
        #expect(Set([pause.path, resume.path, end.path]).count == 3)
    }

    /// `ship_variant/` rewrites the linked flag's variant distribution to 100% for
    /// one arm. There is no builder for it and there must not be one; if this ever
    /// fails, somebody added the most dangerous action on the viewset.
    @Test("has no way to express ship_variant")
    func shipVariantIsUnreachable() throws {
        let built = [
            PostHogAPI.endExperiment(projectID: 1, experimentID: 1, conclusion: .won),
            PostHogAPI.pauseExperiment(projectID: 1, experimentID: 1),
            PostHogAPI.resumeExperiment(projectID: 1, experimentID: 1),
        ]
        for endpoint in built {
            #expect(!endpoint.path.contains("ship_variant"))
            #expect(!endpoint.path.contains("archive"))
        }
    }

    // MARK: - Surveys

    @Test("stops and launches a survey through the bodyless actions")
    func stopAndLaunchSurvey() throws {
        let id = "018f7e00-0000-7000-8000-000000000002"

        let stop = PostHogAPI.stopSurvey(projectID: 1_001, surveyID: id)
        #expect(stop.method == "POST")
        #expect(stop.path == "/api/projects/1001/surveys/\(id)/stop/")
        #expect(stop.category == .crud)
        #expect(try json(stop).isEmpty)

        let launch = PostHogAPI.launchSurvey(projectID: 1_001, surveyID: id)
        #expect(launch.method == "POST")
        #expect(launch.path == "/api/projects/1001/surveys/\(id)/launch/")
        #expect(try json(launch).isEmpty)
    }

    /// The deliberate half of the "two ways to stop a survey are not the same
    /// write" finding: this app stops through the action, which bypasses the
    /// serializer, rather than through `PATCH {"end_date": …}`, which runs it and
    /// mirrors the running state onto the survey's targeting flags. Pinned because
    /// the choice is invisible in the calling code — both spellings would look
    /// like "stop the survey" at the call site.
    @Test("stops through the action, never through a date PATCH")
    func stopIsNotAPatch() throws {
        let stop = PostHogAPI.stopSurvey(projectID: 1, surveyID: "s")
        #expect(stop.method == "POST")
        #expect(stop.path.hasSuffix("/stop/"))
        #expect(!(try text(stop).contains("end_date")))
    }

    /// Resume has no action of its own, so it is the one survey write that must go
    /// through the serializer — and therefore the one where the body's width is
    /// the whole safety argument. One key, and that key's value must reach the
    /// wire as JSON `null`: a Swift `nil` dropped from the dictionary would
    /// produce `{}`, which is a PATCH that answers 200 and changes nothing, so the
    /// resume would silently not happen.
    @Test("resumes with exactly one key, and that key is a real null")
    func resumeSurvey() throws {
        let endpoint = PostHogAPI.resumeSurvey(projectID: 1_001, surveyID: "abc")
        #expect(endpoint.method == "PATCH")
        #expect(endpoint.path == "/api/projects/1001/surveys/abc/")
        #expect(endpoint.category == .crud)

        let body = try json(endpoint)
        #expect(body.count == 1)
        #expect(body["end_date"] is NSNull)
        // Read as text as well: `NSNull` in a parsed dictionary and `null` on the
        // wire are two different claims, and only the second one is what PostHog
        // sees.
        #expect(try text(endpoint) == #"{"end_date":null}"#)

        // Nothing the serializer would act on if it were present. Each of these is
        // a branch of `SurveySerializerCreateUpdateOnly.update()`, and `conditions`
        // is the sharp one — present but carrying no `actions` clears the survey's
        // action associations.
        let wire = try text(endpoint)
        for field in ["conditions", "targeting_flag", "iteration_count", "questions", "start_date", "archived"] {
            #expect(!wire.contains(field), "resume must not carry \(field)")
        }
    }

    // MARK: - Rollout percentage

    /// Authored filters include two keys `FlagFilters` does not model. They are
    /// the point: a typed re-encode would drop both.
    private var authoredFilters: JSONValue {
        .object([
            "groups": .array([
                .object([
                    "properties": .array([]),
                    "rollout_percentage": .number(0),
                    "aggregation_group_type_index": .null,
                ])
            ]),
            "early_exit": .bool(false),
            "aggregation_group_type_index": .null,
            // Present when a flag carries per-variant payloads, and the single
            // most expensive key to lose.
            "payloads": .object(["control": .string("{\"a\":1}")]),
        ])
    }

    private func flag(
        filters: JSONValue,
        version: Int? = 1,
        id: Int = 710_201
    ) throws -> FeatureFlag {
        var object: [String: JSONValue] = [
            "id": .number(Double(id)),
            "key": .string("harbor-checkout-rollout"),
            "active": .bool(true),
            "filters": filters,
        ]
        if let version { object["version"] = .number(Double(version)) }
        let data = try JSONEncoder().encode(JSONValue.object(object))
        return try JSONDecoder().decode(FeatureFlag.self, from: data)
    }

    /// The whole reason the write is a JSON transformation. Every key the client
    /// fails to echo is destroyed by a `filters` PATCH, and three of the keys in
    /// this payload do not exist on `FlagFilters` at all.
    @Test("carries every unmodelled key through untouched")
    func rolloutPreservesUnknownKeys() throws {
        let mutated = try #require(
            FlagRollout.filters(authoredFilters, settingGroup: 0, toPercentage: 25)
        )

        #expect(mutated["early_exit"] == .bool(false))
        #expect(mutated["aggregation_group_type_index"] == .null)
        #expect(mutated["payloads"]?["control"] == .string("{\"a\":1}"))
        #expect(mutated["groups"]?[0]?["aggregation_group_type_index"] == .null)
        #expect(mutated["groups"]?[0]?["properties"] == .array([]))
        #expect(mutated["groups"]?[0]?["rollout_percentage"] == .number(25))

        // And the decoded model provably cannot round-trip them, which is what
        // makes the raw path necessary rather than merely tidy.
        let typed = try JSONDecoder().decode(FlagFilters.self, from: JSONEncoder().encode(authoredFilters))
        let reencoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(
                JSONValue.object([
                    "groups": .array(
                        (typed.groups ?? []).map { group in
                            .object(["rollout_percentage": .number(group.rolloutPercentage ?? 0)])
                        }
                    )
                ])
            )
        ) as? [String: Any]
        #expect(reencoded?["early_exit"] == nil)
        #expect(reencoded?["payloads"] == nil)
    }

    /// A `filters` PATCH with no `groups` key answers 200 with the flag
    /// unchanged — `validate_filters` returns the instance's existing filters. The
    /// transformation cannot produce one, because it refuses to start from a
    /// `filters` object that has none.
    @Test("always includes groups, and refuses filters that have none")
    func rolloutAlwaysCarriesGroups() throws {
        #expect(FlagRollout.filters(.object(["multivariate": .object([:])]), settingGroup: 0, toPercentage: 50) == nil)
        #expect(FlagRollout.filters(.object([:]), settingGroup: 0, toPercentage: 50) == nil)
        #expect(FlagRollout.filters(.object(["groups": .object([:])]), settingGroup: 0, toPercentage: 50) == nil)
        #expect(FlagRollout.filters(.array([]), settingGroup: 0, toPercentage: 50) == nil)

        let endpoint = try PostHogAPI.setFlagRollout(
            projectID: 1, flag: flag(filters: authoredFilters), groupIndex: 0, percentage: 50
        )
        #expect(try json(endpoint)["filters"] != nil)
        #expect(try text(endpoint).contains("\"groups\""))
    }

    /// There is no "the" rollout percentage. `FeatureFlag.rolloutPercentage` is a
    /// `max()` across groups, so a write has to name one — and must leave the
    /// others exactly as they were.
    @Test("edits only the named condition group")
    func rolloutEditsOneGroup() throws {
        let two = JSONValue.object([
            "groups": .array([
                .object(["rollout_percentage": .number(10), "variant": .string("control")]),
                .object(["rollout_percentage": .number(90), "properties": .array([.object(["key": .string("email")])])]),
            ])
        ])
        // The derived summary reads 90 for this flag; writing that back into group
        // 0 is the exact mistake this signature prevents.
        let decoded = try flag(filters: two)
        #expect(decoded.rolloutPercentage == 90)

        let mutated = try #require(FlagRollout.filters(two, settingGroup: 1, toPercentage: 5))
        #expect(mutated["groups"]?[0]?["rollout_percentage"] == .number(10))
        #expect(mutated["groups"]?[0]?["variant"] == .string("control"))
        #expect(mutated["groups"]?[1]?["rollout_percentage"] == .number(5))
        #expect(mutated["groups"]?[1]?["properties"]?[0]?["key"] == .string("email"))

        // Out of range indexes build nothing rather than landing on a neighbour.
        #expect(FlagRollout.filters(two, settingGroup: 2, toPercentage: 5) == nil)
        #expect(FlagRollout.filters(two, settingGroup: -1, toPercentage: 5) == nil)
    }

    @Test("refuses a percentage PostHog would reject")
    func rolloutValidatesRange() throws {
        for bad in [-1.0, 100.1, 1000, .infinity, -.infinity, Double.nan] {
            #expect(
                FlagRollout.filters(authoredFilters, settingGroup: 0, toPercentage: bad) == nil,
                "\(bad) should not build"
            )
        }
        for good in [0.0, 0.5, 50, 99.9, 100] {
            #expect(FlagRollout.filters(authoredFilters, settingGroup: 0, toPercentage: good) != nil)
        }
    }

    /// `version` is read off the *raw body* server-side, so omitting it skips the
    /// conflict check entirely and last write wins. Sending the version decoded
    /// with the flag is the only way to be told you were racing.
    @Test("sends the decoded version, as a JSON integer, and omits it when absent")
    func rolloutSendsVersion() throws {
        let endpoint = try PostHogAPI.setFlagRollout(
            projectID: 1_001, flag: flag(filters: authoredFilters, version: 7), groupIndex: 0, percentage: 25
        )
        #expect(try #require(endpoint).method == "PATCH")
        #expect(try #require(endpoint).path == "/api/projects/1001/feature_flags/710201/")
        #expect(try #require(endpoint).category == .crud)

        let body = try json(endpoint)
        // Read back as an integer: `7.0` on the wire is a different document from
        // `7`, and only one of them looks like the value the server stores.
        #expect(body["version"] as? Int == 7)
        #expect(try text(endpoint).contains("\"version\":7"))

        // A flag decoded without one omits the key rather than guessing a number,
        // which would be a claim about a row this client never read.
        let versionless = try PostHogAPI.setFlagRollout(
            projectID: 1, flag: flag(filters: authoredFilters, version: nil), groupIndex: 0, percentage: 25
        )
        #expect(try json(versionless)["version"] == nil)
    }

    /// Whole percentages are written whole. PostHog accepts either, but the flag's
    /// own payload reads `0`, and a body that matches what the server stores is
    /// one fewer difference to explain in an activity-log diff.
    @Test("writes a whole percentage without a fraction")
    func rolloutNumberFormatting() throws {
        let endpoint = try PostHogAPI.setFlagRollout(
            projectID: 1, flag: flag(filters: authoredFilters), groupIndex: 0, percentage: 25
        )
        #expect(try text(endpoint).contains("\"rollout_percentage\":25"))
        #expect(!(try text(endpoint).contains("25.0")))
    }

    @Test("builds nothing at all for a flag whose filters could not be kept")
    func rolloutRefusesWithoutRawFilters() throws {
        let bare = try JSONDecoder().decode(
            FeatureFlag.self,
            from: Data(#"{"id":1,"key":"k","active":true}"#.utf8)
        )
        #expect(bare.filtersRaw == nil)
        #expect(!bare.canEditRollout)
        #expect(PostHogAPI.setFlagRollout(projectID: 1, flag: bare, groupIndex: 0, percentage: 10) == nil)

        // …and a flag whose filters carry no groups is refused by the same gate,
        // rather than sending the PATCH the server would silently ignore.
        let groupless = try flag(filters: .object(["multivariate": .object([:])]))
        #expect(!groupless.canEditRollout)
        #expect(PostHogAPI.setFlagRollout(projectID: 1, flag: groupless, groupIndex: 0, percentage: 10) == nil)

        #expect(try flag(filters: authoredFilters).canEditRollout)
    }
}

/// HTTP 409, which is the one response in this client that can mean the request
/// worked.
///
/// Every body below is an authored synthetic envelope derived from the public
/// response contract. These tests establish that `PostHogClient` maps the shape
/// onto something a screen can describe correctly; they do not perform a write.
@Suite("Approval-gated writes")
struct ApprovalRequiredTests {

    private func client(status: Int, body: String) -> (PostHogClient, StubTransport) {
        let transport = StubTransport(status: status, body: body)
        return (
            PostHogClient(
                auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
                transport: transport,
                governor: RateLimitGovernor()
            ),
            transport
        )
    }

    private func error(status: Int, body: String) async -> PostHogError? {
        let (client, _) = client(status: status, body: body)
        do {
            _ = try await client.data(for: PostHogAPI.setFlagActive(projectID: 1, flagID: 1, active: false))
            return nil
        } catch let error as PostHogError {
            return error
        } catch {
            return nil
        }
    }

    /// Before this existed, a 409 fell through to `default` and reached the screen
    /// as `PostHogError.http(status: 409, …)` — which every optimistic caller in
    /// this app reports as "couldn't do that". A change request existed and
    /// approvers had been emailed.
    @Test("reads approval_required as a filed change request, not a failure")
    func approvalRequired() async throws {
        let body = """
            {"code":"approval_required","status":"approval_required",
             "message":"This change requires approval.",
             "resource_type":"feature_flag","resource_id":"710201",
             "change_request_id":"018f7e00-0000-7000-8000-000000000004",
             "required_approvers":[{"id":700202,"email":"approval.reviewer@example.com"},
                                   {"id":71203,"first_name":"Grace","last_name":"Hopper"}]}
            """
        guard case .approvalRequired(let outcome)? = await error(status: 409, body: body) else {
            Issue.record("expected .approvalRequired")
            return
        }

        #expect(outcome.kind == .filed)
        #expect(outcome.changeRequestID == "018f7e00-0000-7000-8000-000000000004")
        #expect(outcome.approvers == ["approval.reviewer@example.com", "Grace Hopper"])
        #expect(outcome.detail == "This change requires approval.")

        // The sentence a reader sees leads with what is true of the *object*.
        #expect(outcome.summary.hasPrefix("Nothing changed"))
        #expect(outcome.summary.contains("approval.reviewer@example.com"))
        #expect(!outcome.summary.lowercased().contains("failed"))
        #expect(!outcome.summary.lowercased().contains("couldn't"))
    }

    /// The sibling code: somebody already filed this, so yours added nothing. Two
    /// different sentences, because "you filed it" and "it was already filed" call
    /// for different next actions.
    @Test("tells an already-pending request apart from one it just filed")
    func changeRequestPending() async throws {
        let body = #"{"code":"change_request_pending","message":"A change request is already pending.","required_approvers":["approval.reviewer@example.com"]}"#
        guard case .approvalRequired(let outcome)? = await error(status: 409, body: body) else {
            Issue.record("expected .approvalRequired")
            return
        }
        #expect(outcome.kind == .alreadyPending)
        #expect(outcome.changeRequestID == nil)
        #expect(outcome.summary.contains("already waiting"))
        #expect(outcome.summary.contains("approval.reviewer@example.com has to approve it."))
    }

    /// An id can be an integer primary key or a uuid string and nothing read
    /// establishes which, so it is decoded as a JSON value and rendered.
    @Test("quotes a change-request id whichever JSON type it arrives as")
    func changeRequestIDTypeAgnostic() async throws {
        for (wire, expected) in [("\"abc-1\"", "abc-1"), ("4471", "4471")] {
            let body = #"{"code":"approval_required","change_request_id":\#(wire)}"#
            guard case .approvalRequired(let outcome)? = await error(status: 409, body: body) else {
                Issue.record("expected .approvalRequired for \(wire)")
                continue
            }
            #expect(outcome.changeRequestID == expected)
        }
    }

    /// The approver list's element shape is not documented anywhere read. Plain
    /// strings, bare ids and objects are all described; anything else is dropped
    /// rather than printed, because a dialog reading "needs approval from
    /// `{"foo":1}`" is worse than one that names nobody.
    @Test("describes the approver shapes it knows and drops the ones it doesn't")
    func approverDescriptions() {
        #expect(ApprovalOutcome.describe(.string("approval.reviewer@example.com")) == "approval.reviewer@example.com")
        #expect(ApprovalOutcome.describe(.number(700_202)) == "User 700202")
        #expect(ApprovalOutcome.describe(.object(["email": .string("approval.reviewer@example.com")])) == "approval.reviewer@example.com")
        #expect(ApprovalOutcome.describe(.object(["name": .string("Ada L")])) == "Ada L")
        #expect(
            ApprovalOutcome.describe(.object(["first_name": .string("Ada"), "last_name": .string("Lovelace")]))
                == "Ada Lovelace"
        )
        #expect(ApprovalOutcome.describe(.object(["id": .number(7)])) == "User 7")
        #expect(ApprovalOutcome.describe(.object(["unexpected": .bool(true)])) == nil)
        #expect(ApprovalOutcome.describe(.null) == nil)
        #expect(ApprovalOutcome.describe(.string("")) == nil)

        // An approver list nobody could describe still produces a usable sentence.
        let anonymous = ApprovalOutcome(kind: .filed)
        #expect(anonymous.summary.hasPrefix("Nothing changed yet."))
        #expect(!anonymous.summary.contains("approve it"))
    }

    /// 409 is also what the flag serializer's version check raises, and that one
    /// really is a conflict. An unrecognised 409 must not be dressed up as an
    /// approval — telling someone their change is waiting for a colleague when it
    /// is not is worse than a generic message.
    @Test("keeps a version conflict a conflict")
    func versionConflict() async throws {
        let body = #"{"type":"validation_error","code":"conflict","detail":"The flag was changed by Ada while you were editing it."}"#
        guard case .editConflict(let detail)? = await error(status: 409, body: body) else {
            Issue.record("expected .editConflict")
            return
        }
        #expect(detail == "The flag was changed by Ada while you were editing it.")

        // A 409 with no body at all still lands on the conflict, not the approval.
        guard case .editConflict? = await error(status: 409, body: "") else {
            Issue.record("expected .editConflict for an empty body")
            return
        }
    }

    /// The property every optimistic caller branches on. Getting this wrong in
    /// either direction is the defect this whole case exists to fix.
    @Test("marks only the approval case as pending, and none of them retryable")
    func classification() {
        let filed = PostHogError.approvalRequired(ApprovalOutcome(kind: .filed))
        #expect(filed.isApprovalPending)
        #expect(!filed.isRetryable)
        #expect(filed.hasReadableDescription)
        #expect(filed.technicalDetail == nil)

        let conflict = PostHogError.editConflict(detail: nil)
        #expect(!conflict.isApprovalPending)
        #expect(!conflict.isRetryable)
        #expect(conflict.errorDescription?.isEmpty == false)

        for other in [PostHogError.unauthorized, .rateLimited(retryAfter: 1), .http(status: 500, detail: nil)] {
            #expect(!other.isApprovalPending)
        }
    }
}
