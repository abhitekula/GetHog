import Foundation
import Testing

@testable import GetHogKit

@Suite("Web Vitals")
struct WebVitalsTests {
    @Test("synthetic fixture uses authored path buckets")
    func syntheticFixturePathBuckets() throws {
        let breakdown = try WebVitalsBreakdown.decode(from: Fixture.data("web_vitals.json"))

        #expect(breakdown.good.map(\.path) == ["/launchpad", "/docs/start", "/pricing"])
        #expect(breakdown.needsImprovement.map(\.path) == ["/workbench", "/catalog"])
        #expect(breakdown.poor.map(\.path) == ["/checkout", "/reports"])
        #expect(breakdown.allEntries.count == 7)
    }


    @Test("decodes the good / needs-improvement / poor buckets")
    func decodesBuckets() throws {
        let breakdown = try WebVitalsBreakdown.decode(from: Fixture.data("web_vitals.json"))

        #expect(!breakdown.good.isEmpty)
        let first = try #require(breakdown.good.first)
        #expect(first.path.hasPrefix("/"))
        #expect(first.value > 0)
    }

    @Test("classifies each bucket so the band is never inferred from colour")
    func bandsAreExplicit() throws {
        let breakdown = try WebVitalsBreakdown.decode(from: Fixture.data("web_vitals.json"))
        let entries = breakdown.allEntries

        #expect(entries.allSatisfy { $0.band != nil })
        #expect(entries.contains { $0.band == .good })
    }

    @Test("orders bands worst-first, because poor pages are the ones to act on")
    func worstFirst() throws {
        let breakdown = try WebVitalsBreakdown.decode(from: Fixture.data("web_vitals.json"))
        let bands = breakdown.allEntries.compactMap(\.band)

        // Once a `.good` entry appears, nothing worse may follow it.
        if let firstGood = bands.firstIndex(of: .good) {
            #expect(!bands[firstGood...].contains { $0 != .good })
        }
    }

    @Test("reports an empty breakdown without crashing")
    func emptyBreakdown() throws {
        let empty = Data(#"{"results":[{"good":[],"needs_improvements":[],"poor":[]}]}"#.utf8)
        let breakdown = try WebVitalsBreakdown.decode(from: empty)
        #expect(breakdown.allEntries.isEmpty)
    }
}

@Suite("Tier 3 endpoints")
struct Tier3EndpointTests {

    @Test("builds a web vitals breakdown query for a named metric")
    func webVitals() throws {
        let endpoint = PostHogAPI.webVitals(projectID: 1, metric: "LCP", dateFrom: "-7d")
        let body = String(decoding: try #require(endpoint.body), as: UTF8.self)

        #expect(body.contains("WebVitalsPathBreakdownQuery"))
        #expect(body.contains("LCP"))
        // The API rejects the query without thresholds and a percentile.
        #expect(body.contains("thresholds"))
        #expect(body.contains("percentile"))
    }

    @Test("carries the right thresholds per metric, since they differ by metric")
    func metricThresholds() throws {
        // Google's Core Web Vitals thresholds are metric-specific; reusing LCP's
        // for CLS would mislabel almost every page as good.
        #expect(WebVitalMetric.lcp.thresholds == [2500, 4000])
        #expect(WebVitalMetric.cls.thresholds == [0.1, 0.25])
        #expect(WebVitalMetric.inp.thresholds == [200, 500])
        #expect(WebVitalMetric.fcp.thresholds == [1800, 3000])
    }

    @Test("builds marketing analytics and logs endpoints")
    func otherEndpoints() throws {
        let marketing = PostHogAPI.marketingAnalytics(projectID: 42, dateFrom: "-30d")
        #expect(String(decoding: try #require(marketing.body), as: UTF8.self)
            .contains("MarketingAnalyticsTableQuery"))

        let logs = PostHogAPI.logs(projectID: 42, dateFrom: "-24h")
        #expect(String(decoding: try #require(logs.body), as: UTF8.self).contains("LogsQuery"))
    }
}
