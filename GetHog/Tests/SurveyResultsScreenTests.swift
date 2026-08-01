import Foundation
import GetHogKit
import Testing

@testable import GetHog

// The counts, ratings, choice labels, and free-text answers below form one
// authored fictional survey contract. They are deterministic and contain no
// customer response data.

/// Answers the two survey-results queries, recording the SQL each one carried.
private actor SurveyQueryTransport: HTTPTransport {
    private(set) var bodies: [String] = []
    private let summary: String
    private let answers: String
    private let status: Int

    init(summary: String, answers: String, status: Int = 200) {
        self.summary = summary
        self.answers = answers
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let sql = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        bodies.append(sql)
        let payload = sql.contains("AS impressions") ? summary : answers
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(payload.utf8), response)
    }
}

private func client(_ transport: some HTTPTransport) -> PostHogClient {
    PostHogClient(
        auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
        transport: transport
    )
}

private func survey(
    startDate: String? = "2026-01-10T00:00:00Z",
    questions: String = """
    [{"id": "q-rating", "type": "rating", "scale": 5, "question": "How was it?",
      "lowerBoundLabel": "Poor", "upperBoundLabel": "Great"},
     {"id": "q-open", "type": "open", "question": "Why?"}]
    """
) -> Survey {
    let json = """
    {"id": "survey-1", "name": "Test survey", "type": "popover", "archived": false,
     "start_date": \(startDate.map { "\"\($0)\"" } ?? "null"),
     "questions": \(questions)}
    """
    return try! JSONDecoder().decode(Survey.self, from: Data(json.utf8))
}

private let summaryPayload = """
{"columns": ["impressions", "responses", "dismissals", "abandonments", "partials", "first_seen", "last_seen"],
 "results": [[8, 2, 2, 0, 1, "2026-01-10T09:00:00.000000Z", "2026-01-12T15:30:00.000000Z"]]}
"""

private let answersPayload = """
{"columns": ["submission", "timestamp", "event", "q0", "q1"],
 "results": [
   ["s1", "2026-01-12T15:30:00.000000Z", "survey dismissed", "2", "Navigation labels were unclear."],
   ["s2", "2026-01-12T11:15:00.000000Z", "survey dismissed", "3", "Search results loaded out of order."],
   ["s3", "2026-01-11T14:45:00.000000Z", "survey sent", "5", "The example flow was easy to follow."],
   ["s4", "2026-01-10T09:05:00.000000Z", "survey sent", "4", "Export completed successfully."]]}
"""

private let emptyAnswersPayload = """
{"columns": ["submission", "timestamp", "event", "q0", "q1"], "results": []}
"""

@Suite("Survey results screen")
@MainActor
struct SurveyResultsScreenTests {

    @Test("issues both queries together and reads a measured result")
    func loadsResults() async throws {
        let transport = SurveyQueryTransport(summary: summaryPayload, answers: answersPayload)
        let store = SurveyResultsStore()

        await store.load(client: client(transport), projectID: 1, survey: survey())

        let bodies = await transport.bodies
        #expect(bodies.count == 2)
        #expect(bodies.contains { $0.contains("AS impressions") })
        #expect(bodies.contains { $0.contains("getSurveyResponse(0, ") })

        guard case .measured(let results)? = store.state else {
            Issue.record("expected measured, got \(String(describing: store.state))"); return
        }
        #expect(results.summary.impressions == 8)
        #expect(results.summary.responses == 2)
        #expect(store.failure == nil)
    }

    /// Partial answers contribute to the breakdown even when the survey event
    /// was dismissed rather than sent.
    @Test("aggregates partial answers rather than only completed responses")
    func partialsReachTheBreakdown() async throws {
        let transport = SurveyQueryTransport(summary: summaryPayload, answers: answersPayload)
        let store = SurveyResultsStore()

        await store.load(client: client(transport), projectID: 1, survey: survey())

        guard case .measured(let results)? = store.state,
              case .rating(let rating) = results.questions[0].breakdown
        else {
            Issue.record("expected a rating breakdown"); return
        }
        #expect(results.questions[0].answered == 4)
        #expect(abs(rating.mean - 3.5) < 0.0001)
        #expect(results.summary.responses == 2)
    }

    @Test("a survey that never launched is answered without spending a query")
    func neverLaunchedSkipsTheQuery() async throws {
        let transport = SurveyQueryTransport(summary: summaryPayload, answers: answersPayload)
        let store = SurveyResultsStore()

        await store.load(client: client(transport), projectID: 1, survey: survey(startDate: nil))

        #expect(await transport.bodies.isEmpty)
        #expect(store.state == .notLaunched)
        #expect(store.loadedAt != nil)
    }

