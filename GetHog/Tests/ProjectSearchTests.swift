import Foundation
import GetHogKit
import SwiftUI
import Testing

@testable import GetHog

/// Search over the project object index.
///
/// Everything asserted here is a decision that is invisible in a screenshot: a
/// row filed under the wrong heading, a folder offered as a destination, or —
/// worst — a result that opens the wrong object. The screen itself is thin on
/// purpose so that all of it can be checked without one.
@Suite("Project search")
struct ProjectSearchTests {

    // MARK: - Fixtures

    /// The demo fixture, read through `DemoTransport` exactly as the app reads
    /// it, so a fixture that stopped decoding would fail here rather than
    /// silently emptying the screen in demo mode.
    private func demoIndex() async throws -> [FileSystemEntry] {
        let url = URL(string: "https://us.posthog.com/api/projects/1001/file_system/?limit=300")!
        let (data, _) = try await DemoTransport().send(URLRequest(url: url))
        return try Page<FileSystemEntry>.decode(from: data).results
    }

    private func entries(_ json: String) throws -> [FileSystemEntry] {
        try JSONDecoder()
            .decode(Page<FileSystemEntry>.self, from: Data(json.utf8))
            .results
    }

    // MARK: - Filtering

    @Test("matches an object by its own name")
    func matchesName() async throws {
        let index = try await demoIndex()
        let groups = ProjectSearchIndex.results(in: index, query: "meteor report")
        let names = groups.flatMap(\.entries).map(\.name)
        #expect(names == ["Meteor report opens"])
    }

