import Foundation
import Testing

@testable import GetHogKit

/// Health issues, signal reports and agent tasks.
///
/// The fixtures exercise documented response shapes and the contracts each screen
/// relies on, including nullable fields and links between reports and tasks.
@Suite("Monitor surface")
struct MonitorModelTests {

    // MARK: - Health issues

    @Test("decodes each issue kind into its own detail")
    func healthIssueKinds() throws {
        let page = try Page<HealthIssue>.decode(from: Fixture.data("health_issues.json"))
        #expect(page.results.count == 8)

        let outdated = try #require(page.results.first { $0.kind == .sdkOutdated })
        guard case .sdkOutdated(let name, let current, let latest) = outdated.detail else {
            Issue.record("expected an sdkOutdated detail, got \(outdated.detail)")
            return
        }
        #expect(!name.isEmpty)
        #expect(!current.isEmpty)
        #expect(!latest.isEmpty)
    }

    /// `payload` is polymorphic keyed by `kind`, exactly like `insight.result`.
    /// A kind this client has never seen must degrade to a card, not throw —
    /// PostHog adds them without asking.
    @Test("survives a health issue kind that does not exist yet")
    func unknownHealthKind() throws {
        let json = """
        {"id": "x", "kind": "asteroid_impact", "severity": "critical",
         "status": "active", "dismissed": false, "payload": {"velocity": 9000}}
        """
        let issue = try JSONDecoder().decode(HealthIssue.self, from: Data(json.utf8))
        #expect(issue.kind == .unknown)
        guard case .unknown(let raw) = issue.detail else {
            Issue.record("expected .unknown, got \(issue.detail)")
            return
        }
        #expect(raw == "asteroid_impact")
        // The severity still has to survive, because that is what decides
        // whether the card is worth interrupting someone for.
        #expect(issue.severity == .critical)
    }

    @Test("ranks active issues above resolved ones, worst first")
    func healthIssueOrdering() throws {
        let page = try Page<HealthIssue>.decode(from: Fixture.data("health_issues.json"))
        let ordered = page.results.sorted(by: HealthIssue.mostUrgentFirst)

        let firstResolvedIndex = ordered.firstIndex { $0.status == .resolved }
        let lastActiveIndex = ordered.lastIndex { $0.status == .active }
        if let firstResolvedIndex, let lastActiveIndex {
            #expect(lastActiveIndex < firstResolvedIndex)
        }
    }

    // MARK: - Signal reports

