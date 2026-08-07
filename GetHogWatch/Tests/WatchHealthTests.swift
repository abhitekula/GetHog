import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch health")
struct WatchHealthTests {

    private func metric(
        id: String, value: Double, previous: Double? = nil, title: String = "Example metric"
    ) -> SharedSnapshot.Metric {
        SharedSnapshot.Metric(
            id: id, title: title, value: value, unit: nil,
            previous: previous, sparkline: [], dashboardID: 9001
        )
    }

    private func snapshot(_ metrics: [SharedSnapshot.Metric]) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001, projectName: "Synthetic Analytics",
            metrics: metrics, flags: [], capturedAt: WatchFixtures.now
        )
    }

    /// Issues built through the kit's own decoder rather than its preview
    /// initialiser: `occurrences` lives in `aggregations`, which only the
    /// decoding path fills, and a pulse that tops by occurrences is untestable
    /// against issues whose occurrences are all zero.
    private func issues(_ json: String) throws -> [ErrorIssue] {
        try ErrorTrackingResponse.decode(from: Data(json.utf8)).issues
    }

    @Test("a breached threshold reads as firing, under the metric's current name")
    func breachedWatchFires() {
        let derived = WatchHealth.derive(
            snapshot: snapshot([metric(id: "501", value: 55, title: "Example signups")]),
            watches: [
                MetricWatch(
                    id: "w1", metricID: "501", title: "Name as saved", condition: .above(40)
                ),
            ],
            previouslyBreaching: [],
            issues: nil
        )

        #expect(derived.health.rows.count == 1)
        #expect(derived.health.rows[0].isFiring)
        #expect(derived.health.rows[0].title == "Example signups")
        #expect(derived.health.rows[0].summary == "Above 40")
        #expect(derived.health.firingCount == 1)
        #expect(derived.breaching == ["w1"])
    }

    @Test("an unbreached threshold reads as quiet")
    func unbreachedWatchIsQuiet() {
        let derived = WatchHealth.derive(
            snapshot: snapshot([metric(id: "501", value: 12)]),
            watches: [
                MetricWatch(id: "w1", metricID: "501", title: "Quiet", condition: .above(40)),
            ],
            previouslyBreaching: [],
            issues: nil
        )

        #expect(derived.health.rows.count == 1)
        #expect(!derived.health.rows[0].isFiring)
        #expect(derived.health.firingCount == 0)
        #expect(derived.breaching.isEmpty)
    }

    @Test("a disabled watch is not listed at all")
    func disabledWatchIsExcluded() {
        let derived = WatchHealth.derive(
            snapshot: snapshot([metric(id: "501", value: 55)]),
            watches: [
                MetricWatch(
                    id: "w1", metricID: "501", title: "Paused",
                    condition: .above(40), isEnabled: false
                ),
            ],
            previouslyBreaching: [],
            issues: nil
        )

        #expect(derived.health.rows.isEmpty)
    }

    @Test("a watch whose metric vanished stays latched rather than reading as recovered")
    func missingMetricStaysLatched() {
        let derived = WatchHealth.derive(
            snapshot: snapshot([metric(id: "999", value: 1)]),
            watches: [
                MetricWatch(
                    id: "w1", metricID: "501", title: "Name as saved", condition: .above(40)
                ),
            ],
            previouslyBreaching: ["w1"],
            issues: nil
        )

        #expect(derived.breaching == ["w1"])
        #expect(derived.health.rows[0].isFiring)
        // No metric in the snapshot, so the saved title is all there is.
        #expect(derived.health.rows[0].title == "Name as saved")
    }

    @Test("the error pulse counts only active issues and tops by occurrences")
    func errorPulseCountsActiveOnly() throws {
        let decoded = try issues(#"""
            {"results":[
              {"id":"example-issue-1","name":"ExampleFault","status":"active",
               "aggregations":{"occurrences":29}},
              {"id":"example-issue-2","name":"LouderButResolved","status":"resolved",
               "aggregations":{"occurrences":99}},
              {"id":"example-issue-3","name":"SmallerFault","status":"active",
               "aggregations":{"occurrences":4}}]}
            """#)

        let derived = WatchHealth.derive(
            snapshot: nil, watches: [], previouslyBreaching: [], issues: decoded
        )

        #expect(derived.health.errorPulse?.activeCount == 2)
        #expect(derived.health.errorPulse?.topIssueName == "ExampleFault")
        #expect(derived.health.errorPulse?.topOccurrences == 29)
    }

    @Test("issues that were never checked are nil, not zero, while rows still derive")
    func uncheckedIssuesAreNil() {
        let derived = WatchHealth.derive(
            snapshot: snapshot([metric(id: "501", value: 55)]),
            watches: [
                MetricWatch(id: "w1", metricID: "501", title: "Example", condition: .above(40)),
            ],
            previouslyBreaching: [],
            issues: nil
        )

        #expect(derived.health.errorPulse == nil)
        #expect(derived.health.rows.count == 1)
    }

    @Test("no snapshot leaves the latch exactly as it was found")
    func noSnapshotPreservesTheLatch() {
        let derived = WatchHealth.derive(
            snapshot: nil,
            watches: [
                MetricWatch(id: "w1", metricID: "501", title: "Example", condition: .above(40)),
            ],
            previouslyBreaching: ["w1"],
            issues: nil
        )

        #expect(derived.breaching == ["w1"])
        #expect(derived.health.rows[0].isFiring)
    }
}
