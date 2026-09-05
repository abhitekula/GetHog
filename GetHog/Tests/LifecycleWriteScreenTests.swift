import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// A transport that answers whatever the test says, and records what it was
/// asked.
///
/// Same construction as `AnnotationComposerTests`: every request and response is
/// authored locally. The tests pin the request built, the state shown while it is
/// out, and what happens when each of the three possible responses comes back.
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

// MARK: - Project-scoped flag recovery

/// Holds project 1's list response until project 2 has already landed. Both
/// payloads are authored and synthetic; the ordering is the behavior under
/// test, not network timing.
private actor OutOfOrderFlagsTransport: HTTPTransport {
    private var firstStarted = false
    private var releaseFirst: CheckedContinuation<Void, Never>?

    func waitForFirstRequest() async {
        while !firstStarted { await Task.yield() }
    }

    func releaseFirstRequest() {
        releaseFirst?.resume()
        releaseFirst = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let projectID = request.url?.pathComponents
            .drop(while: { $0 != "projects" })
            .dropFirst()
            .first
            .flatMap(Int.init) ?? 0

        if projectID == 1 {
            firstStarted = true
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
            }
        }

        let body = """
        {"count":1,"next":null,"previous":null,"results":[
          {"id":\(projectID * 100 + 1),"key":"project-\(projectID)-flag","active":true}
        ]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// Holds one feature-flag PATCH so a project switch can happen while the
/// controller is suspended in `PostHogClient.data(for:)`.
private actor HeldFlagWriteTransport: HTTPTransport {
    private let status: Int
    private let body: String
    private var started = false
    private var release: CheckedContinuation<Void, Never>?

    init(status: Int, body: String = "{}") {
        self.status = status
        self.body = body
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish() {
        release?.resume()
        release = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        await withCheckedContinuation { continuation in
            release = continuation
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

/// Holds the device-owner check so the selected project can disappear while a
/// confirmed write is suspended exactly where Face ID or Touch ID suspends it.
@MainActor
private final class HeldFlagBiometricGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<BiometricGate.Outcome, Never>?

    func evaluate() async -> BiometricGate.Outcome {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish(_ outcome: BiometricGate.Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

@Suite("Flag project recovery")
@MainActor
struct FlagProjectRecoveryTests {
    private func scopedClient(_ transport: some HTTPTransport) -> PostHogClient {
        PostHogClient(auth: StaticAuth(), transport: transport)
    }

    @Test("a late old-project flag response cannot replace the new project")
    func lateProjectResponseIsDiscarded() async {
        let transport = OutOfOrderFlagsTransport()
        let store = FlagsStore()
        let first = Task { await store.load(client: scopedClient(transport), projectID: 1) }
        await transport.waitForFirstRequest()

        await store.load(client: scopedClient(transport), projectID: 2)
        await transport.releaseFirstRequest()
        await first.value

        #expect(store.flags.map(\.key) == ["project-2-flag"])
    }

    @Test("a detail loaded in one project cannot write through the current project")
    func staleDetailCannotWrite() async throws {
        let controller = FlagToggleController()
        let (client, transport) = client([(200, "{}"), (200, "{}")])
        let flag = try JSONDecoder().decode(
            FeatureFlag.self,
            from: Data(
                #"{"id":710301,"key":"synthetic-project-boundary","active":true,"filters":{"groups":[{"rollout_percentage":10,"properties":[]}]}}"#.utf8
            )
        )

        await controller.setActive(
            false,
            flag: flag,
            client: client,
            projectID: 1_001,
            currentProjectID: 2_002
        )
        await controller.setRollout(
            25,
            group: 0,
            flag: flag,
            client: client,
            projectID: 1_001,
            currentProjectID: 2_002
        )

        #expect(await transport.requests.isEmpty)
        #expect(controller.effectiveActive(flag))
        #expect(controller.effectiveRollout(flag, group: 0) == 10)
    }

    @Test("a same-project reconnect while authentication is open blocks the old client's PATCH")
    func reconnectDuringAuthenticationBlocksWrite() async throws {
        let controller = FlagToggleController()
        let (client, transport) = client([(200, "{}")])
        let gate = HeldFlagBiometricGate()
        let flag: FeatureFlag = try decode(
            #"{"id":710301,"key":"synthetic-auth-boundary","active":true}"#
        )
        let originalScope = FlagWriteScope(
            projectID: 1_001,
            projectRegion: .usCloud,
            authSessionID: UUID()
        )
        var currentScope: FlagWriteScope? = originalScope

        let write = Task {
            await controller.setActive(
                false,
                flag: flag,
                client: client,
                projectID: 1_001,
                expectedScope: originalScope,
                currentScope: { currentScope },
                isGateEnabled: true,
                gate: { await gate.evaluate() }
            )
        }
        await gate.waitUntilStarted()
        currentScope = FlagWriteScope(
            projectID: 1_001,
            projectRegion: .usCloud,
            authSessionID: UUID()
        )
        gate.finish(.passed)
        await write.value

        #expect(await transport.requests.isEmpty)
        #expect(controller.effectiveActive(flag))
        #expect(!controller.isBusy(flag))
        #expect(controller.successCount == 0)
    }

    @Test("an old completion cannot finish or clear a same-ID write in the new project")
    func oldCompletionCannotAffectNewProjectWrite() async throws {
        let controller = FlagToggleController()
        let oldTransport = HeldFlagWriteTransport(status: 200)
        let newTransport = HeldFlagWriteTransport(status: 200)
        let oldFlag: FeatureFlag = try decode(
            #"{"id":710301,"key":"old-project-flag","active":true}"#
        )
        let newFlag: FeatureFlag = try decode(
            #"{"id":710301,"key":"new-project-flag","active":true}"#
        )

        let oldWrite = Task {
            await controller.setActive(
                false,
                flag: oldFlag,
                client: scopedClient(oldTransport),
                projectID: 1
            )
        }
        await oldTransport.waitUntilStarted()
        #expect(controller.isBusy(oldFlag))

        controller.resetForProjectChange()
        #expect(!controller.isBusy(newFlag))
        let newWrite = Task {
            await controller.setActive(
                false,
                flag: newFlag,
                client: scopedClient(newTransport),
                projectID: 2
            )
        }
        await newTransport.waitUntilStarted()
        #expect(controller.isBusy(newFlag))

        await oldTransport.finish()
        await oldWrite.value

        // The old success is neither this project's success nor permission to
        // remove its same-numeric-ID in-flight marker.
        #expect(controller.successCount == 0)
        #expect(controller.isBusy(newFlag))
        #expect(controller.effectiveActive(newFlag) == false)
        #expect(controller.message == nil)

        await newTransport.finish()
        await newWrite.value
        #expect(controller.successCount == 1)
        #expect(!controller.isBusy(newFlag))
    }

    @Test("an old rollout failure cannot roll back or report in the new project")
    func oldRolloutFailureCannotAffectNewProject() async throws {
        let controller = FlagToggleController()
        let oldTransport = HeldFlagWriteTransport(
            status: 409,
            body: #"{"code":"conflict","detail":"Synthetic stale conflict."}"#
        )
        let newTransport = HeldFlagWriteTransport(status: 200)
        let oldFlag: FeatureFlag = try decode(
            #"{"id":710301,"key":"old-project-flag","active":true,"filters":{"groups":[{"rollout_percentage":10,"properties":[]}]}}"#
        )
        let newFlag: FeatureFlag = try decode(
            #"{"id":710301,"key":"new-project-flag","active":true,"filters":{"groups":[{"rollout_percentage":80,"properties":[]}]}}"#
        )

        let oldWrite = Task {
            await controller.setRollout(
                25,
                group: 0,
                flag: oldFlag,
                client: scopedClient(oldTransport),
                projectID: 1
            )
        }
        await oldTransport.waitUntilStarted()
        #expect(controller.effectiveRollout(oldFlag, group: 0) == 25)

        controller.resetForProjectChange()
        let newWrite = Task {
            await controller.setRollout(
                60,
                group: 0,
                flag: newFlag,
                client: scopedClient(newTransport),
                projectID: 2
            )
        }
        await newTransport.waitUntilStarted()
        #expect(controller.effectiveRollout(newFlag, group: 0) == 60)

        await oldTransport.finish()
        await oldWrite.value

        // The old rollback must not remove project 2's same-ID optimistic
        // value, and its defer must not clear project 2's busy state.
        #expect(controller.effectiveRollout(newFlag, group: 0) == 60)
        #expect(controller.isBusy(newFlag))
        #expect(controller.failureCount == 0)
        #expect(controller.filedCount == 0)
        #expect(controller.message == nil)

        await newTransport.finish()
        await newWrite.value
        #expect(controller.successCount == 1)
        #expect(!controller.isBusy(newFlag))
    }
}

private struct StaticAuth: AuthProvider {
    let region = PostHogRegion.usCloud
    func authorizationHeader() async throws -> String { "Bearer test" }
    func handleUnauthorized() async throws {}
}

/// An authored 409 body matching the public approval-policy contract. See
/// `ApprovalRequiredTests` in the kit.
private let approvalBody = """
    {"code":"approval_required","message":"This change requires approval.",
     "change_request_id":"cr-1","required_approvers":["approval.reviewer@example.com"]}
    """

private func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func client(_ responses: [(Int, String)]) -> (PostHogClient, ScriptedTransport) {
    let transport = ScriptedTransport(responses)
    return (PostHogClient(auth: StaticAuth(), transport: transport), transport)
}

// MARK: - Experiments

@Suite("Experiment lifecycle")
@MainActor
struct ExperimentLifecycleTests {

    private func experiment(
        status: String = "running",
        conclusion: String? = nil,
        endDate: String? = nil
    ) throws -> Experiment {
        var object: [String: Any] = [
            "id": 4101,
            "name": "Budget wizard step order",
            "feature_flag_key": "budget-wizard-order",
            "start_date": "2026-01-01T00:00:00Z",
            "status": status,
        ]
        if let conclusion { object["conclusion"] = conclusion }
        if let endDate { object["end_date"] = endDate }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Experiment.self, from: data)
    }

    /// The three actions have different blast radii, so which one each control is
    /// allowed to reach is part of the design and not an implementation detail.
    @Test("offers only the actions the experiment's state can accept")
    func availability() throws {
        let controller = ExperimentLifecycleController()

        let running = try experiment(status: "running")
        #expect(controller.canPause(running))
        #expect(!controller.canResume(running))
        #expect(controller.canEnd(running))

        let paused = try experiment(status: "paused")
        #expect(!controller.canPause(paused))
        #expect(controller.canResume(paused))
        // A paused experiment can still be ended: its results window is open.
        #expect(controller.canEnd(paused))

        // A draft has nothing to pause and nothing to conclude.
        let draft = try experiment(status: "draft")
        #expect(!controller.canPause(draft))
        #expect(!controller.canResume(draft))
        #expect(!controller.canEnd(draft))

        // `end/` 400s on an already-stopped experiment, so offering it there
        // would be offering a button that cannot work.
        let stopped = try experiment(status: "stopped", endDate: "2026-01-20T00:00:00Z")
        #expect(!controller.canEnd(stopped))
    }

    @Test("ends with the conclusion and the comment the user chose")
    func end() async throws {
        let controller = ExperimentLifecycleController()
        let (client, transport) = client([(200, "{}")])
        let experiment = try experiment()

        await controller.end(
            experiment,
            conclusion: .won,
            comment: "Shipping it.",
            client: client,
            projectID: 1_001
        )

        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.hasSuffix("/api/projects/1001/experiments/4101/end/"))
        #expect(sent.body.contains("\"conclusion\":\"won\""))
        #expect(sent.body.contains("Shipping it."))
        // The field whose blast radius is a git repository.
        #expect(!sent.body.contains("open_cleanup_pr"))

        #expect(controller.successCount == 1)
        #expect(controller.failureCount == 0)
        #expect(controller.effectiveStatusText(experiment) == "Complete")
        #expect(controller.effectiveConclusion(experiment) == .won)
        #expect(controller.effectiveEndDate(experiment) != nil)

        // Ending does not touch the flag, and the screen says so afterwards as
        // well as before — someone who ended an experiment from a train should
        // not believe they also stopped serving the variant.
        let message = try #require(controller.message)
        #expect(message.kind == .notice)
        #expect(message.text.contains("feature flag was not touched"))
    }

    /// Pausing writes nothing on the experiment row — PostHog derives `paused`
    /// from the linked flag being inactive — so the override is the only place
    /// the change can live until the next fetch.
    @Test("pauses and resumes by moving a status the API never stores")
    func pauseAndResume() async throws {
        let controller = ExperimentLifecycleController()
        let (client, transport) = client([(200, "{}"), (200, "{}")])
        let experiment = try experiment()

        await controller.setPaused(true, experiment: experiment, client: client, projectID: 1)
        #expect(controller.effectiveStatusText(experiment) == "Paused")
        #expect(controller.effectiveStatus(experiment) == .paused)

        var sent = try #require(await transport.requests.last)
        #expect(sent.method == "POST")
        #expect(sent.url.hasSuffix("/experiments/4101/pause/"))
        #expect(sent.body == "{}")

        await controller.setPaused(false, experiment: experiment, client: client, projectID: 1)
        #expect(controller.effectiveStatusText(experiment) == "Running")
        sent = try #require(await transport.requests.last)
        #expect(sent.url.hasSuffix("/experiments/4101/resume/"))
    }

    @Test("rolls the status back when the write is refused")
    func rollback() async throws {
        let controller = ExperimentLifecycleController()
        let (client, _) = client([(403, #"{"detail":"missing scope experiment:write"}"#)])
        let experiment = try experiment()

        await controller.setPaused(true, experiment: experiment, client: client, projectID: 1)

        #expect(controller.effectiveStatusText(experiment) == "Running")
        #expect(controller.failureCount == 1)
        #expect(controller.filedCount == 0)
        let message = try #require(controller.message)
        #expect(message.kind == .failure)
        // Named, because a read-scoped key passes every preflight probe and only
        // fails here.
        #expect(message.text.contains("experiment:write"))
    }

    /// The defect the whole 409 case exists to fix, applied to experiments: the
    /// two lifecycle actions that touch a flag inherit the flag serializer's
    /// approval gate.
    ///
    /// Both halves matter and they pull in opposite directions. The optimistic
    /// state **must** roll back — the experiment really did not change. What the
    /// reader is told must **not** be a failure — a change request exists and
    /// approvers were notified.
    @Test("rolls back but reports a filed change request, not a failure")
    func approvalRequired() async throws {
        let controller = ExperimentLifecycleController()
        let (client, _) = client([(409, approvalBody)])
        let experiment = try experiment()

        await controller.setPaused(true, experiment: experiment, client: client, projectID: 1)

        // Rolled back: the experiment is unchanged, so the screen must stop
        // claiming otherwise.
        #expect(controller.effectiveStatusText(experiment) == "Running")

        // …and reported as filed, in a counter of its own, so the error haptic
        // does not say "that didn't work" about a request the server accepted.
        #expect(controller.filedCount == 1)
        #expect(controller.failureCount == 0)
        #expect(controller.successCount == 0)

        let message = try #require(controller.message)
        #expect(message.kind == .filed)
        #expect(message.text.contains("waiting for approval"))
        #expect(message.text.contains("approval.reviewer@example.com"))
        #expect(message.text.contains("cr-1"))
        #expect(!message.text.contains("Couldn't"))
    }

    @Test("drops overrides once a fresh fetch has spoken for the same experiment")
    func reconcile() async throws {
        let controller = ExperimentLifecycleController()
        let (client, _) = client([(200, "{}")])
        let experiment = try experiment()

        await controller.setPaused(true, experiment: experiment, client: client, projectID: 1)
        #expect(controller.effectiveStatusText(experiment) == "Paused")

        // Whoever else changed it in the web console wins.
        controller.reconcile(with: [try self.experiment(status: "running")])
        #expect(controller.effectiveStatusText(experiment) == "Running")
    }
}

// MARK: - Surveys

@Suite("Survey lifecycle")
@MainActor
struct SurveyLifecycleTests {

    private static let id = "018f6600-0000-7000-8000-000000000601"

    private func survey(start: String? = nil, end: String? = nil, archived: Bool = false) throws -> Survey {
        var object: [String: Any] = [
            "id": Self.id,
            "name": "Example App metric 829",
            "type": "popover",
            "archived": archived,
        ]
        if let start { object["start_date"] = start }
        if let end { object["end_date"] = end }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Survey.self, from: data)
    }

    /// A survey has no status field at all, so every one of these questions is
    /// answered from the two dates and the archived flag — the same expression
    /// PostHog's own `_should_survey_flags_be_active` uses.
    @Test("derives what it can offer from the dates, because there is no status")
    func availability() throws {
        let controller = SurveyLifecycleController()

        let draft = try survey()
        #expect(controller.canLaunch(draft))
        #expect(!controller.canStop(draft))
        #expect(!controller.canResume(draft))
        #expect(controller.effectiveStatusText(draft) == "Draft")

        let running = try survey(start: "2026-01-10T09:00:00Z")
        #expect(controller.canStop(running))
        #expect(!controller.canLaunch(running))
        #expect(!controller.canResume(running))

        let stopped = try survey(start: "2026-01-10T09:00:00Z", end: "2026-01-20T09:00:00Z")
        #expect(controller.canResume(stopped))
        #expect(!controller.canStop(stopped))
        // Not `launch/`: that action refuses a survey whose end date is in the
        // past, so the word that sounds right is the call that cannot work.
        #expect(!controller.canLaunch(stopped))

        // Archived offers nothing. Both actions 400 on one.
        let archived = try survey(start: "2026-01-10T09:00:00Z", archived: true)
        #expect(!controller.canStop(archived))
        #expect(!controller.canLaunch(archived))
        #expect(!controller.canResume(archived))
    }

    @Test("stops through the action and derives the new status from the date")
    func stop() async throws {
        let controller = SurveyLifecycleController()
        let (client, transport) = client([(200, "{}")])
        let survey = try survey(start: "2026-01-10T09:00:00Z")

        await controller.stop(survey, client: client, projectID: 1_001)

        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.hasSuffix("/api/projects/1001/surveys/\(Self.id)/stop/"))
        // Not the serializer path: a `PATCH {"end_date": …}` would also stop the
        // survey and would additionally deactivate its targeting flags.
        #expect(!sent.body.contains("end_date"))

        #expect(controller.effectiveStatusText(survey) == "Stopped")
        #expect(controller.effective(survey).endDate != nil)
        // The start date survives, so the survey is "Stopped" and not "Draft".
        #expect(controller.effective(survey).startDate != nil)

        let message = try #require(controller.message)
        #expect(message.kind == .notice)
        #expect(message.text.contains("kept"))
    }

    @Test("resumes with a single null end_date and nothing else")
    func resume() async throws {
        let controller = SurveyLifecycleController()
        let (client, transport) = client([(200, "{}")])
        let survey = try survey(start: "2026-01-10T09:00:00Z", end: "2026-01-20T09:00:00Z")

        await controller.resume(survey, client: client, projectID: 1)

        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "PATCH")
        #expect(sent.body == #"{"end_date":null}"#)
        #expect(controller.effectiveStatusText(survey) == "Running")
        #expect(controller.effective(survey).endDate == nil)
    }

    @Test("launches a draft and rolls back when refused")
    func launchAndRollback() async throws {
        let controller = SurveyLifecycleController()
        let (client, transport) = client([(200, "{}"), (403, #"{"detail":"nope"}"#)])
        let draft = try survey()

        await controller.launch(draft, client: client, projectID: 1)
        #expect(try #require(await transport.requests.first).url.hasSuffix("/launch/"))
        #expect(controller.effectiveStatusText(draft) == "Running")

        controller.reconcile(with: [draft])
        await controller.stop(draft, client: client, projectID: 1)
        #expect(controller.effectiveStatusText(draft) == "Draft")
        #expect(controller.failureCount == 1)
        #expect(try #require(controller.message).text.contains("survey:write"))
    }
}

// MARK: - Rollout

@Suite("Flag rollout")
@MainActor
struct FlagRolloutScreenTests {

    private func flag(groups: [[String: Any]], version: Int? = 1) throws -> FeatureFlag {
        var object: [String: Any] = [
            "id": 710_301,
            "key": "example-navigation",
            "active": true,
            "filters": [
                "groups": groups,
                "early_exit": false,
                "payloads": ["control": "{}"],
            ],
        ]
        if let version { object["version"] = version }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FeatureFlag.self, from: data)
    }

    @Test("writes one condition group and echoes everything else back untouched")
    func setRollout() async throws {
        let controller = FlagToggleController()
        let (client, transport) = client([(200, "{}")])
        let flag = try flag(groups: [
            ["rollout_percentage": 10, "properties": []],
            ["rollout_percentage": 90, "properties": []],
        ])

        await controller.setRollout(25, group: 0, flag: flag, client: client, projectID: 1_001)

        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "PATCH")
        #expect(sent.url.hasSuffix("/api/projects/1001/feature_flags/710301/"))
        // `groups` must be present or the PATCH is silently ignored — 200, flag
        // unchanged.
        #expect(sent.body.contains("\"groups\""))
        // The keys `FlagFilters` does not model, still there.
        #expect(sent.body.contains("early_exit"))
        #expect(sent.body.contains("payloads"))
        // The version, so a concurrent edit is refused rather than clobbered.
        #expect(sent.body.contains("\"version\":1"))

        #expect(controller.effectiveRollout(flag, group: 0) == 25)
        // The other group is untouched, which is the whole reason the write names
        // one — `FeatureFlag.rolloutPercentage` is a `max()` and is not a value
        // anything may write back.
        #expect(controller.effectiveRollout(flag, group: 1) == 90)
        #expect(controller.successCount == 1)
    }

    /// A `filters` PATCH with no `groups` answers 200 with the flag unchanged, so
    /// sending one would look like success. The controller declines instead, and
    /// says why in words a person can act on.
    @Test("sends nothing at all when the flag can't be edited safely")
    func refusesUnsafeEdit() async throws {
        let controller = FlagToggleController()
        let (client, transport) = client([(200, "{}")])
        let bare = try JSONDecoder().decode(
            FeatureFlag.self,
            from: Data(#"{"id":1,"key":"k","active":true}"#.utf8)
        )
        #expect(!bare.canEditRollout)

        await controller.setRollout(25, group: 0, flag: bare, client: client, projectID: 1)

        #expect(await transport.requests.isEmpty)
        #expect(controller.failureCount == 1)
        #expect(try #require(controller.message).text.contains("web console"))
    }

    /// The already-shipped defect, on the write it was reported against.
    @Test("reports an approval-gated flag write as filed, and rolls the flag back")
    func approvalOnToggle() async throws {
        let controller = FlagToggleController()
        let (client, _) = client([(409, approvalBody)])
        let flag = try flag(groups: [["rollout_percentage": 10, "properties": []]])

        await controller.setActive(false, flag: flag, client: client, projectID: 1)

        #expect(controller.effectiveActive(flag))
        #expect(controller.filedCount == 1)
        #expect(controller.failureCount == 0)
        let message = try #require(controller.message)
        #expect(message.kind == .filed)
        #expect(message.text.contains("approval.reviewer@example.com"))
        #expect(!message.text.contains("Couldn't"))
    }

    @Test("rolls a rollout back when somebody else got there first")
    func versionConflict() async throws {
        let controller = FlagToggleController()
        let (client, _) = client([(409, #"{"code":"conflict","detail":"Ada is editing this."}"#)])
        let flag = try flag(groups: [["rollout_percentage": 10, "properties": []]])

        await controller.setRollout(25, group: 0, flag: flag, client: client, projectID: 1)

        #expect(controller.effectiveRollout(flag, group: 0) == 10)
        #expect(controller.failureCount == 1)
        #expect(controller.filedCount == 0)
        let message = try #require(controller.message)
        #expect(message.kind == .failure)
        #expect(message.text.contains("somebody else changed it"))
    }
}

// MARK: - Demo routing

/// The demo answers for the six lifecycle writes, driven through the real
/// `PostHogAPI` builders.
///
/// Through the builders and not through hand-written paths, for
/// `DemoTransportTests`' reason: a literal only proves the transport matches the
/// string the test author typed, while a builder makes a rename in the kit break
/// this file.
@Suite("Demo lifecycle routes")
struct DemoLifecycleRouteTests {

    private func reply(for endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: "https://us.posthog.com" + endpoint.path)!
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        return try await DemoTransport().send(request)
    }

    private func object(for endpoint: Endpoint) async throws -> [String: Any] {
        let (data, response) = try await reply(for: endpoint)
        #expect(response.statusCode == 200)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let projectID = 1_001
    /// The running demo experiment, which is the one with a detail fixture and
    /// therefore the one a pause is ever asked for.
    private static let experimentID = 71_101
    private static let launchedSurvey = "018f9000-0000-7000-8000-000000000107"
    private static let draftSurvey = "018f9000-0000-7000-8000-000000000200"

    @Test("answers an experiment end with the experiment, ended")
    func endExperiment() async throws {
        let body = try await object(
            for: PostHogAPI.endExperiment(
                projectID: Self.projectID,
                experimentID: Self.experimentID,
                conclusion: .won
            )
        )
        #expect(body["id"] as? Int == Self.experimentID)
        #expect(body["status"] as? String == "stopped")
        #expect(body["end_date"] as? String != nil)
    }

    @Test("answers a pause and a resume with the experiment's derived status")
    func pauseResumeExperiment() async throws {
        let paused = try await object(
            for: PostHogAPI.pauseExperiment(projectID: Self.projectID, experimentID: Self.experimentID)
        )
        #expect(paused["id"] as? Int == Self.experimentID)
        #expect(paused["status"] as? String == "paused")
        // Pausing writes nothing on the experiment row, so the end date must not
        // appear — the demo would otherwise be teaching the wrong lesson about
        // which action closes the results window.
        #expect(paused["end_date"] is NSNull || paused["end_date"] == nil)

        let resumed = try await object(
            for: PostHogAPI.resumeExperiment(projectID: Self.projectID, experimentID: Self.experimentID)
        )
        #expect(resumed["status"] as? String == "running")
    }

    /// Matched by id and not served as a first row: the sheet that made the write
    /// is showing one particular survey, and answering with another one's name is
    /// the failure the experiment detail route documents at length.
    @Test("answers each survey action with that survey, dates moved")
    func surveyActions() async throws {
        let stopped = try await object(
            for: PostHogAPI.stopSurvey(projectID: Self.projectID, surveyID: Self.launchedSurvey)
        )
        #expect(stopped["id"] as? String == Self.launchedSurvey)
        #expect(stopped["end_date"] as? String != nil)

        let launched = try await object(
            for: PostHogAPI.launchSurvey(projectID: Self.projectID, surveyID: Self.draftSurvey)
        )
        #expect(launched["id"] as? String == Self.draftSurvey)
        #expect(launched["start_date"] as? String != nil)

        let resumed = try await object(
            for: PostHogAPI.resumeSurvey(projectID: Self.projectID, surveyID: Self.launchedSurvey)
        )
        #expect(resumed["id"] as? String == Self.launchedSurvey)
        #expect(resumed["end_date"] is NSNull)
    }

    /// The one that could only ever have been got wrong by method: `PATCH
    /// /surveys/:id/` is the resume and `GET /surveys/:id/` is a read, and they
    /// are the same path. A route keyed on the path alone would answer the list
    /// to both — which decodes cleanly as a `Page` and would look fine.
    @Test("keeps the survey read on the same path answering the list")
    func readAndWriteSharePathNotAnswer() async throws {
        let (data, response) = try await reply(
            for: PostHogAPI.surveys(projectID: Self.projectID)
        )
        #expect(response.statusCode == 200)
        let page = try JSONDecoder().decode(Page<Survey>.self, from: data)
        #expect(page.results.count > 1)

        // …while the write on a path under it answers one object, not a page.
        let resumed = try await object(
            for: PostHogAPI.resumeSurvey(projectID: Self.projectID, surveyID: Self.launchedSurvey)
        )
        #expect(resumed["results"] == nil)
    }

    /// The flag writes are deliberately unrouted and fall through to the flags
    /// collection, which is what the toggle has always done. Asserted so that
    /// staying unrouted is a decision rather than an oversight — and so a future
    /// route has to update this test rather than silently changing the answer.
    @Test("leaves the flag writes answering the flags collection")
    func flagWritesFallThrough() async throws {
        let flags = try JSONDecoder().decode(
            Page<FeatureFlag>.self,
            from: try await reply(
                for: PostHogAPI.setFlagActive(projectID: Self.projectID, flagID: 700_862, active: false)
            ).0
        )
        #expect(!flags.results.isEmpty)

        // And the rollout builder reaches the same place, which also proves the
        // demo flags decode with the complete authored filters the write needs.
        let flag = try #require(flags.results.first { $0.id == 710_301 })
        #expect(flag.canEditRollout)
        let endpoint = try #require(
            PostHogAPI.setFlagRollout(projectID: Self.projectID, flag: flag, groupIndex: 0, percentage: 25)
        )
        let (_, response) = try await reply(for: endpoint)
        #expect(response.statusCode == 200)
    }

    /// The multi-group flag in the demo data, which is the only place the "there
    /// is no *the* rollout percentage" case is reachable on screen.
    @Test("keeps a two-group demo flag editable per group")
    func multiGroupDemoFlagIsReachable() async throws {
        let flags = try JSONDecoder().decode(
            Page<FeatureFlag>.self,
            from: try await reply(for: PostHogAPI.featureFlags(projectID: Self.projectID)).0
        )
        let multi = try #require(flags.results.first { $0.conditionGroups.count > 1 })
        #expect(multi.canEditRollout)
        #expect(PostHogAPI.setFlagRollout(projectID: 1, flag: multi, groupIndex: 1, percentage: 5) != nil)
        #expect(PostHogAPI.setFlagRollout(projectID: 1, flag: multi, groupIndex: 9, percentage: 5) == nil)
    }
}

// MARK: - What a 403 on a write is allowed to claim

/// Pins `WriteFailure.message` for every shape a 403 can take.
///
/// The defect these exist for: the `.forbidden` case matched *binding nothing*,
/// discarding both of `PostHogError.forbidden`'s associated values — the scope
/// response named, and its authored detail — and asserting `writeScope`, a
/// constant hardcoded at each of four call sites.
///
/// That is wrong in the worst available direction. `missingScope` is nil
/// *precisely when* the 403 is not about a scope, so the sentence was at its most
/// specific exactly where it was least applicable. `ForbiddenDetailTests` in the
/// kit pins the other half: neither 403 documented in README.md carries anything
/// the scope regex can match.
@Suite("Write 403 diagnosis")
struct WriteForbiddenMessageTests {

    private static func message(_ error: PostHogError) -> String {
        WriteFailure.message(
            for: error, object: "Signup flag", action: "pause", writeScope: "feature_flag:write"
        ).text
    }

    /// The one branch entitled to assert a scope: PostHog named it.
    @Test("names the scope PostHog named, not the one the call site guessed")
    func prefersPostHogsOwnScope() {
        let text = Self.message(
            .forbidden(
                missingScope: "experiment:write",
                detail: "You do not have the experiment:write scope."
            )
        )
        // The value that used to be discarded.
        #expect(text.contains("experiment:write"))
        // The call site's guess must not appear when PostHog disagreed with it.
        #expect(!text.contains("feature_flag:write"))
    }

    /// README.md documents this one: `/data_modeling_jobs/recent/` and
    /// `/notebooks/recording_comments/` both answer it. No scope opens these and
    /// no plan upgrade does either, so telling someone to edit their key sends
    /// them to a control that cannot help.
    @Test("a personal-key refusal is not reported as a missing scope")
    func personalKeyRefusalIsNotAScope() {
        let text = Self.message(
            .forbidden(
                missingScope: nil,
                detail: "This action does not support personal API key access"
            )
        )
        #expect(text.contains("personal API key"))
        #expect(!text.contains("feature_flag:write"))
        #expect(!text.lowercased().contains("missing the"))
    }

    /// The second 403 in README.md's table, and a property of the *key* rather
    /// than of the request. Project-scoped credentials are a supported case, so
    /// this response must remain understandable without inferring a scope.
    ///
    /// Nothing classifies it, which is the point: the honest answer is to quote
    /// PostHog and mark the scope as the guess it has always been.
    @Test("an unclassifiable 403 quotes PostHog rather than asserting a cause")
    func unknownRefusalQuotesPostHog() {
        let detail = "API keys with scoped projects are only supported on project-based endpoints."
        let text = Self.message(.forbidden(missingScope: nil, detail: detail))

        // PostHog's own sentence is the only true statement available, so it
        // has to survive rather than being replaced by a guess.
        #expect(text.contains(detail))
        // The guess may still be offered — it is often right — but only as a
        // possibility, never as the diagnosis.
        #expect(text.contains("If your key is missing the feature_flag:write scope"))
        #expect(text.contains("organization admin"))
    }

    /// PostHog-side gating: neither a new key nor an admin can lift it.
    @Test("a feature-flagged product says so instead of blaming the key")
    func featureFlaggedRefusal() {
        let text = Self.message(
            .forbidden(
                missingScope: nil,
                detail: "This requires feature flag 'metrics' to be enabled for your organisation."
            )
        )
        #expect(text.contains("metrics"))
        #expect(text.contains("feature flag"))
        #expect(!text.contains("Add it to the key"))
    }

    /// A 403 with nothing in it at all still has to fall back to something, and
    /// the call site's scope is the best guess available — phrased as a guess.
    @Test("a bare 403 offers the call site's scope as a possibility")
    func bareRefusalFallsBackToTheGuess() {
        let text = Self.message(.forbidden(missingScope: nil, detail: nil))
        #expect(text.contains("feature_flag:write"))
        #expect(text.contains("didn't say which permission"))
    }

    /// Every branch above still has to read as one sentence about this object
    /// and this action, since that is what the message view renders.
    @Test("every 403 message names the action and the object")
    func allMessagesLeadWithTheAction() {
        let details: [String?] = [
            nil,
            "This action does not support personal API key access",
            "API keys with scoped projects are only supported on project-based endpoints.",
            "This requires feature flag 'metrics' to be enabled.",
        ]
        for detail in details {
            let text = Self.message(.forbidden(missingScope: nil, detail: detail))
            #expect(text.hasPrefix("Couldn't pause Signup flag"))
        }
        #expect(
            Self.message(.forbidden(missingScope: "x:write", detail: "needs x:write"))
                .hasPrefix("Couldn't pause Signup flag")
        )
    }

    /// A declined OAuth scope fails identically to a missing key scope but is
    /// fixed in the opposite place. Prescribing key editing would send the
    /// user to a control that cannot help — the grant is widened in Settings.
    @Test("an OAuth denial prescribes Settings, not key editing")
    func oauthDenialPrescribesSettings() {
        let text = WriteFailure.message(
            for: PostHogError.forbidden(
                missingScope: "feature_flag:write",
                detail: "You do not have the feature_flag:write scope."
            ),
            object: "Signup flag",
            action: "pause",
            writeScope: "feature_flag:write",
            remedy: .oauthCloud
        ).text
        #expect(text.contains("feature_flag:write"))
        #expect(text.contains("Settings"))
        #expect(!text.contains("API key"))
    }

    @Test("an OAuth bare 403 guesses the scope with a Settings remedy")
    func oauthBareRefusalGuessesWithSettingsRemedy() {
        let text = WriteFailure.message(
            for: PostHogError.forbidden(missingScope: nil, detail: nil),
            object: "Signup flag",
            action: "pause",
            writeScope: "feature_flag:write",
            remedy: .oauthCloud
        ).text
        #expect(text.contains("feature_flag:write"))
        #expect(text.contains("Settings"))
        #expect(!text.contains("API key"))
    }

    @Test("an OAuth rejection names sign-in expiry")
    func oauthRejectionNamesExpiry() {
        let text = WriteFailure.message(
            for: PostHogError.unauthorized,
            object: "Signup flag",
            action: "pause",
            writeScope: "feature_flag:write",
            remedy: .oauthCloud
        ).text
        #expect(text.contains("sign-in expired"))
        #expect(!text.contains("API key"))
    }
}
