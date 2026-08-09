import Foundation
import GetHogKit
import Testing

@testable import GetHog

private enum ProjectSearchDestinationResource: Sendable {
    case persons
    case cohorts
    case playlists
}

/// Publishes project 1 once, then holds both a project-1 refresh and the
/// replacement project-2 load so the test controls which response lands last.
private actor OutOfOrderProjectSearchDestinationTransport: HTTPTransport {
    private let resource: ProjectSearchDestinationResource
    private var projectOneRequests = 0
    private var oldRefreshStarted = false
    private var newScopeStarted = false
    private var releaseOldRefresh: CheckedContinuation<Void, Never>?
    private var releaseNewScope: CheckedContinuation<Void, Never>?

    init(resource: ProjectSearchDestinationResource) {
        self.resource = resource
    }

    func waitForOldRefresh() async {
        while !oldRefreshStarted { await Task.yield() }
    }

    func waitForNewScope() async {
        while !newScopeStarted { await Task.yield() }
    }

    func releaseOldProjectRefresh() {
        releaseOldRefresh?.resume()
        releaseOldRefresh = nil
    }

    func releaseNewProjectLoad() {
        releaseNewScope?.resume()
        releaseNewScope = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let projectID = request.url?.pathComponents
            .drop(while: { $0 != "projects" })
            .dropFirst()
            .first
            .flatMap(Int.init) ?? 0

        if projectID == 1 {
            projectOneRequests += 1
            if projectOneRequests == 2 {
                oldRefreshStarted = true
                await withCheckedContinuation { releaseOldRefresh = $0 }
            }
        } else if projectID == 2 {
            newScopeStarted = true
            await withCheckedContinuation { releaseNewScope = $0 }
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (payload(projectID: projectID), response)
    }

    private func payload(projectID: Int) -> Data {
        let body: String
        switch resource {
        case .persons:
            body = """
            {"count":1,"next":null,"previous":null,"results":[
              {"id":"person-\(projectID)","distinct_ids":["synthetic-person-\(projectID)"],
               "properties":{"name":"Project \(projectID) person"}}
            ]}
            """
        case .cohorts:
            body = """
            {"count":1,"next":null,"previous":null,"results":[
              {"id":\(projectID * 100 + 1),"name":"Project \(projectID) cohort","deleted":false}
            ]}
            """
        case .playlists:
            body = """
            {"count":1,"next":null,"previous":null,"results":[
              {"id":\(projectID * 100 + 1),"short_id":"project-\(projectID)-playlist",
               "name":"Project \(projectID) playlist","type":"collection",
               "pinned":false,"is_synthetic":false}
            ]}
            """
        }
        return Data(body.utf8)
    }
}

@Suite("Project-search native destination scope")
@MainActor
struct ProjectSearchDestinationScopeTests {
    private func client(_ transport: some HTTPTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
    }

    @Test("a late old-project person response cannot publish into the new scope")
    func lateOldProjectPersonsAreDiscarded() async {
        let transport = OutOfOrderProjectSearchDestinationTransport(resource: .persons)
        let client = client(transport)
        let store = PeopleStore()

        await store.loadPersons(client: client, projectID: 1, search: nil)
        #expect(store.persons.map(\.id) == ["person-1"])

        let oldRefresh = Task {
            await store.loadPersons(client: client, projectID: 1, search: nil)
        }
        await transport.waitForOldRefresh()

        let newScope = Task {
            await store.loadPersons(client: client, projectID: 2, search: nil)
        }
        await transport.waitForNewScope()
        #expect(store.persons.isEmpty)

        await transport.releaseNewProjectLoad()
        await newScope.value
        #expect(store.persons.map(\.id) == ["person-2"])

        await transport.releaseOldProjectRefresh()
        await oldRefresh.value
        #expect(store.persons.map(\.id) == ["person-2"])
    }

    @Test("a late old-project cohort response cannot publish into the new destination scope")
    func lateOldProjectCohortsAreDiscarded() async {
        let transport = OutOfOrderProjectSearchDestinationTransport(resource: .cohorts)
        let client = client(transport)
        let store = PeopleStore()

        await store.loadCohorts(client: client, projectID: 1)
        #expect(store.cohorts.map(\.name) == ["Project 1 cohort"])

        let oldRefresh = Task {
            await store.loadCohorts(client: client, projectID: 1, force: true)
        }
        await transport.waitForOldRefresh()

        let newScope = Task {
            await store.loadCohorts(client: client, projectID: 2, force: true)
        }
        await transport.waitForNewScope()
        #expect(store.cohorts.isEmpty)

        await transport.releaseNewProjectLoad()
        await newScope.value
        #expect(store.cohorts.map(\.name) == ["Project 2 cohort"])

        await transport.releaseOldProjectRefresh()
        await oldRefresh.value
        #expect(store.cohorts.map(\.name) == ["Project 2 cohort"])
    }

    @Test("a late old-project playlist response cannot publish into the new destination scope")
    func lateOldProjectPlaylistsAreDiscarded() async {
        let transport = OutOfOrderProjectSearchDestinationTransport(resource: .playlists)
        let client = client(transport)
        let store = PlaylistsStore()

        await store.load(client: client, projectID: 1)
        #expect(store.playlists.map(\.name) == ["Project 1 playlist"])

        let oldRefresh = Task {
            await store.load(client: client, projectID: 1)
        }
        await transport.waitForOldRefresh()

        let newScope = Task {
            await store.load(client: client, projectID: 2)
        }
        await transport.waitForNewScope()
        #expect(store.playlists.isEmpty)

        await transport.releaseNewProjectLoad()
        await newScope.value
        #expect(store.playlists.map(\.name) == ["Project 2 playlist"])

        await transport.releaseOldProjectRefresh()
        await oldRefresh.value
        #expect(store.playlists.map(\.name) == ["Project 2 playlist"])
    }
}
