import Foundation
import Testing

@testable import GetHogKit

// Saved event filters are the one piece of user-authored data GetHog stores
// locally: PostHog has no API for them, so nothing here round-trips through the
// server and the encoding is ours to keep stable. The two properties worth
// pinning are that a decoded filter is identical to the one saved, and that a
// filter saved against one project is invisible from another.

@Suite("Event filter tokens")
struct EventFilterTokenTests {

    @Test("survives an encode/decode round trip with its kind, key and value intact")
    func tokenRoundTrip() throws {
        let tokens: [EventFilterToken] = [
            .event("$pageview"),
            .person("filter.person@example.org"),
            .property("plan", "pro"),
        ]
        let data = try JSONEncoder().encode(tokens)
        let decoded = try JSONDecoder().decode([EventFilterToken].self, from: data)

        #expect(decoded == tokens)
        #expect(decoded[0].kind == .event)
        #expect(decoded[2].key == "plan")
        #expect(decoded[2].value == "pro")
    }

    @Test("identity distinguishes tokens that differ only by kind")
    func tokenIdentity() {
        #expect(EventFilterToken.event("signup").id != EventFilterToken.person("signup").id)
        #expect(EventFilterToken.event("signup").id == EventFilterToken.event("signup").id)
    }

    @Test("reads key:value text as a property token")
    func suggestsPropertyToken() {
        let suggestions = EventFilterToken.suggestions(for: "plan:pro")
        #expect(suggestions == [.property("plan", "pro")])
    }

    @Test("tolerates spaces around the colon and inside the value")
    func suggestsPropertyTokenWithSpaces() {
        #expect(EventFilterToken.suggestions(for: "plan : pro tier") == [.property("plan", "pro tier")])
    }

    @Test("offers an event and a person reading for bare text")
    func suggestsEventAndPerson() {
        #expect(EventFilterToken.suggestions(for: "$pageview") == [.event("$pageview"), .person("$pageview")])
    }

    // A property key becomes a bare HogQL path, so anything that isn't an
    // identifier has to fall back rather than be interpolated into the query.
    @Test("falls back to event and person when the key could not be a property path")
    func rejectsUnsafePropertyKey() {
        let suggestions = EventFilterToken.suggestions(for: "we're done:yes")
        #expect(suggestions.allSatisfy { $0.kind != .property })
    }

    @Test("offers nothing for blank text")
    func suggestsNothingForBlankText() {
        #expect(EventFilterToken.suggestions(for: "   ").isEmpty)
        #expect(EventFilterToken.suggestions(for: "plan:").isEmpty == false)
    }

    @Test("labels a property token as key and value, and the others as their term")
    func displayText() {
        #expect(EventFilterToken.property("plan", "pro").displayText == "plan: pro")
        #expect(EventFilterToken.event("$pageview").displayText == "$pageview")
        #expect(EventFilterToken.person("rowan").displayText == "rowan")
    }
}

@Suite("Saved event filter store")
struct SavedEventFilterStoreTests {

    private func makeStore() -> SavedEventFilterStore {
        SavedEventFilterStore(storage: InMemoryFilterStorage())
    }

    @Test("a saved set comes back with its tokens unchanged")
    func savesAndReadsBack() throws {
        let store = makeStore()
        let tokens: [EventFilterToken] = [.event("purchase"), .property("plan", "pro")]

        let saved = try #require(store.add(name: "Pro purchases", tokens: tokens, projectID: 1))
        #expect(saved.name == "Pro purchases")

        let filters = store.filters(projectID: 1)
        #expect(filters.count == 1)
        #expect(filters[0].tokens == tokens)
        #expect(filters[0].id == saved.id)
    }

    // The scoping requirement: an event name that exists in one project is
    // meaningless in the next, so the storage key carries the project id.
    @Test("a set saved against one project is invisible from another")
    func scopesPerProject() {
        let store = makeStore()
        store.add(name: "Pro purchases", tokens: [.event("purchase")], projectID: 1)

        #expect(store.filters(projectID: 1).count == 1)
        #expect(store.filters(projectID: 42).isEmpty)
    }

    @Test("two projects keep independent sets under the same name")
    func projectsDoNotCollide() {
        let store = makeStore()
        store.add(name: "Signups", tokens: [.event("signup_a")], projectID: 1)
        store.add(name: "Signups", tokens: [.event("signup_b")], projectID: 42)

        #expect(store.filters(projectID: 1).first?.tokens == [.event("signup_a")])
        #expect(store.filters(projectID: 42).first?.tokens == [.event("signup_b")])
    }

