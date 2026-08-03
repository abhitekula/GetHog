import Foundation
import Testing

@testable import GetHogKit

/// AI session summaries — `/single_session_summaries/`.
///
/// Synthetic data exercises independently optional fields and joins the decoder
/// must support.
@Suite("Session summaries")
struct SessionSummaryTests {

    // MARK: - List

    @Test("decodes the list rows a triage screen is scanned on")
    func listDecodes() throws {
        let page = try Page<SessionSummaryRow>.decode(
            from: Fixture.data("single_session_summaries.json")
        )
        #expect(page.count == 1)
        #expect(page.results.count == 1)

        let first = try #require(page.results.first)
        // Keyed by `session_id`, not by the row's own `id` — that is what lets a
        // summary be attached to a recording the app already has.
        #expect(first.id == "018f1000-0000-7000-8000-000000000001")
        #expect(first.summaryID == "018f1000-0000-7000-8000-000000000010")
        #expect(first.distinctID == "person-example-001")
        #expect(first.duration == 10)
        #expect(first.startTime != nil)
        #expect(first.modelUsed == "synthetic-fixture")
        #expect(first.hasExceptions == false)
        #expect(first.exceptionCount == 0)
        #expect(first.outcome?.succeeded == true)
        #expect(first.outcome?.detail == "The user refreshed the fictional dashboard widgets.")
    }

    @Test("reads a failed outcome as a failure, not as a missing one")
    func listFailureOutcome() throws {
        let page = try Page<SessionSummaryRow>.decode(
            from: Fixture.data("single_session_summaries.json")
        )
        let failures = page.results.filter { $0.outcome?.succeeded == false }
        #expect(failures.isEmpty)
    }

    /// `session_outcome` is the whole point of a row, and it is still optional.
    /// A row without one must survive and read as "not judged", never as failure.
    @Test("survives a row with no outcome at all")
    func listRowWithoutOutcome() throws {
        let json = """
        {"id": "a", "session_id": "s-1", "session_duration": 12}
        """
        let row = try JSONDecoder().decode(SessionSummaryRow.self, from: Data(json.utf8))
        #expect(row.id == "s-1")
        #expect(row.outcome == nil)
        #expect(row.hasExceptions == false)
        #expect(row.startTime == nil)
    }

    // MARK: - Detail

