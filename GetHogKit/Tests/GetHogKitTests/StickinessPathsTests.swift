import Foundation
import Testing

@testable import GetHogKit

/// Wraps a captured `/query/` result array in an insight envelope, so these
/// tests exercise the same decode path a real dashboard tile takes.
private func insight(kind: String, resultsFrom fixture: String) throws -> Insight {
    let response = try JSONSerialization.jsonObject(
        with: Fixture.data(fixture)
    ) as! [String: Any]
    let envelope: [String: Any] = [
        "id": 1,
        "name": kind,
        "query": ["kind": "InsightVizNode", "source": ["kind": kind]],
        "result": response["results"] as Any,
    ]
    let data = try JSONSerialization.data(withJSONObject: envelope)
    return try JSONDecoder().decode(Insight.self, from: data)
}

@Suite("Stickiness insights")
struct StickinessTests {

    @Test("decodes N-days-active buckets rather than a time series")
    func decodesBuckets() throws {
        let insight = try insight(kind: "StickinessQuery", resultsFrom: "stickiness.json")

        // `days` here is [1,2,3,4,5,6] — interval COUNTS, not dates. Routing this
        // through the trends path yields an empty chart, because the day strings
        // never parse as dates.
        guard case .stickiness(let series) = insight.renderModel else {
            Issue.record("expected .stickiness, got \(insight.renderModel)")
            return
        }

        let first = try #require(series.first)
        #expect(first.label == "$pageview")
        #expect(first.buckets.count >= 6)
        #expect(first.buckets[0].intervals == 1)
        #expect(first.buckets[0].count == 1007)
        #expect(first.buckets[1].intervals == 2)
        #expect(first.buckets[1].count == 43)
    }

    @Test("decodes integer day labels, which JSON gives as numbers not strings")
    func integerDayLabels() throws {
        // The trends decoder types `days` as [String]; stickiness sends numbers,
        // so a naive decode drops the whole array and silently renders nothing.
        let json = #"""
        {"label":"x","count":3,"data":[2,1],"days":[1,2]}
        """#
        let dto = try JSONDecoder().decode(TrendsSeriesDTO.self, from: Data(json.utf8))
        #expect(dto.dayLabels == ["1", "2"])
    }
}

@Suite("Paths insights")
struct PathsTests {

    @Test("decodes the source/target/value edge list")
    func decodesEdges() throws {
        let insight = try insight(kind: "PathsQuery", resultsFrom: "paths.json")

        guard case .paths(let graph) = insight.renderModel else {
            Issue.record("expected .paths, got \(insight.renderModel)")
            return
        }

        #expect(graph.edges.count == 50)
        let top = try #require(graph.edges.first)
        #expect(top.value > 0)
        #expect(!top.source.isEmpty)
    }

    @Test("strips PostHog's step-index prefix from node names")
    func stripsStepPrefix() throws {
        let insight = try insight(kind: "PathsQuery", resultsFrom: "paths.json")
        guard case .paths(let graph) = insight.renderModel else { return }

        // PostHog prefixes node names with their step number ("2_$web_vitals"),
        // which is layout metadata, not something to show a user.
        #expect(graph.edges.allSatisfy { !$0.source.hasPrefix("1_") })
        #expect(graph.edges.contains { $0.step != nil })
    }

    @Test("ranks edges by traffic so the busiest path reads first")
    func ranksByValue() throws {
        let insight = try insight(kind: "PathsQuery", resultsFrom: "paths.json")
        guard case .paths(let graph) = insight.renderModel else { return }

        let values = graph.edges.map(\.value)
        #expect(values == values.sorted(by: >))
    }
}

@Suite("Plan and access errors")
struct PlanErrorTests {

    @Test("surfaces a 402 as a paid-plan gate, not a generic failure")
    func paymentRequired() async throws {
        let body = try Fixture.string("activity_log_402.json")
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: StubTransport(status: 402, body: body)
        )

        do {
            _ = try await client.data(for: Endpoint(path: "/api/x/", category: .crud))
            Issue.record("expected a paymentRequired error")
        } catch let error as PostHogError {
            guard case .paymentRequired(let detail) = error else {
                Issue.record("expected .paymentRequired, got \(error)")
                return
            }
            // Telling the user to upgrade is actionable; "server error" is not.
            #expect(detail?.contains("paid PostHog plan") == true)
        }
    }

    @Test("recognises a resource access-control failure returned as HTTP 400")
    func accessControlFailure() async throws {
        // PostHog reports missing per-resource access as a 400, not a 403, so a
        // naive handler shows it as a malformed-request bug.
        let body = #"{"type":"validation_error","code":"invalid_input","detail":"Access control failure. You don't have `viewer` access to the `logs` resource."}"#
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: StubTransport(status: 400, body: body)
        )

        do {
            _ = try await client.data(for: Endpoint(path: "/api/x/", category: .query))
            Issue.record("expected an accessDenied error")
        } catch let error as PostHogError {
            guard case .accessDenied(let resource) = error else {
                Issue.record("expected .accessDenied, got \(error)")
                return
            }
            #expect(resource == "logs")
        }
    }
}