    @Test("the storage key names the project")
    func storageKeyNamesProject() {
        #expect(SavedEventFilterStore.storageKey(projectID: 42).contains("42"))
        #expect(
            SavedEventFilterStore.storageKey(projectID: 42)
                != SavedEventFilterStore.storageKey(projectID: 123)
        )
    }

    @Test("renaming keeps the identity and the tokens")
    func renames() throws {
        let store = makeStore()
        let saved = try #require(
            store.add(name: "Old", tokens: [.event("purchase")], projectID: 1)
        )

        store.rename(id: saved.id, to: "  New  ", projectID: 1)

        let filters = store.filters(projectID: 1)
        #expect(filters.count == 1)
        #expect(filters[0].name == "New")
        #expect(filters[0].id == saved.id)
        #expect(filters[0].tokens == [.event("purchase")])
    }

    @Test("deleting removes only the named set")
    func deletesOne() throws {
        let store = makeStore()
        let keep = try #require(store.add(name: "Keep", tokens: [.event("a")], projectID: 1))
        let drop = try #require(store.add(name: "Drop", tokens: [.event("b")], projectID: 1))

        store.delete(id: drop.id, projectID: 1)

        #expect(store.filters(projectID: 1).map(\.id) == [keep.id])
    }

    @Test("a blank name or an empty token set is not saved")
    func rejectsEmptyInput() {
        let store = makeStore()
        #expect(store.add(name: "   ", tokens: [.event("a")], projectID: 1) == nil)
        #expect(store.add(name: "Fine", tokens: [], projectID: 1) == nil)
        #expect(store.filters(projectID: 1).isEmpty)
    }

    @Test("names are trimmed on the way in")
    func trimsName() throws {
        let store = makeStore()
        let saved = try #require(
            store.add(name: "  Pro purchases \n", tokens: [.event("a")], projectID: 1)
        )
        #expect(saved.name == "Pro purchases")
    }

    // Alphabetical rather than newest-first: this list is something the user
    // scans by name, and a rename should move the row somewhere predictable.
    @Test("sets are listed alphabetically, ignoring case")
    func sortsByName() {
        let store = makeStore()
        store.add(name: "zebra", tokens: [.event("a")], projectID: 1)
        store.add(name: "Apple", tokens: [.event("b")], projectID: 1)
        store.add(name: "mango", tokens: [.event("c")], projectID: 1)

        #expect(store.filters(projectID: 1).map(\.name) == ["Apple", "mango", "zebra"])
    }

    @Test("unreadable stored data reads as no saved sets rather than throwing")
    func toleratesCorruptData() {
        let storage = InMemoryFilterStorage()
        storage.setFilterData(Data("not json".utf8), forKey: SavedEventFilterStore.storageKey(projectID: 1))
        let store = SavedEventFilterStore(storage: storage)

        #expect(store.filters(projectID: 1).isEmpty)
    }
}

@Suite("Event filter query building")
struct EventFilterQueryTests {

    /// Any bound will do for a shape assertion; that there *is* one is the
    /// invariant these tests now carry.
    private static let floor = Date(timeIntervalSince1970: 1_700_000_000)

    private static func decodedSQL(from endpoint: Endpoint) -> String? {
        guard let body = endpoint.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let query = json["query"] as? [String: Any]
        else { return nil }
        return query["query"] as? String
    }

    @Test("an event token becomes an exact event match")
    func singleEventToken() throws {
        let endpoint = PostHogAPI.events(projectID: 1, since: Self.floor, tokens: [.event("purchase")])
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains("event = 'purchase'"))
    }

    // Two exact event names AND-ed together match nothing, so same-kind tokens
    // widen the query rather than narrowing it to the empty set.
    @Test("several event tokens become one IN list")
    func manyEventTokens() throws {
        let endpoint = PostHogAPI.events(projectID: 1, since: Self.floor, tokens: [.event("a"), .event("b")])
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains("event IN ('a', 'b')"))
    }

    @Test("a person token matches the distinct id")
    func personToken() throws {
        let endpoint = PostHogAPI.events(projectID: 1, since: Self.floor, tokens: [.person("rowan")])
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains("distinct_id ILIKE '%rowan%'"))
    }

    @Test("a property token becomes a property equality")
    func propertyToken() throws {
        let endpoint = PostHogAPI.events(projectID: 1, since: Self.floor, tokens: [.property("plan", "pro")])
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains("properties.plan = 'pro'"))
    }

    @Test("tokens of different kinds are combined with AND")
    func mixedTokens() throws {
        let endpoint = PostHogAPI.events(
            projectID: 1,
            since: Self.floor,
            tokens: [.event("purchase"), .property("plan", "pro")]
        )
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains("event = 'purchase' AND properties.plan = 'pro'"))
    }

    @Test("no tokens leaves the time bound as the only filter")
    func noTokens() throws {
        // This used to expect no WHERE clause at all. That shape is what made
        // the feed unusable — measured at a median 8.53s and 1 success in 5 —
        // so the expectation moved with the fix rather than the fix being
        // written around it.
        let endpoint = PostHogAPI.events(projectID: 1, since: Self.floor, tokens: [])
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains("WHERE timestamp > toDateTime64("))
        #expect(!sql.contains(" AND "))
    }

    @Test("a quote in a token value is escaped, not interpolated raw")
    func escapesTokenValues() throws {
        let endpoint = PostHogAPI.events(projectID: 1, since: Self.floor, tokens: [.event(#"a\'b"#)])
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains(#"a\\\'b"#))
    }

    @Test("the keyset cursor still applies alongside tokens")
    func cursorWithTokens() throws {
        let endpoint = PostHogAPI.events(
            projectID: 1,
            since: Self.floor,
            before: EventCursor(timestamp: Self.floor, uuid: "u1"),
            tokens: [.event("purchase")]
        )
        let sql = try #require(Self.decodedSQL(from: endpoint))
        #expect(sql.contains("(timestamp, uuid) < (toDateTime64("))
        #expect(sql.contains("event = 'purchase'"))
    }
}