    @Test("shown and never answered is its own state, not an empty one")
    func shownButUnanswered() async throws {
        let transport = SurveyQueryTransport(
            summary: """
            {"columns": ["impressions", "responses", "dismissals", "abandonments", "partials"],
             "results": [[8, 0, 2, 0, 0]]}
            """,
            answers: emptyAnswersPayload
        )
        let store = SurveyResultsStore()

        await store.load(client: client(transport), projectID: 1, survey: survey())

        guard case .shownButUnanswered(let summary)? = store.state else {
            Issue.record("expected shownButUnanswered, got \(String(describing: store.state))"); return
        }
        #expect(summary.impressions == 8)
    }

    @Test("a launched survey with no events reads as no activity")
    func noActivity() async throws {
        let transport = SurveyQueryTransport(
            summary: """
            {"columns": ["impressions", "responses", "dismissals", "abandonments", "partials"],
             "results": [[0, 0, 0, 0, 0]]}
            """,
            answers: emptyAnswersPayload
        )
        let store = SurveyResultsStore()

        await store.load(client: client(transport), projectID: 1, survey: survey())

        guard case .noActivity? = store.state else {
            Issue.record("expected noActivity, got \(String(describing: store.state))"); return
        }
    }

    @Test("a failed query surfaces as a failure, not as an empty survey")
    func failureIsNotEmptiness() async throws {
        let transport = SurveyQueryTransport(
            summary: #"{"type":"server_error","detail":"Query exceeded memory limits"}"#,
            answers: emptyAnswersPayload,
            status: 400
        )
        let store = SurveyResultsStore()

        await store.load(client: client(transport), projectID: 1, survey: survey())

        #expect(store.state == nil)
        #expect(store.failure != nil)
    }

    @Test("a 5-point rating shows no NPS score and says why")
    func noScoreOnAFivePointScale() async throws {
        let transport = SurveyQueryTransport(summary: summaryPayload, answers: answersPayload)
        let store = SurveyResultsStore()

        await store.load(client: client(transport), projectID: 1, survey: survey())

        guard case .measured(let results)? = store.state,
              case .rating(let rating) = results.questions[0].breakdown
        else {
            Issue.record("expected a rating breakdown"); return
        }
        #expect(rating.netPromoter == nil)
        #expect(rating.netPromoterAbsence?.contains("0–10") == true)
    }

    @Test("a question type the app can't total up says so instead of drawing nothing")
    func unsupportedQuestionType() async throws {
        let transport = SurveyQueryTransport(
            summary: summaryPayload,
            answers: """
            {"columns": ["submission", "timestamp", "event", "q0"], "results":
              [["s1", "2026-05-08T02:05:06.836000Z", "survey sent", "clicked"]]}
            """
        )
        let store = SurveyResultsStore()

        await store.load(
            client: client(transport),
            projectID: 1,
            survey: survey(questions: #"[{"id": "q-link", "type": "link", "question": "Book a call"}]"#)
        )

        guard case .measured(let results)? = store.state,
              case .notAggregatable(let reason) = results.questions[0].breakdown
        else {
            Issue.record("expected notAggregatable"); return
        }
        #expect(reason.contains("link question"))
    }
}

@Suite("Survey distribution accessibility")
@MainActor
struct SurveyDistributionAccessibilityTests {

    @Test("a distribution publishes a chart descriptor with every bar in it")
    func chartDescriptor() throws {
        let counts: [Int: Int] = [2: 3, 5: 1]
        let bars: [SurveyDistributionBar] = (1...5).map { value in
            let count = counts[value] ?? 0
            return SurveyDistributionBar(
                label: String(value),
                count: count,
                share: Double(count) / 4.0
            )
        }
        let descriptor = SurveyDistributionDescriptor(
            title: "How was it?",
            axisTitle: "Rating",
            bars: bars,
            isNumericAxis: true
        ).makeChartDescriptor()

        #expect(descriptor.title == "How was it?")
        #expect(descriptor.series.first?.dataPoints.count == 5)
        let summary = try #require(descriptor.summary)
        #expect(summary.contains("4 answers"))
        #expect(summary.contains("Most common: 2"))
    }

    @Test("an empty distribution still describes itself without claiming a winner")
    func emptyDescriptor() throws {
        let descriptor = SurveyDistributionDescriptor(
            title: "Nobody answered",
            axisTitle: "Choice",
            bars: [
                SurveyDistributionBar(label: "A", count: 0, share: 0),
                SurveyDistributionBar(label: "B", count: 0, share: 0),
            ],
            isNumericAxis: false
        ).makeChartDescriptor()

        let summary = try #require(descriptor.summary)
        #expect(summary.contains("0 answers"))
        #expect(!summary.contains("Most common"))
    }
}