    /// The second half of the brief for this field: a user who remembers where
    /// something is filed but not what it is called still finds it.
    @Test("matches every object filed under a folder, by the folder's name")
    func matchesFolder() async throws {
        let index = try await demoIndex()
        let groups = ProjectSearchIndex.results(in: index, query: "Replays")
        let hits = groups.flatMap(\.entries)

        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.type == .sessionRecordingPlaylist })
        // The folder itself is not among them: it is context, not a destination.
        #expect(!hits.contains { $0.type == .folder })
    }

    /// A folder segment can contain a slash of its own, so the query has to be
    /// tested against the *segments*, never against a re-joined path.
    @Test("matches a name that itself contains a slash")
    func matchesEscapedSlashInName() async throws {
        let index = try await demoIndex()
        let hits = ProjectSearchIndex.results(in: index, query: "Observatory / test").flatMap(\.entries)

        #expect(hits.count == 1)
        #expect(hits.first?.name == "Observatory / test crew")
        #expect(hits.first?.folderDisplayPath == "Sandbox / Groups")
    }

    @Test("an empty query matches everything that is an object")
    func emptyQueryMatchesObjects() async throws {
        let index = try await demoIndex()
        let all = ProjectSearchIndex.results(in: index, query: "").flatMap(\.entries)
        #expect(all.count == index.filter { $0.type != .folder }.count)
        #expect(!all.isEmpty)
    }

    /// A query that is only whitespace is not a query. Trimming it here is what
    /// stops a stray space from emptying the screen.
    @Test("a whitespace query is treated as no query")
    func whitespaceQuery() async throws {
        let index = try await demoIndex()
        let all = ProjectSearchIndex.results(in: index, query: "   ").flatMap(\.entries)
        #expect(all.count == index.filter { $0.type != .folder }.count)
    }

    /// Folders carry neither a `ref` nor an `href`, so a folder row could only
    /// ever be a dead end. It is dropped rather than shown as one.
    @Test("never offers a folder as a result")
    func excludesFolders() async throws {
        let index = try await demoIndex()
        #expect(index.contains { $0.type == .folder })

        let everything = ProjectSearchIndex.results(in: index, query: "Sandbox").flatMap(\.entries)
        #expect(!everything.isEmpty)
        #expect(!everything.contains { $0.type == .folder })
        #expect(!ProjectSearchIndex.recentlyViewed(in: index).contains { $0.type == .folder })
    }

    // MARK: - Grouping

    @Test("groups by type in a fixed order, names sorted inside each group")
    func grouping() async throws {
        let index = try await demoIndex()
        let groups = ProjectSearchIndex.results(in: index, query: "")

        // Analysis first, then what ships to users, then what runs behind them.
        let order = groups.map(\.type)
        #expect(order.firstIndex(of: .dashboard)! < order.firstIndex(of: .insight)!)
        #expect(order.firstIndex(of: .insight)! < order.firstIndex(of: .featureFlag)!)
        #expect(order.firstIndex(of: .featureFlag)! < order.firstIndex(of: .survey)!)
        #expect(order.firstIndex(of: .survey)! < order.firstIndex(of: .cohort)!)

        let insights = try #require(groups.first { $0.type == .insight })
        #expect(insights.entries.map(\.name) == insights.entries.map(\.name).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
    }

    /// `hog_function/transformation` and `hog_function/internal_destination` are
    /// two types, not one type in two folders — reading them as one family would
    /// file a transformation under a destinations heading.
    @Test("keeps the two hog function subtypes in separate groups")
    func hogFunctionSubtypesGroupSeparately() async throws {
        let index = try await demoIndex()
        let groups = ProjectSearchIndex.results(in: index, query: "")

        #expect(groups.contains { $0.type == .hogFunction(subtype: "transformation") })
        #expect(groups.contains { $0.type == .hogFunction(subtype: "internal_destination") })
        // And they read as their subtype, not as the raw wire value.
        let titles = Set(groups.map(\.type.title))
        #expect(titles.contains("Transformation"))
        #expect(titles.contains("Internal destination"))
    }

    // MARK: - Recently viewed

    /// The default state. Rows nobody has opened are unranked rather than
    /// oldest, so they are absent rather than filling the list with fake history.
    @Test("lists only what was actually opened, most recent first")
    func recentlyViewed() async throws {
        let index = try await demoIndex()
        let recent = ProjectSearchIndex.recentlyViewed(in: index)

        #expect(recent.count == index.filter { $0.lastViewedAt != nil }.count)
        #expect(recent.allSatisfy { $0.lastViewedAt != nil })

        let dates = recent.compactMap(\.lastViewedAt)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("caps how much history it shows")
    func recentlyViewedLimit() async throws {
        let index = try await demoIndex()
        #expect(ProjectSearchIndex.recentlyViewed(in: index, limit: 1).count == 1)
    }

    // MARK: - Routing

    /// The three types this app can open itself, each keyed off the id PostHog
    /// put on the row.
    @Test("routes a dashboard, a flag and a survey to the screens the app has")
    func routesToNativeScreens() async throws {
        let index = try await demoIndex()

        let dashboard = try #require(index.first { $0.type == .dashboard })
        #expect(ProjectSearchIndex.route(for: dashboard) == .dashboard(id: 725_101))

        let flag = try #require(index.first { $0.type == .featureFlag })
        #expect(ProjectSearchIndex.route(for: flag) == .featureFlag(id: 710_301))

        let survey = try #require(index.first { $0.type == .survey })
        #expect(
            ProjectSearchIndex.route(for: survey)
                == .survey(id: "018f9000-0000-7000-8000-000000000107")
        )
    }

    /// Everything the app has no screen for goes to PostHog's own page, built
    /// from the link PostHog itself supplied.
    @Test("routes every other type to the console page the row already names")
    func routesToWeb() async throws {
        let index = try await demoIndex()

        // Insight is deliberately not in this list any more: it routes into the
        // app now. `insightsRouteIntoTheApp` below is the assertion that
        // replaced its membership here.
        for type in [FileSystemItemType.hogFunction(subtype: "transformation"),
                     .unknown("notebook")] {
            let entry = try #require(index.first { $0.type == type }, "no \(type.title) row")
            let route = ProjectSearchIndex.route(for: entry)
            guard case .web(let path) = route else {
                Issue.record("\(type.title) routed to \(route), expected a web link")
                continue
            }
            // `AppModel.webURL(path:)` appends to `…/project/<id>`, so a leading
            // slash here would put the object under an empty path segment.
            #expect(!path.hasPrefix("/"))
            #expect(entry.href == "/" + path)
        }
    }

    /// `ref` on an insight row is the console handle, which is exactly what
    /// `SavedInsightDetailView` resolves from, so nothing has to be derived.
    @Test("routes an insight into the app using the handle the row already carries")
    func insightsRouteIntoTheApp() async throws {
        let index = try await demoIndex()
        let insight = try #require(index.first { $0.type == .insight })

        let ref = try #require(insight.ref)
        #expect(ProjectSearchIndex.route(for: insight) == .insight(shortID: ref))
        #expect(ProjectSearchIndex.route(for: insight).opensInApp)
        // The handle and the console href have to agree, or the "Open in
        // PostHog" menu item would name a different insight from the row.
        #expect(insight.href == "/insights/\(ref)")
    }

    /// An insight row with nothing to name it still has to do something honest.
    /// The index has produced rows with a null `ref` for other types, and the
    /// fallback is the same one every unroutable row takes.
    @Test("an insight row with no id falls back to the console rather than a blank screen")
    func insightWithoutRefFallsBack() throws {
        let rows = try entries("""
        {"count": 2, "next": null, "previous": null, "results": [
          {"id": "a", "path": "Unfiled/Insights/Nameless", "depth": 3, "type": "insight",
           "ref": null, "href": "/insights", "shortcut": false,
           "last_viewed_at": null, "user_access_level": null},
          {"id": "b", "path": "Unfiled/Insights/Linkless", "depth": 3, "type": "insight",
           "ref": null, "href": null, "shortcut": false,
           "last_viewed_at": null, "user_access_level": null}
        ]}
        """)

        #expect(ProjectSearchIndex.route(for: rows[0]) == .web(path: "insights"))
        #expect(ProjectSearchIndex.route(for: rows[1]) == .unavailable)
    }

    @Test("offers no destination for a row that carries no link at all")
    func folderHasNoDestination() async throws {
        let index = try await demoIndex()
        let folder = try #require(index.first { $0.type == .folder })
        #expect(folder.href == nil)
        #expect(ProjectSearchIndex.route(for: folder) == .unavailable)
    }

    /// A dashboard id that is not a number cannot open the dashboard screen. It
    /// falls back to the console rather than being dropped or, worse, coerced.
    @Test("falls back to the console when an id is not the shape the screen needs")
    func unusableIdFallsBack() throws {
        let rows = try entries("""
        {"count": 2, "next": null, "previous": null, "results": [
          {"id": "a", "path": "Unfiled/Dashboards/Odd one", "depth": 3, "type": "dashboard",
           "ref": "not-a-number", "href": "/dashboard/not-a-number", "shortcut": false,
           "last_viewed_at": null, "user_access_level": null},
          {"id": "b", "path": "Unfiled/Dashboards/Nameless", "depth": 3, "type": "dashboard",
           "ref": null, "href": null, "shortcut": false,
           "last_viewed_at": null, "user_access_level": null}
        ]}
        """)

        #expect(ProjectSearchIndex.route(for: rows[0]) == .web(path: "dashboard/not-a-number"))
        #expect(ProjectSearchIndex.route(for: rows[1]) == .unavailable)
    }

    /// Only three routes are pushes. The others are a modal sheet and a link
    /// out, and handing either to `navigationDestination` would push a blank
    /// screen.
    @Test("only the pushable routes produce a push")
    func pushableRoutes() {
        #expect(
            ProjectSearchRoute.dashboard(id: 7).push(named: "D")
                == .dashboard(id: 7, name: "D")
        )
        #expect(
            ProjectSearchRoute.featureFlag(id: 9).push(named: "k")
                == .featureFlag(id: 9, name: "k")
        )
        #expect(
            ProjectSearchRoute.insight(shortID: "demo0001").push(named: "I")
                == .insight(shortID: "demo0001", name: "I")
        )
        #expect(ProjectSearchRoute.survey(id: "s").push(named: "S") == nil)
        #expect(ProjectSearchRoute.web(path: "insights/x").push(named: "I") == nil)
        #expect(ProjectSearchRoute.unavailable.push(named: "F") == nil)
    }

    /// Drives the tint and the "Web" pill, so it has to agree with the routing
    /// or the row promises something the tap does not do.
    @Test("a group knows whether its rows leave the app")
    func groupKnowsWhereItGoes() async throws {
        let index = try await demoIndex()
        let groups = ProjectSearchIndex.results(in: index, query: "")

        #expect(try #require(groups.first { $0.type == .dashboard }).routesToWeb == false)
        #expect(try #require(groups.first { $0.type == .featureFlag }).routesToWeb == false)
        #expect(try #require(groups.first { $0.type == .survey }).routesToWeb == false)
        // Flipped when the insight library shipped: this group used to be the
        // largest one on the screen wearing a "Web" pill.
        #expect(try #require(groups.first { $0.type == .insight }).routesToWeb == false)
        #expect(try #require(groups.first { $0.type == .cohort }).routesToWeb == false)
        #expect(
            try #require(groups.first { $0.type == .sessionRecordingPlaylist }).routesToWeb
                == false
        )
    }

    @Test("routes cohorts and replay playlists into their native detail screens")
    func cohortsAndPlaylistsRouteNatively() async throws {
        let index = try await demoIndex()
        let cohort = try #require(index.first { $0.type == .cohort })
        let playlist = try #require(index.first { $0.type == .sessionRecordingPlaylist })

        #expect(ProjectSearchIndex.route(for: cohort) == .cohort(id: 730_004))
        #expect(
            ProjectSearchIndex.route(for: playlist)
                == .sessionRecordingPlaylist(shortID: "example-orbit-overview")
        )
        #expect(
            ProjectSearchIndex.route(for: cohort).push(named: cohort.name)
                == .cohort(id: 730_004, name: cohort.name)
        )
        #expect(
            ProjectSearchIndex.route(for: playlist).push(named: playlist.name)
                == .sessionRecordingPlaylist(
                    shortID: "example-orbit-overview",
                    name: playlist.name
                )
        )
    }

    /// Every group that leaves the app has to be able to say so in the user's
    /// own terms; a blank footer would leave the "Web" pill unexplained.
    @Test("every type has a reason it can state for opening in PostHog")
    func webFallbackNotes() async throws {
        let index = try await demoIndex()
        for group in ProjectSearchIndex.results(in: index, query: "") where group.routesToWeb {
            let note = ProjectSearchIndex.webFallbackNote(for: group.type)
            #expect(!note.isEmpty)
            #expect(note.contains("PostHog"))
        }
    }

    // MARK: - Demo fixture

    /// The demo has to be able to demonstrate the routing, which it only can if
    /// its index points at objects the other fixtures actually serve.
    @Test("the demo index points at objects the demo's own fixtures contain")
    func demoIndexAgreesWithTheOtherFixtures() async throws {
        let index = try await demoIndex()

        let dashboardIDs = Set(index.filter { $0.type == .dashboard }.compactMap { $0.ref.flatMap(Int.init) })
        let dashboards: Page<DashboardSummary> = try JSONDecoder().decode(
            Page<DashboardSummary>.self,
            from: try await fixture(for: "/api/projects/1001/dashboards/")
        )
        #expect(dashboardIDs.isSubset(of: Set(dashboards.results.map(\.id))))

        let flagIDs = Set(index.filter { $0.type == .featureFlag }.compactMap { $0.ref.flatMap(Int.init) })
        let flags: Page<FeatureFlag> = try JSONDecoder().decode(
            Page<FeatureFlag>.self,
            from: try await fixture(for: "/api/projects/1001/feature_flags/")
        )
        #expect(flagIDs.isSubset(of: Set(flags.results.map(\.id))))

        let insightHandles = Set(index.filter { $0.type == .insight }.compactMap(\.ref))
        let insights: Page<Insight> = try JSONDecoder().decode(
            Page<Insight>.self,
            from: try await fixture(for: "/api/projects/1001/insights/")
        )
        #expect(insightHandles.isSubset(of: Set(insights.results.compactMap(\.shortID))))

        let cohortIDs = Set(index.filter { $0.type == .cohort }.compactMap { $0.ref.flatMap(Int.init) })
        let cohorts: Page<Cohort> = try JSONDecoder().decode(
            Page<Cohort>.self,
            from: try await fixture(for: "/api/projects/1001/cohorts/")
        )
        #expect(cohorts.results.map(\.id) == [730004, 730081, 730082, 730083, 730084, 730085])
        #expect(cohortIDs.isSubset(of: Set(cohorts.results.map(\.id))))

        let playlistHandles = Set(index.filter { $0.type == .sessionRecordingPlaylist }.compactMap(\.ref))
        let playlists: Page<SessionRecordingPlaylist> = try JSONDecoder().decode(
            Page<SessionRecordingPlaylist>.self,
            from: try await fixture(for: "/api/projects/1001/session_recording_playlists/")
        )
        #expect(playlistHandles.isSubset(of: Set(playlists.results.map(\.shortID))))

        let surveyIDs = Set(index.filter { $0.type == .survey }.compactMap(\.ref))
        let surveys: Page<Survey> = try JSONDecoder().decode(
            Page<Survey>.self,
            from: try await fixture(for: "/api/projects/1001/surveys/")
        )
        #expect(surveyIDs.isSubset(of: Set(surveys.results.map(\.id))))
    }

    private func fixture(for path: String) async throws -> Data {
        let url = URL(string: "https://us.posthog.com" + path)!
        let (data, _) = try await DemoTransport().send(URLRequest(url: url))
        return data
    }
}

