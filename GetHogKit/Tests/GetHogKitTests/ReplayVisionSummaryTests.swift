import Foundation
import Testing

@testable import GetHogKit

@Suite("Replay Vision summaries")
struct ReplayVisionSummaryTests {
    @Test("inline summary scans use the current Replay Vision endpoint and authored config")
    func inlineScanEndpoint() throws {
        let endpoint = PostHogAPI.generateReplayVisionSummary(
            projectID: 1_001,
            sessionID: "session-example-001"
        )

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1001/vision/scanners/inline_scan/")
        #expect(endpoint.category == .query)

        let body = try #require(endpoint.body)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["scanner_type"] as? String == "summarizer")
        #expect(json["session_ids"] as? [String] == ["session-example-001"])
        #expect(
            json["prompt"] as? String
                == "Summarize what the user did in this session: which pages they visited, what they tried to accomplish, and any notable moments like errors, confusion, or successful completions. Be concrete and don't speculate."
        )
        #expect((json["scanner_config"] as? [String: String]) == ["length": "medium"])
    }

    @Test("observation endpoints use the session-scoped current routes")
    func observationEndpoints() {
        let list = PostHogAPI.replayVisionObservations(
            projectID: 1_001,
            sessionID: "session/example"
        )
        #expect(list.path == "/api/projects/1001/vision/observations/")
        #expect(list.query == [
            URLQueryItem(name: "session_id", value: "session/example"),
            URLQueryItem(name: "order_by", value: "-created_at"),
            URLQueryItem(name: "limit", value: "50"),
        ])
        #expect(list.category == .crud)

        let scannerList = PostHogAPI.replayVisionScannerObservations(
            projectID: 1_001,
            scannerID: "scanner-example-001",
            sessionID: "session/example"
        )
        #expect(
            scannerList.path
                == "/api/projects/1001/vision/scanners/scanner-example-001/observations/"
        )
        #expect(
            scannerList.query
                == [
                    URLQueryItem(name: "session_id", value: "session/example"),
                    URLQueryItem(name: "order_by", value: "-created_at"),
                    URLQueryItem(name: "limit", value: "1"),
                ]
        )
        #expect(scannerList.category == .crud)

        let retry = PostHogAPI.retryReplayVisionObservation(
            projectID: 1_001,
            observationID: "observation-example-001"
        )
        #expect(retry.method == "POST")
        #expect(
            retry.path
                == "/api/projects/1001/vision/observations/observation-example-001/retry/"
        )
        #expect(retry.category == .query)
    }

    @Test("decodes a succeeded summarizer observation and its citation segments")
    func observationDecodes() throws {
        let data = Data(#"""
        {
          "count": 1,
          "next": null,
          "previous": null,
          "results": [{
            "id": "018f1000-0000-7000-8000-000000000010",
            "scanner_id": "018f1000-0000-7000-8000-000000000011",
            "session_id": "session-example-001",
            "status": "succeeded",
            "error_reason": "",
            "workflow_id": "replay-vision-example",
            "scanner_snapshot": {
              "name": "",
              "scanner_type": "summarizer",
              "scanner_version": 1,
              "model": "gemini-3-flash-preview",
              "provider": "google",
              "emits_signals": false,
              "scanner_config": {"prompt": "Synthetic prompt", "length": "medium"}
            },
            "scanner_result": {
              "model_output": {
                "scanner_type": "summarizer",
                "title": "Reviewed the fictional dashboard",
                "summary": "The user opened the dashboard and refreshed its widgets.",
                "summary_segments": [
                  {"kind": "text", "value": "Opened the dashboard "},
                  {"kind": "chip", "timestamp_ms": 4200}
                ],
                "intent": "Review current dashboard metrics.",
                "outcome": "The widgets refreshed successfully.",
                "friction_points": ["slow widget refresh"],
                "keywords": ["dashboard", "refreshed"],
                "confidence": 0.9
              },
              "signals_count": 0
            },
            "triggered_by": "on_demand",
            "triggered_by_user": null,
            "backfill_id": null,
            "distinct_id": "synthetic-person-001",
            "recording_subject_email": "alex@example.com",
            "previous_observation_id": null,
            "next_observation_id": null,
            "label": null,
            "started_at": "2026-08-26T10:00:00Z",
            "completed_at": "2026-08-26T10:00:12Z",
            "created_at": "2026-08-26T10:00:00Z"
          }]
        }
        """#.utf8)

        let page = try Page<ReplayVisionObservation>.decode(from: data)
        let observation = try #require(page.results.first)
        let summary = try #require(observation.summary)

        #expect(observation.status == .succeeded)
        #expect(observation.isSummarizer)
        #expect(summary.title == "Reviewed the fictional dashboard")
        #expect(summary.frictionPoints == ["slow widget refresh"])
        #expect(summary.hasFriction)
        #expect(summary.citationOffsets == [4.2])
        #expect(observation.completedAt != nil)
    }

    @Test("unknown observation states remain inspectable instead of failing decoding")
    func unknownStatusDecodes() throws {
        let data = Data(#"""
        {
          "id": "observation-example-unknown",
          "scanner_id": "scanner-example-unknown",
          "session_id": "session-example-unknown",
          "status": "settling",
          "scanner_snapshot": {"scanner_type": "summarizer"},
          "scanner_result": null
        }
        """#.utf8)

        let observation = try JSONDecoder().decode(ReplayVisionObservation.self, from: data)
        #expect(observation.status == .unknown("settling"))
        #expect(observation.summary == nil)
    }

    @Test("inline scan outcomes decode partial success without inventing a result")
    func inlineResponseDecodes() throws {
        let data = Data(#"""
        {
          "scan_id": null,
          "started": 0,
          "results": [{
            "session_id": "session-example-001",
            "scan_outcome": "skipped_quota"
          }]
        }
        """#.utf8)

        let response = try JSONDecoder().decode(ReplayVisionInlineScanResponse.self, from: data)
        #expect(response.scanID == nil)
        #expect(response.started == 0)
        #expect(response.results.first?.outcome == .skippedQuota)
    }

    @Test("summary digests decode the latest event fields and JSON friction arrays")
    func digestRowsDecode() throws {
        let response = try QueryResponse.decode(from: Data(#"""
        {
          "columns": [
            "session_id", "title", "summary", "intent", "outcome",
            "friction_points", "confidence", "model", "completed_at"
          ],
          "results": [[
            "session-example-001",
            "Reviewed the fictional dashboard",
            "The user opened the dashboard and refreshed its widgets.",
            "Review current dashboard metrics.",
            "The widgets refreshed successfully.",
            "[\"slow widget refresh\",\"confusing filter\"]",
            0.9,
            "gemini-3-flash-preview",
            "2026-08-26T10:00:12Z"
          ]]
        }
        """#.utf8))

        let digest = try #require(ReplayVisionSummaryDigest.rows(from: response).first)
        #expect(digest.id == "session-example-001")
        #expect(
            digest.cardSummary
                == "The user opened the dashboard and refreshed its widgets."
        )
        #expect(digest.frictionPoints == ["slow widget refresh", "confusing filter"])
        #expect(digest.hasFriction)
        #expect(digest.completedAt != nil)
    }

    @Test("summary digest queries batch session ids and select only summarizer events")
    func digestEndpointBatchesSessions() throws {
        let endpoint = PostHogAPI.replayVisionSummaryDigests(
            projectID: 1_001,
            sessionIDs: ["plain", "quoted'id"],
            limit: 50
        )
        let body = try #require(endpoint.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try #require((json["query"] as? [String: Any])?["query"] as? String)

        #expect(query.contains("event = '$recording_observed'"))
        #expect(query.contains("properties.scanner_type = 'summarizer'"))
        #expect(query.contains("properties.session_id IN ('plain', 'quoted\\'id')"))
        #expect(query.contains("LIMIT 50"))
    }
}
