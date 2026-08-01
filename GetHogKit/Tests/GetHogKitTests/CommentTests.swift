import Foundation
import Testing

@testable import GetHogKit

/// Swift Testing exports its own `Comment` — the type behind a test's trailing
/// documentation string — so the bare name is ambiguous in any file that imports
/// both. Aliasing here keeps the model's public name plain rather than renaming
/// a PostHog resource to dodge a collision that exists only in tests.
private typealias Comment = GetHogKit.Comment

/// Comments.
///
/// `GET /api/projects/1001/comments/?limit=N` answers 200 and is **cursor**
/// paginated: `next`/`previous` are present and there is **no `count` field at
/// all**. `GET .../comments/count/` is a separate endpoint that answers
/// a standalone count envelope.
///
/// The row fixture is a deterministic synthetic example based on PostHog's
/// public `Comment` serializer. Posting needs `comment:write`, which this app
/// does not ask for — see `PostHogAPI+Comments`.
@Suite("Comments")
struct CommentTests {

    // MARK: - Envelope

    /// A decoder that required `count` would throw on every real response.
    /// `Page.count` is optional for exactly this reason and this pins it.
    @Test("decodes a cursor page that carries no count at all")
    func cursorPageWithoutCount() throws {
        let data = try Fixture.data("comments.json")
        // The absence is a property of the payload, not of the decoder — assert
        // it on the JSON so this still fails if someone "fixes" the fixture.
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(raw?["count"] == nil)

        let page = try Page<Comment>.decode(from: data)
        #expect(page.count == nil)
        #expect(page.next != nil)
        #expect(page.results.count == 5)
        #expect(page.results.map(\.version) == [3, 4, 5, 6, 7])
    }

    /// The count lives on its own sub-resource, and it is the only place a total
    /// can honestly come from — `results.count` is a page size, not a total.
    @Test("reads the separate count endpoint's own envelope")
    func countEndpointEnvelope() throws {
        let count = try JSONDecoder().decode(
            CommentCount.self,
            from: Fixture.data("comments_count.json")
        )
        #expect(count.count == 3)
    }

    // MARK: - Authorship

    /// `created_by` is nullable, and the null case is not an error: a comment
    /// filed by an automation has no user behind it. A row that unwrapped this
    /// would take the thread down.
    @Test("tolerates a comment with no author")
    func nullAuthor() throws {
        let page = try Page<Comment>.decode(from: Fixture.data("comments.json"))
        let orphan = try #require(page.results.first { $0.authorName == nil })
        #expect(orphan.content.hasPrefix("Example Company"))
        // Named for what it is, rather than left blank or given a fake name.
        #expect(orphan.displayAuthor == "PostHog")
    }

    @Test("reduces an embedded user to a display name, falling back to e-mail")
    func authorNames() throws {
        let page = try Page<Comment>.decode(from: Fixture.data("comments.json"))
        #expect(page.results.contains { $0.authorName?.isEmpty == false })
        // Empty first/last names are commoner than absent ones on real
        // installations; an e-mail is a person, "  " is not.
        #expect(page.results.contains { $0.authorName == "alex+0004@example.com" })
    }

    @Test("uses only the reserved synthetic author identities")
    func syntheticAuthorIDs() throws {
        let raw = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("comments.json")) as? [String: Any]
        )
        let results = try #require(raw["results"] as? [[String: Any]])
        let ids = results.compactMap { row in
            ((row["created_by"] as? [String: Any])?["id"] as? NSNumber)?.intValue
        }
        #expect(ids == [880101, 880303, 880101])
    }

    // MARK: - Type and task layer

    @Test("decodes both documented comment types")
    func types() throws {
        let page = try Page<Comment>.decode(from: Fixture.data("comments.json"))
        #expect(page.results.contains { $0.type == .conversation })
        #expect(page.results.contains { $0.type == .review })
    }

    /// The serializer documents two types, and the API ships at least a third.
    /// An unrecognised one must survive as itself: it is still a comment
    /// somebody wrote, and hiding it would make a thread read as incomplete.
    @Test("quarantines a comment type this client has not seen")
    func unknownType() throws {
        let page = try Page<Comment>.decode(from: Fixture.data("comments.json"))
        let reaction = try #require(page.results.first { $0.type == .unknown("emoji_reaction") })
        #expect(reaction.content == "Example Company reviewed a fictional activation signal and recorded the follow-up.")
        #expect(reaction.type == .unknown("emoji_reaction"))
        #expect(reaction.type.title == "Emoji reaction")
    }

    /// `is_task` is documented as immutable after creation and impossible on a
    /// reply, which makes it a property of the comment rather than a state — so
    /// completion is what varies and what a row has to show.
    @Test("separates an open task from a completed one")
    func taskLayer() throws {
        let page = try Page<Comment>.decode(from: Fixture.data("comments.json"))

        let open = try #require(page.results.first { $0.isTask && !$0.isCompleted })
        #expect(open.completedAt == nil)
        #expect(open.completedBy == nil)

        let done = try #require(page.results.first { $0.isTask && $0.isCompleted })
        #expect(done.completedAt != nil)
        #expect(done.completedBy == "alex+0005@example.com")

        #expect(page.results.filter(\.isTask).count == 2)
    }

    @Test("keeps the scope and item id a comment is attached to")
    func attachment() throws {
        let page = try Page<Comment>.decode(from: Fixture.data("comments.json"))
        // Comments are keyed by scope + item_id — they belong to the object they
        // annotate, which is why this app shows them on the insight rather than
        // in a tab of their own.
        #expect(page.results.allSatisfy { $0.scope == "insight" })
        #expect(page.results.allSatisfy { $0.itemID == "synthetic-id-0005" })
        #expect(page.results.first?.createdAt != nil)
    }

    /// Newest last, like every thread anyone has ever read. The API returns
    /// them newest-first, so a view that rendered the response order would put
    /// the reply above the thing it replies to.
    @Test("orders a thread oldest first")
    func threadOrder() throws {
        let page = try Page<Comment>.decode(from: Fixture.data("comments.json"))
        let thread = page.results.sorted(by: Comment.oldestFirst)
        let dates = thread.compactMap(\.createdAt)
        #expect(dates == dates.sorted())
    }

    // MARK: - Endpoint

    @Test("scopes the request to one object rather than fetching the project's comments")
    func endpoint() {
        let endpoint = PostHogAPI.comments(projectID: 1_001, scope: .insight, itemID: "140")
        #expect(endpoint.path == "/api/projects/1001/comments/")
        #expect(endpoint.method == "GET")
        #expect(endpoint.category == .crud)
        #expect(endpoint.query.contains { $0.name == "scope" && $0.value == "insight" })
        #expect(endpoint.query.contains { $0.name == "item_id" && $0.value == "140" })
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "50" })
    }

    @Test("builds the separate count sub-resource")
    func countEndpoint() {
        let endpoint = PostHogAPI.commentCount(projectID: 1_001, scope: .recording, itemID: "abc")
        #expect(endpoint.path == "/api/projects/1001/comments/count/")
        #expect(endpoint.query.contains { $0.name == "scope" && $0.value == "recording" })
        #expect(endpoint.query.contains { $0.name == "item_id" && $0.value == "abc" })
    }

    @Test("uses PostHog's own scope strings")
    func scopeStrings() {
        #expect(CommentScope.insight.rawValue == "insight")
        #expect(CommentScope.dashboard.rawValue == "dashboard")
        #expect(CommentScope.recording.rawValue == "recording")
        #expect(CommentScope.notebook.rawValue == "notebook")
        #expect(CommentScope.featureFlag.rawValue == "feature_flag")
    }
}