private actor OutOfOrderProjectIndexTransport: HTTPTransport {
    private var firstStarted = false
    private var releaseFirst: CheckedContinuation<Void, Never>?

    func waitForFirstRequest() async {
        while !firstStarted { await Task.yield() }
    }

    func releaseFirstRequest() {
        releaseFirst?.resume()
        releaseFirst = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let projectID = request.url?.pathComponents
            .drop(while: { $0 != "projects" })
            .dropFirst()
            .first
            .flatMap(Int.init) ?? 0

        if projectID == 1 {
            firstStarted = true
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
            }
        }

        let body = """
        {"count":1,"next":null,"previous":null,"results":[
          {"id":"synthetic-index-\(projectID)",
           "path":"Synthetic/Dashboards/Project \(projectID) dashboard",
           "depth":3,"type":"dashboard","ref":"\(projectID)",
           "href":"/dashboard/\(projectID)","shortcut":false,
           "last_viewed_at":null,"user_access_level":"viewer"}
        ]}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

@Suite("Project-search project recovery")
@MainActor
struct ProjectSearchStoreRecoveryTests {
    private func client(_ transport: some HTTPTransport) -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "phx_synthetic", region: .usCloud),
            transport: transport
        )
    }

    @Test("a late old-project index response cannot replace the new project")
    func lateProjectResponseIsDiscarded() async {
        let transport = OutOfOrderProjectIndexTransport()
        let store = ProjectSearchStore()
        let first = Task { await store.load(client: client(transport), projectID: 1) }
        await transport.waitForFirstRequest()

        await store.load(client: client(transport), projectID: 2)
        await transport.releaseFirstRequest()
        await first.value

        #expect(store.entries.map(\.name) == ["Project 2 dashboard"])
        #expect(store.total == 1)
    }
}

/// Where search lives, and whether everything else is still reachable.
///
/// Written after the entry point failed on device. Search was declared as a
/// sixth `Tab` with `TabRole.search`, on the reading that the role places it
/// outside the four-slot bar. On an iPhone 17 running iOS 26 it did not draw at
/// all: the bar showed `Dashboards · Events · Sessions · Flags · More` and there
/// was no search affordance anywhere. None of that is visible from a compiler,
/// so what can be checked is the arithmetic underneath it — five slots, and
/// every destination reachable from one of them.
@MainActor
@Suite("Tab structure")
struct AppTabStructureTests {

    /// A suite of its own rather than `.standard`, so nothing here writes the
    /// bar of whatever test runs next in the same process.
    private func prefs() -> NavPreferences {
        let suite = "AppTabStructureTests"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return NavPreferences(defaults: UserDefaults(suiteName: suite)!)
    }


    /// A phone's tab bar holds five. A sixth is what went missing.
    @Test("declares exactly five tabs for the compact bar")
    func compactBarHoldsFive() {
        #expect(prefs().alwaysVisible.count == 5)
        #expect(prefs().alwaysVisible.contains(.search))
    }

    @Test("compact iPad indexes the complement of its system-customized tab bar")
    func compactIPadUsesSystemTabCustomization() {
        let phoneTabs: [AppTab] = [.logs, .errorTracking, .inbox, .health]
        let hiddenPrimary = AppTab.events
        let regularWidthSecondary = AppTab.people

        let loose = CompactSearchIndexPolicy.looseTabs(
            isPad: true,
            phoneTabs: phoneTabs,
            iPadTabBarVisibility: { tab in
                if tab == hiddenPrimary { return .hidden }
                if tab == regularWidthSecondary { return .visible }
                return .automatic
            }
        )
        let indexed = AppTab.groupedScreens(excluding: loose).flatMap(\.tabs) + AppTab.utility

        // Only the four authored primary tabs are declared as compact iPad
        // product tabs. Automatic means their authored visibility; hiding one
        // restores it to Search. A secondary made visible in the regular-width
        // sidebar is not declared in the compact bar and must remain indexed.
        #expect(loose == AppTab.primary.filter { $0 != hiddenPrimary })
        #expect(indexed.contains(.people))
        #expect(indexed.contains(.events))
        #expect(indexed.contains(.logs))
        #expect(!indexed.contains(.dashboards))

        // With no stored system decision, the same policy must retain the
        // authored iPad defaults rather than interpreting `.automatic` as all
        // products visible and emptying the index.
        #expect(
            CompactSearchIndexPolicy.looseTabs(
                isPad: true,
                phoneTabs: phoneTabs,
                iPadTabBarVisibility: { _ in .automatic }
            ) == AppTab.primary
        )
        #expect(
            CompactSearchIndexPolicy.looseTabs(
                isPad: false,
                phoneTabs: phoneTabs,
                iPadTabBarVisibility: { _ in .visible }
            ) == phoneTabs
        )
    }

    /// Every destination is reachable: it either has a tab of its own at both
    /// widths, or it sits on the search tab's stack in compact and has a sidebar
    /// row in regular. A case in neither list is a screen nothing can open —
    /// which is exactly the state search was in.
    @Test("every tab is reachable from somewhere")
    func everyTabIsReachable() {
        let nav = prefs()
        let reachable = Set(nav.alwaysVisible).union(nav.indexedScreens)
        let unreachable = Set(AppTab.allCases).subtracting(reachable)
        #expect(unreachable.isEmpty, "unreachable: \(unreachable.map(\.title))")
    }

    @Test("no tab is declared in two places at once")
    func noDuplicateDeclarations() {
        let nav = prefs()
        let declared = nav.alwaysVisible + nav.indexedScreens
        #expect(Set(declared).count == declared.count)
    }

    /// `open(_:)` pushes exactly what `secondary` contains, so search staying out
    /// of it is what makes `GETHOG_TAB=search` land on the *root* of the stack
    /// rather than inside it — one navigation bar, not two.
    @Test("search is a tab root, never something pushed onto a stack")
    func searchIsNeverPushed() {
        #expect(!AppTab.productScreens.contains(.search))
        #expect(!AppTab.sections.flatMap(\.tabs).contains(.search))
        #expect(!AppTab.utility.contains(.search))
    }

    /// The four product tabs are unchanged by all of this: search took the fifth
    /// slot, which was the index's, not one of theirs.
    @Test("the four product tabs kept their slots")
    func primaryTabsUnchanged() {
        #expect(AppTab.primary == [.dashboards, .events, .sessions, .flags])
    }
}

/// The app's own screens, now searched by the same field as the project's
/// objects.
@MainActor
@Suite("Screen index")
struct ScreenIndexTests {

    @Test("finds a screen by name")
    func findsScreen() {
        #expect(ScreenIndexSections.hasMatches(query: "Annotations", loose: AppTab.primary))
        #expect(ScreenIndexSections.hasMatches(query: "annotations", loose: AppTab.primary))
    }

    /// The no-query state is the whole index, which is what the tab has to show
    /// when it is opened for navigation rather than for search.
    @Test("an empty or whitespace query keeps the whole index")
    func emptyQueryKeepsIndex() {
        #expect(ScreenIndexSections.hasMatches(query: "", loose: AppTab.primary))
        #expect(ScreenIndexSections.hasMatches(query: "   ", loose: AppTab.primary))
    }

    /// Drives which empty state the screen shows, so it has to be able to say no.
    @Test("reports no screens when nothing matches")
    func reportsNoMatches() {
        #expect(!ScreenIndexSections.hasMatches(query: "zzzzqqq", loose: AppTab.primary))
    }

    /// Every screen behind the fifth tab is in the index. One that fell out of
    /// `sections` and `utility` would be unreachable on a phone entirely.
    @Test("indexes every screen the tab bar cannot hold")
    func indexesEverySecondaryScreen() {
        let suite = "ScreenIndexTests"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let nav = NavPreferences(defaults: UserDefaults(suiteName: suite)!)
        for tab in nav.indexedScreens {
            #expect(
                ScreenIndexSections.hasMatches(query: tab.title, loose: nav.barTabs),
                "\(tab.title) is not findable"
            )
        }
    }

    /// The other half of the exactly-once rule, seen from the index's side.
    @Test("the index holds exactly what the bar does not")
    func indexIsTheComplementOfTheBar() {
        let bar: [AppTab] = [.logs, .events, .sessions, .flags]
        #expect(!ScreenIndexSections.hasMatches(query: "Logs", loose: bar))
        #expect(ScreenIndexSections.hasMatches(query: "Dashboards", loose: bar))
    }
}
