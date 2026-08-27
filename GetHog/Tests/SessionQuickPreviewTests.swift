import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Session Quick Preview")
struct SessionQuickPreviewTests {
    @Test("person identity wins, then person and recording distinct identities, then anonymous")
    func identityFallbackIsHonest() throws {
        let named = try Self.recording(
            person: #"{"name":"Synthetic Person","distinct_ids":["person-distinct"]}"#,
            distinctID: "recording-distinct"
        )
        let personDistinct = try Self.recording(
            person: #"{"name":"","distinct_ids":["person-distinct"]}"#,
            distinctID: "recording-distinct"
        )
        let recordingDistinct = try Self.recording(
            person: #"{"name":"","distinct_ids":[]}"#,
            distinctID: "recording-distinct"
        )
        let anonymous = try Self.recording(person: "null", distinctID: nil)

        #expect(SessionQuickPreviewPresentation(recording: named, digest: nil).identity == "Synthetic Person")
        #expect(SessionQuickPreviewPresentation(recording: personDistinct, digest: nil).identity == "person-distinct")
        #expect(SessionQuickPreviewPresentation(recording: recordingDistinct, digest: nil).identity == "recording-distinct")
        #expect(SessionQuickPreviewPresentation(recording: anonymous, digest: nil).identity == "Anonymous")
    }

    @Test("start path, wall duration, active time, and activity facts remain distinct")
    func loadedFactsRemainDistinct() throws {
        let presentation = SessionQuickPreviewPresentation(
            recording: try Self.recording(),
            digest: nil
        )

        #expect(presentation.startPath == "/synthetic/checkout")
        #expect(presentation.duration == "2:05")
        #expect(presentation.activeTime == "0:42")
        #expect(presentation.activity == "12 clicks · 3 keypresses · 2 console errors")
        #expect(presentation.relativeStart != "Unknown start time")
    }

    @Test("web and mobile sources state their actual playability")
    func sourceAndPlayabilityAgree() throws {
        let web = SessionQuickPreviewPresentation(
            recording: try Self.recording(snapshotSource: "web"),
            digest: nil
        )
        let mobile = SessionQuickPreviewPresentation(
            recording: try Self.recording(snapshotSource: "mobile"),
            digest: nil
        )

        #expect(web.source == "Web")
        #expect(web.playability == "Playable")
        #expect(mobile.source == "Mobile")
        #expect(mobile.playability == "Not playable")
    }

    @Test("an already-loaded Replay Vision summary becomes a single line")
    func loadedDigestUsesSummary() throws {
        let digest = try Self.digest(
            summary: "Synthetic checkout began.\nThe confirmation appeared."
        )

        #expect(
            SessionQuickPreviewPresentation(
                recording: try Self.recording(),
                digest: digest
            ).digest == "Synthetic checkout began. The confirmation appeared."
        )
    }

    @Test("loaded friction is the fallback when summary and title are empty")
    func loadedFrictionIsDigestFallback() throws {
        let digest = try Self.digest(
            frictionPoints: #"["The synthetic submit action needed a retry."]"#,
            outcome: "Synthetic checkout eventually completed."
        )

        #expect(
            SessionQuickPreviewPresentation(
                recording: try Self.recording(),
                digest: digest
            ).digest == "Friction: The synthetic submit action needed a retry."
        )
    }

    @Test("loaded outcome follows an empty summary without friction")
    func loadedOutcomeIsDigestFallback() throws {
        let digest = try Self.digest(outcome: "Synthetic checkout completed.")

        #expect(
            SessionQuickPreviewPresentation(
                recording: try Self.recording(),
                digest: digest
            ).digest == "Outcome: Synthetic checkout completed."
        )
    }

    @Test("absent loaded Replay Vision data never invents a digest")
    func absentDigestStaysAbsent() throws {
        #expect(
            SessionQuickPreviewPresentation(
                recording: try Self.recording(),
                digest: nil
            ).digest == nil
        )
    }

    private static func recording(
        person: String = #"{"name":"Synthetic Person","distinct_ids":["person-distinct"]}"#,
        distinctID: String? = "recording-distinct",
        snapshotSource: String = "web"
    ) throws -> SessionRecording {
        let distinctValue = distinctID.map { #""\#($0)""# } ?? "null"
        return try JSONDecoder().decode(
            SessionRecording.self,
            from: Data(
                #"""
                {
                  "id": "session-quick-preview-1",
                  "distinct_id": \#(distinctValue),
                  "recording_duration": 125,
                  "active_seconds": 42,
                  "start_time": "2026-08-27T10:00:00Z",
                  "end_time": "2026-08-27T10:02:05Z",
                  "start_url": "https://example.invalid/synthetic/checkout?step=1",
                  "click_count": 12,
                  "keypress_count": 3,
                  "console_log_count": 4,
                  "console_warn_count": 1,
                  "console_error_count": 2,
                  "snapshot_source": "\#(snapshotSource)",
                  "ongoing": false,
                  "viewed": true,
                  "person": \#(person)
                }
                """#.utf8
            )
        )
    }

    private static func digest(
        title: String = "",
        summary: String = "",
        frictionPoints: String = "[]",
        outcome: String = ""
    ) throws -> ReplayVisionSummaryDigest {
        let titleJSON = try Self.jsonString(title)
        let summaryJSON = try Self.jsonString(summary)
        let outcomeJSON = try Self.jsonString(outcome)
        let response = try QueryResponse.decode(from: Data(
            #"""
            {
              "columns": [
                "session_id", "title", "summary", "intent", "outcome",
                "friction_points", "confidence", "model", "completed_at"
              ],
              "results": [[
                "session-quick-preview-1", \#(titleJSON), \#(summaryJSON), "",
                \#(outcomeJSON), \#(frictionPoints), 0.9, "synthetic-model",
                "2026-08-27T10:03:00Z"
              ]]
            }
            """#.utf8
        ))
        return try #require(ReplayVisionSummaryDigest.rows(from: response).first)
    }

    private static func jsonString(_ value: String) throws -> String {
        try #require(String(data: JSONEncoder().encode(value), encoding: .utf8))
    }
}
