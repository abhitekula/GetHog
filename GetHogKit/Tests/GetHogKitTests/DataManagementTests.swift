import Foundation
import Testing

@testable import GetHogKit

// Authored action and annotation examples for synthetic project 1001. They pin
// the documented envelope and row shapes without depending on tenant data.

@Suite("Actions")
struct ActionTests {

    @Test("decodes an action with its steps")
    func decodesAction() throws {
        let json = """
        {"results": [{
          "id": 71101,
          "name": "Signed up",
          "description": "Any route through the signup form.",
          "tags": ["growth"],
          "post_to_slack": false,
          "steps": [
            {"event": "$autocapture", "selector": "form#signup button[type=submit]",
             "tag_name": "button", "text": "Create account", "text_matching": "exact",
             "href": null, "url": "/signup", "url_matching": "contains", "properties": []},
            {"event": "signup_completed", "properties": [
              {"key": "plan", "value": "pro", "operator": "exact", "type": "event"}]}
          ],
          "created_at": "2026-01-02T11:00:00Z",
          "created_by": {"id": 44, "first_name": "Ada", "last_name": "Lovelace",
                         "email": "fixture.author@example.net"},
          "deleted": false,
          "is_calculating": false,
          "last_calculated_at": "2026-01-28T02:00:00Z",
          "pinned_at": null,
          "team_id": 1001
        }]}
        """
        let page = try Page<PostHogAction>.decode(from: Data(json.utf8))
        let action = try #require(page.results.first)

        #expect(action.id == 71_101)
        #expect(action.name == "Signed up")
        #expect(action.description == "Any route through the signup form.")
        #expect(action.tags == ["growth"])
        #expect(action.steps.count == 2)
        #expect(action.createdAt != nil)
        #expect(action.lastCalculatedAt != nil)
        #expect(action.isCalculating == false)
        #expect(action.isPinned == false)
        #expect(action.createdByName == "Ada Lovelace")
    }

    @Test("summarises a step from whichever matchers it actually carries")
    func stepSummaries() throws {
        let json = """
        {"results": [{"id": 1, "name": "Mixed", "steps": [
          {"event": "$autocapture", "selector": "button.cta", "text": "Buy",
           "text_matching": "exact", "url": "/pricing", "url_matching": "contains"},
          {"event": "$pageview", "url": "blog|news", "url_matching": "regex"},
          {"event": "$autocapture", "href": "https://example.com/docs"},
          {"event": "purchase", "properties": [
            {"key": "a", "value": "1"}, {"key": "b", "value": "2"}]},
          {}
        ]}]}
        """
        let page = try Page<PostHogAction>.decode(from: Data(json.utf8))
        let steps = try #require(page.results.first?.steps)

        #expect(steps[0].summary == "$autocapture · matches button.cta · text is “Buy” · URL contains /pricing")
        #expect(steps[1].summary == "$pageview · URL matches /blog|news/")
        #expect(steps[2].summary == "$autocapture · links to https://example.com/docs")
        #expect(steps[3].summary == "purchase · 2 property filters")
        // A step with nothing set matches every event, which is a real and
        // dangerous configuration — it must not render as an empty row.
        #expect(steps[4].summary == "Any event")
    }

    @Test("falls back to the tag name when a step has no selector")
    func tagOnlyStep() throws {
        let json = #"{"results": [{"id": 1, "name": "N", "steps": [{"event": "$autocapture", "tag_name": "a"}]}]}"#
        let page = try Page<PostHogAction>.decode(from: Data(json.utf8))
        #expect(page.results[0].steps[0].summary == "$autocapture · matches <a>")
    }

    @Test("describes the whole action in one line for a list row")
    func actionSummary() throws {
        let json = """
        {"results": [
          {"id": 1, "name": "One", "steps": [{"event": "$pageview"}]},
          {"id": 2, "name": "Two", "steps": [{"event": "a"}, {"event": "b"}]},
          {"id": 3, "name": "Three", "steps": []}
        ]}
        """
        let page = try Page<PostHogAction>.decode(from: Data(json.utf8))

        #expect(page.results[0].stepSummary == "1 step")
        #expect(page.results[1].stepSummary == "2 steps, matched if any one fires")
        // An action with no steps never matches anything. Saying "0 steps" is
        // accurate but useless; the consequence is the point.
        #expect(page.results[2].stepSummary == "No steps — this action never matches")
    }

    @Test("never claims a calculation time the API did not report")
    func neverCalculated() throws {
        let json = #"{"results": [{"id": 1, "name": "N", "last_calculated_at": null, "is_calculating": true}]}"#
        let page = try Page<PostHogAction>.decode(from: Data(json.utf8))

        #expect(page.results[0].lastCalculatedAt == nil)
        #expect(page.results[0].isCalculating)
    }

    @Test("names an unnamed action instead of rendering a blank row")
    func unnamed() throws {
        // `name` is nullable in the API schema even though the UI requires one.
        let json = #"{"results": [{"id": 7, "name": null, "description": ""}]}"#
        let page = try Page<PostHogAction>.decode(from: Data(json.utf8))

        #expect(page.results[0].name == "Untitled action")
        #expect(page.results[0].description == nil)
    }

    @Test("decodes the authored empty list without inventing rows")
    func authoredEmptyList() throws {
        let page = try Page<PostHogAction>.decode(from: Fixture.data("annotations_empty.json"))
        #expect(page.count == 0)
        #expect(page.results.isEmpty)
    }
}

@Suite("Annotations")
struct AnnotationTests {

