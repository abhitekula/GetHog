import Foundation
import Testing

@testable import GetHogKit

/// The annotation write, tested the way `setFlagActive` is: by inspecting the
/// request that would be sent.
///
/// **No request in this suite is executed.** An annotation is not a value a test
/// can write and then quietly put back because this app cannot delete one. The
/// body below is built from PostHog's OpenAPI document; these tests establish
/// that the app builds the documented request, not that a server accepted it.
@Suite("Annotation writes")
struct AnnotationAPITests {

    private func body(_ endpoint: Endpoint) throws -> String {
        String(decoding: try #require(endpoint.body), as: UTF8.self)
    }

    private func json(_ endpoint: Endpoint) throws -> [String: Any] {
        let data = try #require(endpoint.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("builds a project-scoped annotation as a POST to the collection")
    func createProjectScoped() throws {
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = PostHogAPI.createAnnotation(
            projectID: 1_001,
            content: "Deployed 2.14.0",
            dateMarker: marker
        )

        #expect(endpoint.method == "POST")
        #expect(endpoint.path == "/api/projects/1001/annotations/")
        #expect(endpoint.query.isEmpty)
        // `.crud`, not `.query`: this is a REST resource, and the scarce
        // analytics budget must not be spent on a note.
        #expect(endpoint.category == .crud)

        let json = try json(endpoint)
        #expect(json["content"] as? String == "Deployed 2.14.0")
        #expect(json["scope"] as? String == "project")
        // `USR`, so a note typed on a phone is never drawn with the deploy-marker
        // glyph the list reserves for `GIT`.
        #expect(json["creation_type"] as? String == "USR")
        // Nothing the server owns is sent. Every one of these is `readOnly: true`
        // in the `Annotation` schema, and sending a value for one is how a client
        // starts inventing authorship.
        for serverOwned in ["id", "created_by", "created_at", "updated_at",
                            "insight_name", "insight_short_id", "dashboard_name"] {
            #expect(json[serverOwned] == nil)
        }
        // Nor anything the user was never asked. `emoji`, `deleted` and
        // `hidden_in_user_interface` are writable and deliberately absent — a
        // create that carries a default nobody chose is a default PostHog would
        // otherwise have decided for itself.
        for unasked in ["emoji", "deleted", "hidden_in_user_interface"] {
            #expect(json[unasked] == nil)
        }
    }

    /// The whole reason this feature belongs on a phone: the note records when
    /// the thing *happened*, not when it was typed. A `date_marker` defaulted to
    /// `now` anywhere in this path would silently destroy that.
    @Test("sends the marked instant, round-trippable, and never the current time")
    func markerIsTheEventTime() throws {
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = PostHogAPI.createAnnotation(
            projectID: 1,
            content: "Incident started",
            dateMarker: marker
        )

        let sent = try #require(try json(endpoint)["date_marker"] as? String)
        #expect(sent == PostHogDate.iso8601(marker))
        // Parsed back by the same type that parses the read response, so the
        // instant that goes out is the instant that would come back.
        #expect(PostHogDate.parse(sent) == marker)
        #expect(abs(marker.timeIntervalSinceNow) > 60)
    }

    /// `dashboard_item` means **insight**, and it is both the scope's name and
    /// the field that carries the insight's id — while a *dashboard* annotation
    /// uses `dashboard_id`. Reading either name as English gets it backwards, so
    /// the pairing is pinned here.
    @Test("pairs each scope with the id field PostHog actually reads")
    func scopeTargetsCarryTheRightIDField() throws {
        let insight = PostHogAPI.createAnnotation(
            projectID: 1, content: "c", dateMarker: .init(), target: .insight(id: 9_973_521)
        )
        let insightJSON = try json(insight)
        #expect(insightJSON["scope"] as? String == "dashboard_item")
        #expect(insightJSON["dashboard_item"] as? Int == 9_973_521)
        #expect(insightJSON["dashboard_id"] == nil)

        let dashboard = PostHogAPI.createAnnotation(
            projectID: 1, content: "c", dateMarker: .init(), target: .dashboard(id: 725_101)
        )
        let dashboardJSON = try json(dashboard)
        #expect(dashboardJSON["scope"] as? String == "dashboard")
        #expect(dashboardJSON["dashboard_id"] as? Int == 725_101)
        #expect(dashboardJSON["dashboard_item"] == nil)

        // The two unattached scopes carry neither id.
        for target in [AnnotationTarget.project, .organization] {
            let unattached = try json(
                PostHogAPI.createAnnotation(
                    projectID: 1, content: "c", dateMarker: .init(), target: target
                )
            )
            #expect(unattached["dashboard_item"] == nil)
            #expect(unattached["dashboard_id"] == nil)
        }
        #expect(
            try json(
                PostHogAPI.createAnnotation(
                    projectID: 1, content: "c", dateMarker: .init(), target: .organization
                )
            )["scope"] as? String == "organization"
        )
    }

    /// The trap the README records, from the other direction: a scope value is
    /// not a description of where the annotation is drawn.
    @Test("keeps dashboard_item meaning insight in both directions")
    func scopeVocabularyIsNotEnglish() {
        #expect(AnnotationScope.insight.rawValue == "dashboard_item")
        #expect(AnnotationScope(raw: "dashboard_item") == .insight)
        #expect(AnnotationScope.insight.title == "Insight")
        // …and the *dashboard* scope is the plain word, so the two cannot be
        // swapped by someone reading only the wire values.
        #expect(AnnotationScope.dashboard.rawValue == "dashboard")

        #expect(AnnotationTarget.insight(id: 1).scope == .insight)
        #expect(AnnotationTarget.dashboard(id: 1).scope == .dashboard)
    }

    /// `AnnotationScopeEnum` is five values, `recording` included. It decodes so
    /// old rows survive, and `AnnotationTarget` cannot express it so nothing new
    /// is written with it.
    @Test("decodes all five scopes and offers only the four worth writing")
    func fiveScopesReadFourWritable() {
        let wire = ["dashboard_item", "dashboard", "project", "organization", "recording"]
        let decoded = wire.map { AnnotationScope(raw: $0) }
        #expect(decoded == [.insight, .dashboard, .project, .organization, .recording])
        // Nothing falls through to `.other`, which is what an unknown value gets.
        #expect(!decoded.contains(.other))
        #expect(AnnotationScope(raw: "something_new") == .other)
        #expect(AnnotationScope(raw: nil) == .other)
    }

    /// A negative id is what makes rollback safe: `AnnotationComposer` puts a
    /// placeholder row on screen before the POST is answered and removes that
    /// exact row if it fails, and PostHog's ids are positive, so no real
    /// annotation can be caught by the removal.
    @Test("builds a placeholder row that cannot collide with a real one")
    func placeholderRowIsConstructible() {
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        let placeholder = Annotation(
            id: -1,
            content: "Deployed 2.14.0",
            dateMarker: marker,
            scope: .project
        )

        #expect(placeholder.id < 0)
        #expect(placeholder.displayContent == "Deployed 2.14.0")
        #expect(placeholder.effectiveDate == marker)
        #expect(placeholder.creationType == .user)
        // Nothing the server owns is guessed at: no author, no created time.
        #expect(placeholder.createdByName == nil)
        #expect(placeholder.createdAt == nil)
        #expect(!placeholder.isDeleted)
        #expect(!placeholder.isHidden)

        // And it groups by the day it *marks*, next to whatever else happened.
        let days = Annotation.groupedByDay([placeholder])
        #expect(days.count == 1)
        #expect(days.first?.day != nil)
        #expect(days.first?.annotations.first?.id == -1)
    }

    @Test("escapes nothing by hand — the body is JSON, not interpolated SQL")
    func contentWithQuotesSurvives() throws {
        let endpoint = PostHogAPI.createAnnotation(
            projectID: 1,
            content: #"Rolled back "fast path" — it's slower"#,
            dateMarker: .init()
        )
        // Read back through the parser rather than asserting on bytes: the point
        // is that the value survives, not which escapes `JSONSerialization` chose.
        #expect(
            try json(endpoint)["content"] as? String == #"Rolled back "fast path" — it's slower"#
        )
        #expect(try !body(endpoint).isEmpty)
    }
}
