import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// Replays scripted HTTP responses so a triage write can be tested without a
/// network. The tests pin the request, optimistic state, and rollback entirely
/// with deterministic fictional values.
private actor ScriptedTransport: HTTPTransport {
    private var responses: [(Int, String)]
    private(set) var requests: [(method: String, path: String, body: String)] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(
            (
                method: request.httpMethod ?? "",
                // `absoluteString`, deliberately **not** `url.path`.
                //
                // `URL.path` is the legacy accessor and it strips a trailing
                // slash: a request whose `absoluteString` ends in a slash can
                // report a `.path` without it. Every
                // PostHog write path ends in a slash and Django cares — a
                // missing one is a 301 at best. Asserting through `.path` would
                // have quietly pinned the wrong shape while the app sent the
                // right one, which is worse than either being wrong on its own.
                path: request.url?.absoluteString ?? "",
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

private func issue(
    id: String = "018f3300-0000-7000-8000-000000000901",
    status: String = "active",
    assignee: ErrorIssueAssignee? = nil
) -> ErrorIssue {
    ErrorIssue(
        id: id,
        name: "HarborRenderFault",
        issueDescription: "Harbor card state was unavailable.",
        status: status,
        firstSeen: Date(timeIntervalSince1970: 1_779_000_000),
        lastSeen: Date(timeIntervalSince1970: 1_784_000_000),
        assignee: assignee
    )
}

@MainActor
@Suite("Error triage writes")
struct ErrorTriageTests {

    private func client(_ responses: [(Int, String)]) -> (PostHogClient, ScriptedTransport) {
        let transport = ScriptedTransport(responses)
        return (PostHogClient(auth: StaticAuth(), transport: transport), transport)
    }

    // MARK: - The happy path

    @Test("sends one PATCH carrying only the status, and keeps the new status")
    func resolveSendsStatusOnly() async throws {
        let (client, transport) = client([(200, "{}")])
        let controller = ErrorTriageController()
        let target = issue()

        await controller.setStatus(.resolved, issue: target, client: client, projectID: 1_001)

        let requests = await transport.requests
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent.method == "PATCH")
        #expect(
            sent.path
                == "https://us.posthog.com/api/projects/1001/error_tracking/issues/018f3300-0000-7000-8000-000000000901/"
        )
        #expect(sent.body.contains("\"status\":\"resolved\""))

        #expect(controller.effectiveStatus(target) == "resolved")
        #expect(controller.effective(target).isResolved)
        #expect(controller.successCount == 1)
        #expect(!controller.isBusy(target))
    }

    /// Resolving is not final, and the app says so *after* the fact as well as
    /// before it. PostHog reopens a resolved issue by itself when it recurs, and
    /// someone who resolved it from a phone will not be watching the list.
    @Test("says out loud that a resolved issue can reopen itself")
    func resolveExplainsAutoReopen() async throws {
        let (client, _) = client([(200, "{}")])
        let controller = ErrorTriageController()

        await controller.setStatus(.resolved, issue: issue(), client: client, projectID: 1)

        let message = try #require(controller.message)
        #expect(message.kind == .notice)
        #expect(message.text.lowercased().contains("automatically"))
    }

    @Test("suppresses through the same endpoint with the suppressed status")
    func suppressSendsSuppressed() async throws {
        let (client, transport) = client([(200, "{}")])
        let controller = ErrorTriageController()

        await controller.setStatus(.suppressed, issue: issue(), client: client, projectID: 1)

        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "PATCH")
        #expect(sent.body.contains("\"status\":\"suppressed\""))
        #expect(controller.effective(issue()).isSuppressed)
    }

    @Test("assigns to a user id on the assign sub-resource")
    func assignSendsUserID() async throws {
        let (client, transport) = client([(200, "{}")])
        let controller = ErrorTriageController()
        let target = issue()

        await controller.setAssignee(.user(710_001), issue: target, client: client, projectID: 1)

        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "PATCH")
        #expect(sent.path.hasSuffix("/assign/"))
        #expect(sent.body.contains("\"id\":710001"))
        #expect(sent.body.contains("\"type\":\"user\""))
        #expect(controller.effectiveAssignee(target) == .user(710_001))
    }

    /// Unassigning is a write whose result is "nobody". The override has to be
    /// able to say that, which is why it is a nested optional — a plain `nil`
    /// would be indistinguishable from having written nothing, and the screen
    /// would fall back to showing the old assignee.
    @Test("clearing an assignee shows unassigned rather than the previous owner")
    func unassignOverridesRatherThanFallingBack() async throws {
        let (client, transport) = client([(200, "{}")])
        let controller = ErrorTriageController()
        let target = issue(assignee: .user(1))

        await controller.setAssignee(nil, issue: target, client: client, projectID: 1)

        #expect(try #require(await transport.requests.first).body.contains("\"assignee\":null"))
        #expect(controller.effectiveAssignee(target) == nil)
        #expect(controller.effective(target).assignee == nil)
    }

    // MARK: - Rollback

    /// The property the whole optimistic scheme rests on. A refused write must
    /// leave the screen showing what the server still believes, not what the
    /// user asked for.
    @Test("rolls the status back when PostHog refuses the write")
    func rollsBackOnFailure() async throws {
        let (client, _) = client([(403, #"{"detail":"nope"}"#)])
        let controller = ErrorTriageController()
        let target = issue()

        await controller.setStatus(.resolved, issue: target, client: client, projectID: 1)

        #expect(controller.effectiveStatus(target) == "active")
        #expect(controller.effective(target).isResolved == false)
        #expect(controller.failureCount == 1)
        #expect(controller.successCount == 0)
    }

    @Test("rolls an assignment back to the assignee the server last reported")
    func rollsAssignmentBack() async throws {
        let (client, _) = client([(500, "{}")])
        let controller = ErrorTriageController()
        let target = issue(assignee: .user(7))

        await controller.setAssignee(.user(99), issue: target, client: client, projectID: 1)

        #expect(controller.effectiveAssignee(target) == .user(7))
        #expect(controller.failureCount == 1)
    }

    /// A read-scoped key passes every capability probe — error tracking is gated
    /// on `query:read`, which it has — and fails only at the write. This is the
    /// first and only moment the user can be told what to tick.
    @Test("names the missing write scope on a 403")
    func namesTheWriteScope() async throws {
        let (client, _) = client([(403, #"{"detail":"forbidden"}"#)])
        let controller = ErrorTriageController()

        await controller.setStatus(.suppressed, issue: issue(), client: client, projectID: 1)

        let message = try #require(controller.message)
        #expect(message.kind == .failure)
        #expect(message.text.contains("error_tracking:write"))
        #expect(message.text.contains("suppress"))
    }

    @Test("tells the user to reconnect on a 401 rather than blaming a scope")
    func unauthorizedIsNotAScopeProblem() async throws {
        let (client, _) = client([(401, "{}")])
        let controller = ErrorTriageController()

        await controller.setStatus(.resolved, issue: issue(), client: client, projectID: 1)

        let message = try #require(controller.message)
        #expect(message.text.contains("Reconnect"))
        #expect(!message.text.contains("error_tracking:write"))
    }

    // MARK: - Reconciliation

    /// Whoever changed the issue in the web console wins. A local override that
    /// outlives its own write would quietly misreport the shared state — the
    /// same rule `FlagToggleController.reconcile` follows.
    @Test("a fresh page from the server clears a settled override")
    func refreshClearsOverrides() async throws {
        let (client, _) = client([(200, "{}")])
        let controller = ErrorTriageController()
        let target = issue()

        await controller.setStatus(.resolved, issue: target, client: client, projectID: 1)
        #expect(controller.effectiveStatus(target) == "resolved")

        // The server still says active — someone reopened it elsewhere.
        controller.reconcile(with: [issue(status: "active")])
        #expect(controller.effectiveStatus(target) == "active")
    }

    @Test("a refresh that didn't mention an issue leaves its override alone")
    func refreshIgnoresUnrelatedIssues() async throws {
        let (client, _) = client([(200, "{}")])
        let controller = ErrorTriageController()
        let target = issue()

        await controller.setStatus(.resolved, issue: target, client: client, projectID: 1)
        controller.reconcile(with: [issue(id: "some-other-issue")])

        #expect(controller.effectiveStatus(target) == "resolved")
    }

    // MARK: - Guards

    @Test("a second write while one is in flight is dropped, not queued")
    func doesNotDoubleWrite() async throws {
        // One response only: a second request would exhaust the stub and throw,
        // which is exactly what this asserts does not happen.
        let (client, transport) = client([(200, "{}")])
        let controller = ErrorTriageController()
        let target = issue()

        async let first: Void = controller.setStatus(
            .resolved, issue: target, client: client, projectID: 1
        )
        async let second: Void = controller.setStatus(
            .suppressed, issue: target, client: client, projectID: 1
        )
        _ = await (first, second)

        #expect(await transport.requests.count == 1)
    }

    // MARK: - The stack-trace query window

    /// The window has to contain the issue's own events or the query cannot find
    /// the frames it exists to fetch.
    @Test("bounds the stack query to the issue's own lifetime")
    func stackWindowSpansTheIssue() {
        let target = issue()
        let window = ExceptionStackStore.window(for: target)
        #expect(window.lowerBound == target.firstSeen)
        #expect(window.upperBound == target.lastSeen)
    }

    /// An issue with no `last_seen` is not a reason to build a backwards range —
    /// `ClosedRange` traps on `lower > upper`, which would be a crash on a screen
    /// reached from a deep link.
    @Test("never builds an inverted window when the timestamps are missing")
    func stackWindowSurvivesMissingTimestamps() {
        let bare = ErrorIssue(id: "i", name: "Error")
        let window = ExceptionStackStore.window(for: bare)
        #expect(window.lowerBound <= window.upperBound)

        let inverted = ErrorIssue(
            id: "i",
            name: "Error",
            firstSeen: Date(timeIntervalSince1970: 2_000_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let repaired = ExceptionStackStore.window(for: inverted)
        #expect(repaired.lowerBound <= repaired.upperBound)
    }
}

@Suite("Error issue status presentation")
struct ErrorIssueStatusPresentationTests {

    /// PostHog reports five statuses, two of which are snake_case.
    /// `"pending_release".capitalized` is `"Pending_release"` — a database column
    /// shown to a user.
    @Test("spells every reported status as words")
    func statusTitles() {
        #expect(issue(status: "active").statusTitle == "Active")
        #expect(issue(status: "resolved").statusTitle == "Resolved")
        #expect(issue(status: "suppressed").statusTitle == "Suppressed")
        #expect(issue(status: "archived").statusTitle == "Archived")
        #expect(issue(status: "pending_release").statusTitle == "Pending release")
    }

    @Test("falls back rather than showing nothing for an unknown status")
    func unknownStatus() {
        #expect(issue(status: "quarantined").statusTitle == "Quarantined")
        #expect(issue(status: "").statusTitle == "Unknown")
    }

    /// The status filter is what the Errors list is read through, and the two
    /// deprecated statuses must not silently vanish from every one of its tabs.
    @Test("treats archived and pending-release as neither resolved nor suppressed")
    func deprecatedStatusesStayVisible() {
        for status in ["archived", "pending_release"] {
            let target = issue(status: status)
            #expect(!target.isResolved)
            #expect(!target.isSuppressed)
            // So they land in "Active", which is the only tab that can show them.
            #expect(ErrorIssueFilter.active.matches(target))
        }
    }
}
