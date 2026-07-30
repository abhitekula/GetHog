import Foundation

public extension PostHogAPI {

    /// Comments on one object.
    ///
    /// Always scoped. `GET /comments/` unfiltered returns the project's comments
    /// with no way to tell what any of them is about beyond an id, which is a
    /// list of sentences about nothing — so the filter is a parameter of the
    /// call rather than an option on it.
    ///
    /// The response is **cursor paginated and carries no `count` field**; only
    /// `commentCount` can answer "how many". `Page.count` is optional, which is
    /// what lets `Page<Comment>` decode this at all.
    ///
    /// Read-only. Posting is `POST /comments/` and needs `comment:write`, which
    /// this app does not request: onboarding lists the exact scopes to tick and
    /// adding a write scope to that list — for a feature that is a text field on
    /// a phone — would make every reader's key more powerful than the app needs
    /// it to be. Reading works with the key that is already there.
    static func comments(
        projectID: Int,
        scope: CommentScope,
        itemID: String,
        limit: Int = 50
    ) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/comments/",
            query: [
                URLQueryItem(name: "scope", value: scope.rawValue),
                URLQueryItem(name: "item_id", value: itemID),
                URLQueryItem(name: "limit", value: String(limit)),
            ],
            category: .crud
        )
    }

    /// How many comments an object has, without fetching them.
    ///
    /// Its own sub-resource because the list envelope has no total. Used where a
    /// badge is wanted and the thread is not — never alongside `comments`, which
    /// would spend two requests to learn one thing.
    static func commentCount(projectID: Int, scope: CommentScope, itemID: String) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/comments/count/",
            query: [
                URLQueryItem(name: "scope", value: scope.rawValue),
                URLQueryItem(name: "item_id", value: itemID),
            ],
            category: .crud
        )
    }
}
