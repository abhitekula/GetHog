import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// The annotation write, on this side of the wire.
///
/// The transport is fully scripted, exactly as `ErrorTriageTests` scripts one.
/// The test pins everything the app controls: the request it builds, the row it
/// shows while the request is out, and what it does with that row when the
/// authored response arrives.
private actor ScriptedTransport: HTTPTransport {
    private var responses: [(Int, String)]
    private(set) var requests: [(method: String, url: String, body: String)] = []
    /// Runs *while the request is in flight*, before any response exists.
    ///
    /// The only way to observe the optimistic row deterministically. An
    /// `async let` around `create` does not do it: a child task is not
    /// guaranteed to have reached its first statement before the parent's next
    /// one, so the check raced and read an empty store. This hook cannot race —
    /// the composer inserts the row, then calls `send`, and this is `send`.
    private let whileInFlight: @Sendable () async -> Void

    init(_ responses: [(Int, String)], whileInFlight: @escaping @Sendable () async -> Void = {}) {
        self.responses = responses
        self.whileInFlight = whileInFlight
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await whileInFlight()
        requests.append(
            (
                method: request.httpMethod ?? "",
                // `absoluteString`, not `url.path`: the legacy accessor strips
                // the trailing slash every PostHog collection path ends in, and
                // Django cares. Asserting through `.path` would pin a shape the
                // app does not send.
                url: request.url?.absoluteString ?? "",
                body: request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            )
        )
        let (status, body) = responses.count == 1 ? responses[0] : responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private struct StaticAuth: AuthProvider {
    let region = PostHogRegion.usCloud
    func authorizationHeader() async throws -> String { "Bearer test" }
    func handleUnauthorized() async throws {}
}

/// What PostHog answers a create with: the whole created object.
private let createdAnnotation = """
    {"id": 512, "content": "Deployed 2.14.0", "date_marker": "2023-11-14T22:13:20Z",
     "creation_type": "USR", "scope": "project", "deleted": false,
     "created_at": "2023-11-14T22:40:00Z", "updated_at": "2023-11-14T22:40:00Z",
     "created_by": {"first_name": "Ada", "last_name": "Lovelace", "email": "annotation.author@example.net"},
     "insight_short_id": null, "insight_name": null, "insight_derived_name": null,
     "dashboard_name": null, "emoji": null, "hidden_in_user_interface": null}
    """

@MainActor
@Suite("Annotation writes, app side")
struct AnnotationComposerTests {

    private let marker = Date(timeIntervalSince1970: 1_700_000_000)

    private func client(_ responses: [(Int, String)]) -> (PostHogClient, ScriptedTransport) {
        let transport = ScriptedTransport(responses)
        return (PostHogClient(auth: StaticAuth(), transport: transport), transport)
    }

    @Test("sends one POST to the annotations collection and keeps what came back")
    func createSendsOnePostAndAdoptsTheResponse() async throws {
        let (client, transport) = client([(201, createdAnnotation)])
        let store = AnnotationsStore()
        let composer = AnnotationComposer()

        let ok = await composer.create(
            content: "Deployed 2.14.0",
            dateMarker: marker,
            target: .project,
            store: store,
            client: client,
            projectID: 1_001
        )

        #expect(ok)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "POST")
        // Trailing slash intact.
        #expect(requests[0].url.hasSuffix("/api/projects/1001/annotations/"))
        #expect(requests[0].body.contains("Deployed 2.14.0"))

        // The server's row replaced the placeholder rather than sitting beside
        // it: one annotation, PostHog's id, PostHog's author.
        #expect(store.totalCount == 1)
        #expect(store.annotations.first?.id == 512)
        #expect(store.annotations.first?.createdByName == "Ada Lovelace")
        #expect(composer.successCount == 1)
        #expect(composer.message == nil)
    }

    /// The row has to be there *before* the answer is, or the feature is not
    /// faster than the console — which is its whole justification.
    @Test("shows the row while the request is still out, then settles on the real one")
    func rowIsVisibleBeforeTheServerAnswers() async throws {
        let store = AnnotationsStore()
        let composer = AnnotationComposer()
        // Captured inside the transport, so it is read at the one instant that
        // proves the claim: the request has been sent and nothing has answered.
        let pending = Pending()

        let transport = ScriptedTransport([(201, createdAnnotation)]) {
            let snapshot = await MainActor.run { store.annotations }
            await pending.record(snapshot)
        }
        let client = PostHogClient(auth: StaticAuth(), transport: transport)

        let ok = await composer.create(
            content: "Deployed 2.14.0", dateMarker: marker, target: .project,
            store: store, client: client, projectID: 1
        )
        #expect(ok)

        let inFlight = await pending.snapshot
        #expect(inFlight.count == 1)
        let placeholder = try #require(inFlight.first)
        // Negative, so a rollback can find its own row and no real annotation can
        // be caught by it.
        #expect(placeholder.id < 0)
        #expect(placeholder.displayContent == "Deployed 2.14.0")
        #expect(placeholder.effectiveDate == marker)
        // Nothing the server owns is guessed at while it is pending.
        #expect(placeholder.createdByName == nil)
        #expect(placeholder.createdAt == nil)

        // …and the server's row replaced it rather than joining it.
        #expect(store.totalCount == 1)
        #expect(store.annotations.first?.id == 512)
    }

    /// A refused write must leave the list exactly as it found it. The list is
    /// seeded first, so this also catches a rollback that clears too much.
    @Test("withdraws only its own row when PostHog refuses")
    func rollbackRemovesOnlyThePlaceholder() async throws {
        let (client, _) = client([(403, #"{"detail": "nope"}"#)])
        let store = AnnotationsStore()
        let existing = Annotation(
            id: 99, content: "An earlier note", dateMarker: marker, scope: .project
        )
        store.insert(existing)
        let composer = AnnotationComposer()

        let ok = await composer.create(
            content: "Deployed 2.14.0", dateMarker: marker, target: .project,
            store: store, client: client, projectID: 1
        )

        #expect(!ok)
        #expect(store.totalCount == 1)
        #expect(store.annotations.first?.id == 99)
        #expect(composer.failureCount == 1)
        #expect(composer.successCount == 0)
        // A read-scoped key passes every preflight the app runs and fails only
        // here, so this message is the first place the scope can be named.
        let message = try #require(composer.message)
        #expect(message.kind == .failure)
        #expect(message.text.contains("annotation:write"))
    }

    @Test("names the credential, not the scope, when the key itself was rejected")
    func unauthorizedIsNotReportedAsAMissingScope() async throws {
        let (client, _) = client([(401, #"{"detail": "invalid"}"#)])
        let store = AnnotationsStore()
        let composer = AnnotationComposer()

        _ = await composer.create(
            content: "c", dateMarker: marker, target: .project,
            store: store, client: client, projectID: 1
        )

        let text = try #require(composer.message?.text)
        #expect(text.contains("rejected"))
        #expect(!text.contains("annotation:write"))
        #expect(store.isEmpty)
    }

    /// PostHog answering with something undecodable is the one failure where
    /// "it wasn't saved" would be the wrong thing to say — the write may well
    /// have landed.
    @Test("does not claim the write failed when only the response was unreadable")
    func undecodableResponseSaysTheWriteMayHaveLanded() async throws {
        let (client, _) = client([(201, #"{"unexpected": true}"#)])
        let store = AnnotationsStore()
        let composer = AnnotationComposer()

        let ok = await composer.create(
            content: "c", dateMarker: marker, target: .project,
            store: store, client: client, projectID: 1
        )

        #expect(!ok)
        let text = try #require(composer.message?.text)
        #expect(text.contains("may have been saved"))
        // The row is still withdrawn: showing one this app cannot confirm would
        // be a different lie.
        #expect(store.isEmpty)
    }

    /// Grouping is derived from the flat list, so an inserted row lands under the
    /// day it *marks* — not under today, and not in a bucket of its own.
    @Test("files a new annotation under the day it marks, beside what else happened")
    func optimisticRowGroupsByItsMarker() {
        let store = AnnotationsStore()
        let sameDay = marker.addingTimeInterval(3600)
        store.insert(Annotation(id: 1, content: "Earlier", dateMarker: marker, scope: .project))
        store.insert(Annotation(id: -1, content: "Pending", dateMarker: sameDay, scope: .project))

        #expect(store.days.count == 1)
        #expect(store.days.first?.annotations.count == 2)
        // Newest within the day first.
        #expect(store.days.first?.annotations.first?.id == -1)

        store.remove(id: -1)
        #expect(store.days.count == 1)
        #expect(store.days.first?.annotations.map(\.id) == [1])
    }

    /// Two writes in one session must not collide as `Identifiable`; a collapsed
    /// pair would make the second look like it was never written. The ids are
    /// consumed even by a write that fails, which is what makes a retry after a
    /// 403 safe.
    @Test("hands out a distinct placeholder id each time, failures included")
    func placeholderIDsDoNotRepeat() async throws {
        let store = AnnotationsStore()
        let composer = AnnotationComposer()
        let pending = Pending()

        let transport = ScriptedTransport([(403, "{}"), (403, "{}")]) {
            let snapshot = await MainActor.run { store.annotations }
            await pending.record(snapshot)
        }
        let client = PostHogClient(auth: StaticAuth(), transport: transport)

        for _ in 0..<2 {
            _ = await composer.create(
                content: "c", dateMarker: marker, target: .project,
                store: store, client: client, projectID: 1
            )
        }

        let ids = await pending.allIDs
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { $0 < 0 })
        #expect(composer.failureCount == 2)
        #expect(store.isEmpty)
    }
}

/// Collects what the store looked like at each in-flight moment.
private actor Pending {
    private(set) var snapshots: [[Annotation]] = []

    func record(_ annotations: [Annotation]) { snapshots.append(annotations) }

    var snapshot: [Annotation] { snapshots.last ?? [] }

    /// The placeholder id from each write, in order.
    var allIDs: [Int] { snapshots.compactMap(\.last?.id) }
}

/// The demo route, driven through the real `PostHogAPI` builder.
///
/// Creating an annotation is the app's one write that produces a *new row*, so a
/// demo that swallowed it would show the sheet close and then nothing — which
/// reads as a broken optimistic insert rather than as a missing fixture.
@Suite("Demo annotation writes")
struct DemoAnnotationRouteTests {

    private func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: "https://us.posthog.com" + endpoint.path)!
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        return try await DemoTransport().send(request)
    }

    @Test("a created annotation comes back as one annotation, not as a page")
    func createRoutesToASingleObject() async throws {
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        let (data, response) = try await send(
            PostHogAPI.createAnnotation(
                projectID: 1_001, content: "Deployed 2.14.0", dateMarker: marker
            )
        )

        #expect(response.statusCode == 201)
        let created = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(created.displayContent == "Deployed 2.14.0")
        #expect(created.dateMarker == marker)
        #expect(created.scope == .project)
        #expect(created.creationType == .user)
        // The server fills these in, and the demo has to as well or the row draws
        // with a blank byline where the real one has a name.
        #expect(created.id > 0)
        #expect(created.createdByName == "Demo User")
        #expect(created.createdAt != nil)
    }

    /// The read path is unchanged: annotations were genuinely empty in the
    /// authored fixture, and an empty page is still the honest response for a `GET`.
    @Test("still serves an empty page for the listing")
    func listingIsStillHonestlyEmpty() async throws {
        let (data, response) = try await send(
            PostHogAPI.annotations(projectID: 1_001)
        )
        #expect(response.statusCode == 200)
        let page = try JSONDecoder().decode(Page<Annotation>.self, from: data)
        #expect(page.results.isEmpty)
    }

    /// The schema browser's two queries are **both** `HogQLQuery`, so they have
    /// to be matched before the generic line or the events fixture answers
    /// them — and that fixture has no `table_name` column, so every row would
    /// decode to nil and the browser would draw "No tables" over a 141-table
    /// project.
    ///
    /// Routed through the real builders rather than hand-written SQL, so a
    /// change to the query in the kit breaks this rather than passing against a
    /// string this test happens to contain.
    @Test("the schema browser's queries do not fall through to the events fixture")
    func schemaQueriesRouteToTheirOwnFixtures() async throws {
        let tables = try QueryResponse.decode(
            from: try await send(PostHogAPI.schemaTables(projectID: 1_001)).0
        )
        #expect(tables.columns.contains("table_name"))
        #expect(!tables.rows.isEmpty)

        // Each authored table answers with its own columns…
        for table in ["events", "persons", "sessions"] {
            let columns = try QueryResponse.decode(
                from: try await send(
                    PostHogAPI.schemaColumns(projectID: 1_001, table: table)
                ).0
            )
            #expect(!columns.rows.isEmpty, "expected authored columns for \(table)")
        }

        // …and every other table answers empty rather than being served another
        // table's columns, which would be confidently wrong rather than blank.
        let unrecorded = try QueryResponse.decode(
            from: try await send(
                PostHogAPI.schemaColumns(projectID: 1_001, table: "raw_sessions")
            ).0
        )
        #expect(unrecorded.rows.isEmpty)
    }
}