    @Test("decodes the narrative, its chapters and their outcomes")
    func detailDecodes() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary.json")
        )
        #expect(detail.id == "018f1000-0000-7000-8000-000000000001")
        #expect(detail.duration == 10)
        #expect(detail.outcome?.succeeded == true)

        let body = try #require(detail.summary)
        #expect(body.segments.count == 2)
        #expect(body.segmentOutcomes.count == 2)
        #expect(body.keyActions.count == 2)

        let second = body.segments[1]
        #expect(second.index == 1)
        #expect(second.name == "Refresh widgets")
        #expect(second.startEventID == "event-refresh")
        #expect(second.duration == 6)
        #expect(second.eventsCount == 2)
        #expect(second.confusionCount == 1)
        #expect(second.abandonmentCount == 1)
        #expect(second.failureCount == 1)
    }

    /// The single most load-bearing rule in this file: a `confusion_count` that
    /// is absent is not a `confusion_count` of zero. "0 confusions" is a claim
    /// the model made; a missing field is a claim it never made, and the screen
    /// must be able to tell them apart.
    @Test("keeps an absent count absent rather than defaulting it to zero")
    func absentCountsStayAbsent() throws {
        let json = """
        {"name": "Checkout", "index": 0, "meta": {"duration": 10}}
        """
        let segment = try JSONDecoder().decode(SessionSummarySegment.self, from: Data(json.utf8))
        #expect(segment.duration == 10)
        #expect(segment.confusionCount == nil)
        #expect(segment.abandonmentCount == nil)
        #expect(segment.failureCount == nil)
        #expect(segment.eventsCount == nil)

        // And with the whole `meta` object gone.
        let bare = try JSONDecoder().decode(
            SessionSummarySegment.self,
            from: Data(#"{"name": "Checkout", "index": 1}"#.utf8)
        )
        #expect(bare.duration == nil)
        #expect(bare.confusionCount == nil)
    }

    @Test("survives a detail whose summary body is missing entirely")
    func detailWithoutSummaryBody() throws {
        let json = """
        {"id": "x", "session_id": "s-2", "summary": null, "session_duration": 30}
        """
        let detail = try JSONDecoder().decode(SessionSummaryDetail.self, from: Data(json.utf8))
        #expect(detail.id == "s-2")
        #expect(detail.summary == nil)
        #expect(detail.chapters.isEmpty)
    }

    @Test("survives a summary body with no sentiment, segments or key actions")
    func summaryBodyWithNothingInIt() throws {
        let json = """
        {"id": "x", "session_id": "s-3", "summary": {"session_outcome": {"success": true}}}
        """
        let detail = try JSONDecoder().decode(SessionSummaryDetail.self, from: Data(json.utf8))
        let body = try #require(detail.summary)
        #expect(body.sentiment == nil)
        #expect(body.segments.isEmpty)
        #expect(body.keyActions.isEmpty)
        #expect(detail.outcome?.succeeded == true)
    }

    // MARK: - Sentiment

    @Test("decodes sentiment, its score and the signals behind it")
    func sentimentDecodes() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary.json")
        )
        let sentiment = try #require(detail.summary?.sentiment)
        #expect(sentiment.outcome == .friction)
        #expect(sentiment.frustrationScore == 0.2)
        #expect(sentiment.signals.count == 2)

        let abandonment = try #require(sentiment.signals.first)
        #expect(abandonment.type == .abandonment)
        #expect(abandonment.intensity == 0.3)
        #expect(abandonment.segmentIndex == 1)
        #expect(abandonment.detail == "The fictional refresh briefly needed another attempt.")
    }

    /// Scores are normalized for display but service values remain defensive
    /// inputs, so out-of-range values must not escape the meter.
    @Test("clamps an out-of-range frustration score")
    func frustrationScoreIsClamped() throws {
        func score(_ raw: String) throws -> Double? {
            let json = """
            {"id": "x", "session_id": "s", "summary": {"sentiment": {"frustration_score": \(raw)}}}
            """
            let detail = try JSONDecoder().decode(SessionSummaryDetail.self, from: Data(json.utf8))
            return detail.summary?.sentiment?.frustrationScore
        }
        #expect(try score("0.7") == 0.7)
        #expect(try score("0") == 0)
        #expect(try score("1") == 1)
        // Out-of-range values must not render outside the meter's bounds.
        #expect(try score("70") == 1)
        #expect(try score("-3") == 0)
        #expect(try score("null") == nil)
    }

    @Test("quarantines a sentiment outcome and a signal type it has not seen")
    func unknownSentimentVocabulary() throws {
        let json = """
        {"id": "x", "session_id": "s", "summary": {"sentiment": {
            "outcome": "incandescent",
            "frustration_score": 0.5,
            "sentiment_signals": [
              {"signal_type": "keyboard_smashing", "description": "Typed the same field nine times.",
               "intensity": 0.8, "segment_index": 2}
            ]}}}
        """
        let detail = try JSONDecoder().decode(SessionSummaryDetail.self, from: Data(json.utf8))
        let sentiment = try #require(detail.summary?.sentiment)
        #expect(sentiment.outcome == .unknown("incandescent"))
        // The word still has to reach the screen — an unrecognised outcome that
        // renders as blank tells a reader less than the raw string does.
        #expect(try #require(sentiment.outcome).title == "Incandescent")

        let signal = try #require(sentiment.signals.first)
        #expect(signal.type == .unknown("keyboard_smashing"))
        #expect(signal.type.title == "Keyboard smashing")
    }

    // MARK: - Key actions

    @Test("reads confusion and abandonment as the flags they are")
    func keyEventFlags() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary.json")
        )
        let events = try #require(detail.summary?.keyActions.last?.events)
        let event = try #require(events.first)
        #expect(event.confusion == true)
        #expect(event.abandonment == true)
        #expect(event.exception == nil)
        #expect(event.millisecondsSinceStart == 900)
        #expect(event.currentURL == "https://app.example.com/dashboard")
        #expect(event.detail == "The user pressed the fictional refresh button.")
    }

    /// `exception` sits beside two booleans and is not one. Decoding it as
    /// `Bool` throws on every event that actually had an exception, which is
    /// precisely the set of events this screen exists to surface.
    @Test("decodes a key event's exception as a severity, not a boolean")
    func keyEventExceptionIsAString() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary_frustrated.json")
        )
        let actions = try #require(detail.summary?.keyActions)
        #expect(detail.id == "018f1000-0000-7000-8000-000000000002")
        #expect(detail.summaryID == "018f1000-0000-7000-8000-000000000011")
        #expect(actions.count == 3)
        #expect(actions[1].events.first?.exception == .blocking)
        #expect(actions[2].events.first?.exception == .nonBlocking)
        #expect(actions[0].events.first?.exception == nil)

        let invented = try JSONDecoder().decode(
            SessionSummaryKeyEvent.self,
            from: Data(#"{"event_id": "z", "exception": "catastrophic"}"#.utf8)
        )
        #expect(invented.exception == .unknown("catastrophic"))
    }

    // MARK: - Chapters

    /// The join this whole feature turns on. A segment carries no time of its
    /// own — only `start_event_id`. The offset lives on the key-action event
    /// with the matching `event_id`, and that is what the replay seeks to.
    @Test("resolves each chapter's start offset through its start event")
    func chaptersCarryTheirOffset() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary.json")
        )
        let chapters = detail.chapters
        #expect(chapters.count == 2)

        #expect(chapters[0].title == "Open dashboard")
        #expect(chapters[0].startOffset == 0.5)
        #expect(chapters[1].startOffset == 0.9)
        // Ordered by time, so the table of contents reads down the session.
        #expect(chapters[0].startOffset! < chapters[1].startOffset!)
    }

    @Test("carries each chapter's own outcome and its counts")
    func chaptersCarryTheirOutcome() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary.json")
        )
        let chapters = detail.chapters
        #expect(chapters[0].outcome?.succeeded == true)
        #expect(chapters[1].outcome?.succeeded == true)
        #expect(chapters[1].outcome?.detail == "The fictional widgets refreshed.")
        #expect(chapters[1].segment.confusionCount == 1)
    }

    /// Falls back to `segment_index` when abbreviated IDs do not line up. The
    /// index is the field the API uses to relate the parallel arrays.
    @Test("falls back to the segment index when start event ids do not match")
    func chapterOffsetFallsBackToIndex() throws {
        let json = """
        {"id": "x", "session_id": "s", "summary": {
          "segments": [{"name": "Checkout", "index": 0, "start_event_id": "does-not-exist"}],
          "key_actions": [{"segment_index": 0, "events": [
            {"event_id": "other", "milliseconds_since_start": 5000,
             "description": "Opened the cart."}]}]}}
        """
        let detail = try JSONDecoder().decode(SessionSummaryDetail.self, from: Data(json.utf8))
        let chapter = try #require(detail.chapters.first)
        #expect(chapter.startOffset == 5)
    }

    /// A chapter whose offset cannot be resolved is still worth reading — it
    /// simply cannot be seeked to, and the screen must be able to tell.
    @Test("keeps a chapter with no resolvable offset, unseekable")
    func chapterWithoutOffset() throws {
        let json = """
        {"id": "x", "session_id": "s", "summary": {
          "segments": [{"name": "Checkout", "index": 0}]}}
        """
        let detail = try JSONDecoder().decode(SessionSummaryDetail.self, from: Data(json.utf8))
        let chapter = try #require(detail.chapters.first)
        #expect(chapter.title == "Checkout")
        #expect(chapter.startOffset == nil)
    }

    /// The replay's clock starts at its first snapshot, not at
    /// `session_start_time`, so an offset measured from one is wrong against the
    /// other. When the key event's absolute timestamp is known it is preferred,
    /// because that is the only reading that lands on the right frame.
    @Test("re-bases a chapter offset onto the replay's own origin")
    func chapterOffsetRebasedOntoReplayOrigin() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary.json")
        )
        let chapter = try #require(detail.chapters.first)
        let sessionStart = try #require(detail.startTime)

        // Same answer as `milliseconds_since_start` when the origins agree.
        // Compared with a tolerance because this arm goes through `Date`; a
        // millisecond of drift on a seek is irrelevant, a strict equality is not.
        #expect(abs(chapter.startOffset(from: sessionStart)! - 0.5) < 0.001)
        // A replay whose first snapshot landed 9s late shifts every chapter.
        let late = sessionStart.addingTimeInterval(9)
        #expect(chapter.startOffset(from: late) == 0)
        // Never negative: a replay that started *after* the chapter seeks to 0
        // rather than asking the player for a position it does not have.
        #expect(chapter.startOffset(from: sessionStart.addingTimeInterval(600)) == 0)
        // With no origin it falls back to the session-relative reading.
        #expect(chapter.startOffset(from: nil) == 0.5)
    }

    /// "Nothing went wrong here" and "nobody checked" are different sentences,
    /// and only one of them may be printed. The counts themselves collapse both
    /// to an empty list — neither deserves a chip — so this is what keeps the
    /// distinction reachable.
    @Test("tells a measured nought apart from a count nobody reported")
    func measuredZeroIsNotAbsence() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary.json")
        )
        // Chapter one counted, and counted nothing.
        #expect(detail.chapters[0].reportedNoDifficulty == true)
        #expect(detail.chapters[0].noteworthyCounts.isEmpty)
        // Chapter two counted, and found something.
        #expect(detail.chapters[1].reportedNoDifficulty == false)
        #expect(detail.chapters[1].noteworthyCounts.count == 2)

        // A segment with no `meta` reported nothing at all.
        let bare = try JSONDecoder().decode(
            SessionSummaryDetail.self,
            from: Data(#"{"session_id":"s","summary":{"segments":[{"name":"A","index":0}]}}"#.utf8)
        )
        #expect(bare.chapters[0].reportedNoDifficulty == nil)
        #expect(bare.chapters[0].noteworthyCounts.isEmpty)
    }

    @Test("attaches sentiment signals to the chapter they were observed in")
    func chaptersCarryTheirSignals() throws {
        let detail = try SessionSummaryDetail.decode(
            from: Fixture.data("single_session_summary_frustrated.json")
        )
        let chapters = detail.chapters
        #expect(chapters.count == 3)
        #expect(chapters[0].signals.isEmpty)
        #expect(chapters[1].signals.count == 2)
        #expect(chapters[2].signals.count == 1)
        #expect(chapters[1].signals.first?.type == .errorCascade)
        #expect(chapters[2].signals.first?.type == .backtracking)
    }

    // MARK: - Endpoints

    @Test("builds a PAT-compatible individual summary generation request")
    func generationEndpoint() throws {
        let sessionID = "018f1000-0000-7000-8000-000000000001"
        let endpoint = PostHogAPI.generateIndividualSessionSummary(
            projectID: 1_001,
            sessionID: sessionID
        )

        #expect(
            endpoint.path
                == "/api/projects/1001/session_summaries/create_session_summaries_individually/"
        )
        #expect(endpoint.method == "POST")
        #expect(endpoint.category == .query)

        let body = try #require(endpoint.body)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object.keys.sorted() == ["session_ids"])
        #expect(object["session_ids"] as? [String] == [sessionID])
    }

    @Test("builds the summaries list endpoint")
    func listEndpoint() {
        let endpoint = PostHogAPI.sessionSummaries(projectID: 1_001, limit: 50)
        #expect(endpoint.path == "/api/projects/1001/single_session_summaries/")
        #expect(endpoint.method == "GET")
        // A plain listing computes nothing, so it must not bill against the
        // shared `.query` budget the insight screens are competing for.
        #expect(endpoint.category == .crud)
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "50" })
        #expect(!endpoint.query.contains { $0.name == "outcome" })
    }

    @Test("passes the outcome filter through to the server")
    func listEndpointFilters() {
        let failures = PostHogAPI.sessionSummaries(projectID: 1, outcome: .failure)
        #expect(failures.query.contains { $0.name == "outcome" && $0.value == "failure" })

        let withExceptions = PostHogAPI.sessionSummaries(projectID: 1, hasExceptions: true)
        #expect(withExceptions.query.contains { $0.name == "has_exceptions" && $0.value == "true" })

        let ordered = PostHogAPI.sessionSummaries(projectID: 1, order: "-session_duration")
        #expect(ordered.query.contains { $0.name == "order" && $0.value == "-session_duration" })
    }

    /// Keyed by `session_id`. Using the row's own `id` here answers 404, which
    /// is indistinguishable from "this session was never summarised".
    @Test("builds the detail endpoint from the session id")
    func detailEndpoint() {
        let endpoint = PostHogAPI.sessionSummary(
            projectID: 1_001,
            sessionID: "018f1000-0000-7000-8000-000000000001"
        )
        #expect(
            endpoint.path
                == "/api/projects/1001/single_session_summaries/018f1000-0000-7000-8000-000000000001/"
        )
        #expect(endpoint.category == .crud)
    }

    // MARK: - The 404 that isn't an error

    /// Most sessions have no summary, and the API says so with a 404 carrying
    /// `"No stored summary found for this session."`. Treating that as a failure
    /// would put an error card on the majority of session screens.
    @Test("reads a missing summary as absence rather than as failure")
    func missingSummaryIsNotAnError() async throws {
        let body = #"{"detail":"No stored summary found for this session."}"#
        let transport = StubTransport(status: 404, body: body)
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_test", region: .usCloud),
            transport: transport
        )

        do {
            let _: SessionSummaryDetail = try await client.send(
                PostHogAPI.sessionSummary(projectID: 1, sessionID: "never-summarised")
            )
            Issue.record("expected the request to throw")
        } catch let error as PostHogError {
            #expect(SessionSummaryDetail.isMissingSummary(error))
        }

        // Anything else is a genuine failure and must keep reading as one.
        #expect(!SessionSummaryDetail.isMissingSummary(.unauthorized))
        #expect(!SessionSummaryDetail.isMissingSummary(.http(status: 500, detail: nil)))
    }
}