    @Test("decodes reports, including the ones with no priority at all")
    func signalReportPriority() throws {
        let page = try Page<SignalReport>.decode(from: Fixture.data("signal_reports.json"))
        #expect(page.count == 29)
        #expect(page.results.count == 11)

        let first = try #require(page.results.first)
        #expect(first.id == "018f9000-0000-7000-8000-000000000036")
        #expect(first.title == "Archive export retry storm")
        #expect(first.status == .resolved)
        #expect(first.priority == "P2")
        #expect(first.signalCount == 8)
        #expect(first.sourceProducts == ["error_tracking", "github"])
        #expect(first.implementationPRMerged)

        // A missing priority means the report has not been triaged; decoding it
        // as a made-up low priority would change the product's meaning.
        let untriaged = try #require(page.results.first {
            $0.id == "018f9000-0000-7000-8000-000000000038"
        })
        #expect(untriaged.priority == nil)
        #expect(untriaged.alreadyAddressed == true)
    }

    @Test("keeps every source product, not just the first")
    func signalReportSources() throws {
        let page = try Page<SignalReport>.decode(from: Fixture.data("signal_reports.json"))

        let multiSource = try #require(page.results.first {
            $0.id == "018f9000-0000-7000-8000-000000000041"
        })
        #expect(multiSource.sourceProducts == ["session_replay", "github"])
    }

    @Test("decodes every status the documented API returns")
    func signalReportStatuses() throws {
        let page = try Page<SignalReport>.decode(from: Fixture.data("signal_reports.json"))
        #expect(Set(page.results.map(\.status)) == [
            .potential, .ready, .inProgress, .resolved, .failed,
        ])
    }

    // MARK: - Tasks

    @Test("decodes agent-filed tasks with their embedded run state")
    func taskDecoding() throws {
        let page = try Page<AgentTask>.decode(from: Fixture.data("tasks.json"))
        #expect(page.count == 26)
        #expect(page.results.count == 26)

        // `latest_run` is embedded in the list response, so run state costs no
        // second request per row.
        let first = try #require(page.results.first)
        #expect(first.id == "018f9000-0000-7000-8000-000000000066")
        #expect(first.title == "Stabilize archive export retries")
        #expect(first.taskNumber == 401)
        #expect(first.originProduct == "signal_report")
        #expect(first.repository == "example-labs/nebula")
        #expect(first.latestRun?.status == "completed")
        #expect(first.latestRun?.branch == "fix/archive-export-retries")
        #expect(first.latestRun?.completedAt == PostHogDate.parse("2026-01-01T12:45:00Z"))
    }

    @Test("tolerates a task with no repository")
    func taskWithoutRepository() throws {
        let page = try Page<AgentTask>.decode(from: Fixture.data("tasks.json"))
        let scout = try #require(page.results.first {
            $0.id == "018f9000-0000-7000-8000-000000000067"
        })
        #expect(scout.repository == nil)
        #expect(scout.originProduct == "signals_scout")
    }

    /// Scout-filed tasks store their whole prompt as the title, prefixed with a
    /// bracketed internal identifier:
    ///
    ///     [sandbox_prompt:signals_scout:signals-scout-feature-flags] Review the
    ///     fixture application's flag behavior.
    ///
    /// Rendered raw, every scout row reads as the same wall of boilerplate and
    /// the one useful fact — which scout ran — is the part that gets truncated
    /// away.
    @Test("recovers which scout ran from a prompt-shaped title")
    func scoutTaskDisplayTitle() throws {
        let page = try Page<AgentTask>.decode(from: Fixture.data("tasks.json"))
        let scoutTasks = page.results.filter { $0.signalReportID == nil }
        #expect(scoutTasks.count == 13)

        let featureFlagsScout = try #require(scoutTasks.first {
            $0.id == "018f9000-0000-7000-8000-000000000067"
        })
        #expect(featureFlagsScout.scoutName == "signals-scout-feature-flags")
        #expect(featureFlagsScout.displayTitle == "Feature flags scout")

        for task in scoutTasks {
            #expect(!task.displayTitle.hasPrefix("["))
            #expect(!task.displayTitle.contains("sandbox_prompt"))
            #expect(!task.displayTitle.contains("You are a"))
            #expect(!task.displayTitle.isEmpty)
        }
    }

    @Test("humanises the scout identifier without inventing one")
    func scoutNameHumanising() throws {
        let json = """
        {"id": "1", "title": "[sandbox_prompt:signals_scout:signals-scout-feature-flags] \
        Review the fixture application's flag behavior."}
        """
        let task = try JSONDecoder().decode(AgentTask.self, from: Data(json.utf8))
        #expect(task.displayTitle == "Feature flags scout")
        // The raw identifier is still worth showing — it is what the row's
        // subtitle uses — so it must survive the tidying rather than be lost.
        #expect(task.scoutName == "signals-scout-feature-flags")
    }

    @Test("leaves a real title completely alone")
    func realTitleUntouched() throws {
        let json = """
        {"id": "2", "title": "Improve export scheduling telemetry"}
        """
        let task = try JSONDecoder().decode(AgentTask.self, from: Data(json.utf8))
        // Report-filed tasks already carry a written title. Running the
        // bracket-stripping over one of those would be a regression.
        #expect(task.displayTitle == "Improve export scheduling telemetry")
        #expect(task.scoutName == nil)
    }

    @Test("links a task back to the signal report that filed it")
    func taskSignalReportLink() throws {
        let taskPage = try Page<AgentTask>.decode(from: Fixture.data("tasks.json"))
        let reportPage = try Page<SignalReport>.decode(from: Fixture.data("signal_reports.json"))
        let reportIDs = Set(reportPage.results.map(\.id))
        let reportTasks = taskPage.results.filter { $0.signalReportID != nil }

        #expect(reportTasks.count == 13)
        #expect(reportTasks.allSatisfy { task in
            task.signalReportID.map(reportIDs.contains) == true
        })
        #expect(reportTasks.first?.signalReportID == "018f9000-0000-7000-8000-000000000036")
    }
}
