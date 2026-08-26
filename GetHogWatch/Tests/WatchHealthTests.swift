import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch health")
struct WatchHealthTests {

    /// Issues are built through the kit decoder because occurrences live in
    /// aggregations, which preview initializers do not populate.
    private func issues(_ json: String) throws -> [ErrorIssue] {
        try ErrorTrackingResponse.decode(from: Data(json.utf8)).issues
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

        let health = WatchHealth.derive(issues: decoded)

        #expect(health.errorPulse?.activeCount == 2)
        #expect(health.errorPulse?.topIssueName == "ExampleFault")
        #expect(health.errorPulse?.topOccurrences == 29)
    }

    @Test("issues that were never checked are nil, not zero")
    func uncheckedIssuesAreNil() {
        #expect(WatchHealth.derive(issues: nil).errorPulse == nil)
    }

    @Test("a completed healthy check reports zero active issues")
    func healthyCheckReportsZero() {
        #expect(WatchHealth.derive(issues: []).errorPulse?.activeCount == 0)
    }
}