    @Test("decodes the authored empty list")
    func authoredEmptyList() throws {
        // The fictional contract keeps the fully formed empty-page shape.
        let page = try Page<Annotation>.decode(from: Fixture.data("annotations_empty.json"))
        #expect(page.count == 0)
        #expect(page.next == nil)
        #expect(page.results.isEmpty)
    }

    @Test("decodes an annotation and keeps who created it")
    func decodesAnnotation() throws {
        let json = """
        {"results": [{
          "id": 91,
          "content": "Shipped v2.4",
          "date_marker": "2026-01-20T09:30:00Z",
          "creation_type": "GIT",
          "dashboard_item": 4021,
          "insight_short_id": "aB3dEf",
          "insight_name": "Weekly actives",
          "insight_derived_name": null,
          "dashboard_id": null,
          "dashboard_name": null,
          "created_by": {"id": 44, "first_name": "Ada", "last_name": null,
                         "email": "fixture.author@example.net"},
          "created_at": "2026-01-20T09:31:00Z",
          "updated_at": "2026-01-20T09:31:00Z",
          "deleted": false,
          "scope": "dashboard_item",
          "emoji": "🚀",
          "hidden_in_user_interface": null
        }]}
        """
        let page = try Page<Annotation>.decode(from: Data(json.utf8))
        let annotation = try #require(page.results.first)

        #expect(annotation.id == 91)
        #expect(annotation.content == "Shipped v2.4")
        #expect(annotation.dateMarker != nil)
        #expect(annotation.emoji == "🚀")
        #expect(annotation.insightName == "Weekly actives")
        #expect(annotation.isHidden == false)
        // Only a last name is missing, so the email must not win over the
        // first name that is actually there.
        #expect(annotation.createdByName == "Ada")
    }

    @Test("distinguishes a person's note from a git integration's marker")
    func creationTypes() {
        // PostHog's three-letter codes are opaque, and collapsing them loses the
        // difference between "a human wrote this" and "a deploy hook did".
        #expect(AnnotationCreationType(raw: "USR") == .user)
        #expect(AnnotationCreationType(raw: "GIT") == .gitIntegration)
        #expect(AnnotationCreationType(raw: nil) == .other)
        #expect(AnnotationCreationType(raw: "XYZ") == .other)

        #expect(AnnotationCreationType.user.title == "Added by a person")
        #expect(AnnotationCreationType.gitIntegration.title == "From a git integration")
    }

    @Test("maps every documented scope, including the misleading one")
    func scopes() {
        // `dashboard_item` means *insight*, not "an item on a dashboard". Passing
        // the raw string through to the UI would mislabel every insight note.
        #expect(AnnotationScope(raw: "dashboard_item") == .insight)
        #expect(AnnotationScope.insight.title == "Insight")
        #expect(AnnotationScope(raw: "project") == .project)
        #expect(AnnotationScope(raw: "organization") == .organization)
        #expect(AnnotationScope(raw: "dashboard") == .dashboard)
        #expect(AnnotationScope(raw: "recording") == .recording)
        #expect(AnnotationScope(raw: "") == .other)
        #expect(AnnotationScope(raw: "something_new") == .other)
    }

    @Test("groups by the marked day, newest first")
    func grouping() throws {
        let json = """
        {"results": [
          {"id": 1, "content": "morning", "date_marker": "2026-01-20T09:00:00Z", "scope": "project"},
          {"id": 2, "content": "evening", "date_marker": "2026-01-20T21:00:00Z", "scope": "project"},
          {"id": 3, "content": "older", "date_marker": "2026-01-18T12:00:00Z", "scope": "project"}
        ]}
        """
        let page = try Page<Annotation>.decode(from: Data(json.utf8))
        let days = Annotation.groupedByDay(page.results, calendar: Self.utc)

        #expect(days.count == 2)
        #expect(days[0].annotations.map(\.id) == [2, 1])
        #expect(days[1].annotations.map(\.id) == [3])
    }

    @Test("falls back to created_at when an annotation has no date marker")
    func fallsBackToCreatedAt() throws {
        let json = """
        {"results": [{"id": 1, "content": "c", "date_marker": null,
                      "created_at": "2026-01-19T08:00:00Z", "scope": "project"}]}
        """
        let page = try Page<Annotation>.decode(from: Data(json.utf8))
        let days = Annotation.groupedByDay(page.results, calendar: Self.utc)

        #expect(days.count == 1)
        #expect(days[0].day != nil)
    }

    @Test("keeps undated annotations in a trailing group instead of dropping them")
    func undated() throws {
        let json = """
        {"results": [
          {"id": 1, "content": "dated", "date_marker": "2026-01-20T09:00:00Z", "scope": "project"},
          {"id": 2, "content": "undated", "scope": "project"}
        ]}
        """
        let page = try Page<Annotation>.decode(from: Data(json.utf8))
        let days = Annotation.groupedByDay(page.results, calendar: Self.utc)

        #expect(days.count == 2)
        #expect(days[0].day != nil)
        #expect(days[1].day == nil)
        #expect(days[1].annotations.map(\.id) == [2])
    }

    @Test("says an annotation is empty rather than rendering a blank row")
    func emptyContent() throws {
        let json = #"{"results": [{"id": 1, "content": "", "scope": "project"}]}"#
        let page = try Page<Annotation>.decode(from: Data(json.utf8))
        #expect(page.results[0].content == nil)
        #expect(page.results[0].displayContent == "(no text)")
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
