import Foundation
import Observation
import GetHogKit

// Search across the whole project, backed by `GET /file_system/`.
//
// PostHog's own object index answers "what is in this project" without one
// request per resource, spanning insights, dashboards, flags, surveys, cohorts,
// replay playlists and pipeline functions. On a phone that is worth more than
// any one product screen: it reaches everything without the user first knowing
// which tab an object lives in.
//
// Everything below the request is deliberately pure. Filtering, grouping and the
// decision about where a row goes are the parts that can be wrong in a way a
// screenshot would not show, so they are separated from the view and tested.

// MARK: - Routing

/// Where a result goes when it is tapped.
///
/// Every case is something the app can actually do. Nothing here invents a
/// destination: a type this app has no screen for routes to PostHog's own page
/// using the link the index already carries, and a row with nothing behind it
/// admits that rather than presenting itself as tappable.
enum ProjectSearchRoute: Hashable {
    /// `DashboardDetailView` already resolves itself from an id, which is
    /// exactly what a `file_system` row carries.
    case dashboard(id: Int)
    /// A saved insight, by the console handle the index row already carries.
    ///
    /// This was `.web` until the insight library shipped, and it was the single
    /// largest thing on this screen leaving the app: insights are 140 of the 200
    /// rows PostHog's index returns for this project. `ref` on an insight row is
    /// the `short_id` — verified against both the live index and the demo
    /// fixture, where every insight row reads `"ref": "demo0001"` beside
    /// `"href": "/insights/demo0001"` — which is exactly what
    /// `SavedInsightDetailView` resolves from.
    case insight(shortID: String)
    case featureFlag(id: Int)
    /// A sheet, not a push: `SurveyDetailSheet` brings its own navigation stack
    /// and is presented modally everywhere else in the app.
    case survey(id: String)
    /// `href` with its leading slash removed, ready for `AppModel.webURL(path:)`.
    case web(path: String)
    /// Nothing behind the row at all.
    case unavailable

    /// Whether the object opens in the app rather than in a browser.
    ///
    /// Reinforcement only — a row that leaves the app says so in words too.
    var opensInApp: Bool {
        switch self {
        case .dashboard, .insight, .featureFlag, .survey: true
        case .web, .unavailable: false
        }
    }

    /// The pushable form, when there is one.
    func push(named name: String) -> ProjectSearchPush? {
        switch self {
        case .dashboard(let id): .dashboard(id: id, name: name)
        case .insight(let shortID): .insight(shortID: shortID, name: name)
        case .featureFlag(let id): .featureFlag(id: id, name: name)
        case .survey, .web, .unavailable: nil
        }
    }
}

/// The results that open by pushing.
///
/// A type of its own rather than a subset of `ProjectSearchRoute`, so a route
/// that is not a push — a survey sheet, a web link — cannot reach
/// `navigationDestination` and land the user on a blank screen.
enum ProjectSearchPush: Hashable {
    case dashboard(id: Int, name: String)
    case insight(shortID: String, name: String)
    case featureFlag(id: Int, name: String)
}

// MARK: - Results

/// One object type and the rows that matched under it.
struct ProjectSearchGroup: Identifiable {
    let type: FileSystemItemType
    let entries: [FileSystemEntry]

    var id: String { type.rawValue }

    /// True when none of these rows can be opened in the app, which is a fact
    /// about the *type* and therefore worth stating once per group rather than
    /// once per row.
    var routesToWeb: Bool {
        entries.first.map { !ProjectSearchIndex.route(for: $0).opensInApp } ?? false
    }
}

/// Filtering, grouping and routing over the project index.
enum ProjectSearchIndex {

    // MARK: Filtering

    /// Matches an object's own name, or any folder above it.
    ///
    /// Folder segments are matched one at a time rather than against
    /// `folderDisplayPath`: that string is joined with `" / "` so it reads
    /// cleanly beside a name that contains a slash of its own, which means a
    /// query typed as `Unfiled/Cohorts` would miss it while `Cohorts` hit.
    /// Per-segment matching gives the same answer for both.
    static func matches(_ entry: FileSystemEntry, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if entry.name.localizedCaseInsensitiveContains(needle) { return true }
        return entry.folderSegments.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// Everything matching `query`, grouped by type.
    static func results(in entries: [FileSystemEntry], query: String) -> [ProjectSearchGroup] {
        grouped(objects(in: entries).filter { matches($0, query: query) })
    }

    /// The default state, and the reason this screen is worth opening with no
    /// query typed at all.
    ///
    /// `last_viewed_at` is null on all but a handful of rows. The kit's
    /// comparator leaves those unranked rather than sorting them as "opened
    /// longest ago", and they are dropped here for the same reason: never opened
    /// is not old history, and 190 of them would bury the five rows that are.
    static func recentlyViewed(in entries: [FileSystemEntry], limit: Int = 15) -> [FileSystemEntry] {
        Array(
            objects(in: entries)
                .filter { $0.lastViewedAt != nil }
                .sorted(by: FileSystemEntry.mostRecentlyViewedFirst)
                .prefix(limit)
        )
    }

    /// The rows that stand for something openable.
    ///
    /// Folders are dropped. PostHog sends them with neither a `ref` nor an
    /// `href` because a folder is a container rather than an object, so there is
    /// nothing to open and no honest destination to offer — and nothing is lost,
    /// because a folder's name is the folder path of everything inside it and
    /// `matches` already searches that.
    private static func objects(in entries: [FileSystemEntry]) -> [FileSystemEntry] {
        entries.filter { $0.type != .folder }
    }

    // MARK: Grouping

    private static func grouped(_ entries: [FileSystemEntry]) -> [ProjectSearchGroup] {
        Dictionary(grouping: entries, by: \.type)
            .map { type, rows in
                ProjectSearchGroup(
                    type: type,
                    entries: rows.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                )
            }
            // Fixed order, never by hit count: a group that reorders itself while
            // the user is still typing costs more than the ranking buys.
            .sorted { ($0.rank, $0.type.title) < ($1.rank, $1.type.title) }
    }

    /// Analysis first, then what ships to users, then what runs in the
    /// background — the same progression the sidebar's own sections follow.
    fileprivate static func rank(_ type: FileSystemItemType) -> Int {
        switch type {
        case .dashboard: 0
        case .insight: 1
        case .featureFlag: 2
        case .survey: 3
        case .cohort: 4
        case .sessionRecordingPlaylist: 5
        case .hogFunction: 6
        // Never reached — folders are filtered out above — but the switch has to
        // be exhaustive, and an unrecognised type belongs at the end either way.
        case .folder: 7
        case .unknown: 8
        }
    }

    // MARK: Routing

    /// The screen, sheet or link a row leads to.
    static func route(for entry: FileSystemEntry) -> ProjectSearchRoute {
        switch entry.type {
        case .dashboard:
            // `ref` is the dashboard's own numeric id, which is precisely what
            // `DashboardDetailView` restores a torn-off window from.
            if let id = entry.ref.flatMap(Int.init) { return .dashboard(id: id) }
        case .insight:
            // An 8-character console handle, not a number — and deliberately not
            // coerced to one. `SavedInsightDetailView` accepts either spelling
            // and resolves them by different routes.
            if let ref = entry.ref, !ref.isEmpty { return .insight(shortID: ref) }
        case .featureFlag:
            if let id = entry.ref.flatMap(Int.init) { return .featureFlag(id: id) }
        case .survey:
            // A UUID string here, not a number.
            if let ref = entry.ref, !ref.isEmpty { return .survey(id: ref) }
        case .cohort, .sessionRecordingPlaylist, .hogFunction, .folder, .unknown:
            break
        }
        return webRoute(for: entry)
    }

    /// PostHog's own page for the object.
    ///
    /// Built from `href` rather than reassembled from `type` and `ref`: the
    /// console owns its URL scheme and has changed it before, and `href` is the
    /// link it built for itself.
    private static func webRoute(for entry: FileSystemEntry) -> ProjectSearchRoute {
        guard let href = entry.href, !href.isEmpty else { return .unavailable }
        // `AppModel.webURL(path:)` appends to `…/project/<id>`, so the leading
        // slash has to go or the object arrives under an empty path segment.
        let path = String(href.drop(while: { $0 == "/" }))
        return path.isEmpty ? .unavailable : .web(path: path)
    }

    /// Why a whole group leaves the app, in the user's terms.
    ///
    /// Stated per group rather than per row because it is a fact about the type,
    /// and because a reader deserves to know *before* tapping that the row hands
    /// them to a browser.
    static func webFallbackNote(for type: FileSystemItemType) -> String {
        switch type {
        // Insights no longer fall back at all — `route(for:)` sends them to
        // `SavedInsightDetailView` — so this arm is unreachable from the screen,
        // which only renders a note for a group whose rows leave the app.
        //
        // It used to read "GetHog draws an insight as part of the dashboard
        // it sits on, so a saved insight found here opens in PostHog", which was
        // the app's largest self-imposed limit stated to the user on its most
        // general screen. That sentence is gone rather than softened; a note
        // explaining a fallback that no longer happens would be a confident
        // false claim about the app's own behaviour.
        //
        // The arm itself stays because the switch must be exhaustive over a type
        // this app does not own, and because `webRoute(for:)` is still the
        // fallback for an insight row with no `ref` — a row the index cannot
        // name, which is a real if rare shape.
        case .insight:
            "This insight row carries no id GetHog can open, so it opens in PostHog."
        case .cohort:
            "GetHog lists cohorts under People but has no screen for a single one, so these open in PostHog."
        case .sessionRecordingPlaylist:
            "Playlists are listed under Sessions; opening one on its own happens in PostHog."
        case .hogFunction:
            "GetHog reads the pipeline but has no screen for an individual function, so these open in PostHog."
        case .unknown:
            "GetHog doesn't have a screen for this kind of object, so it opens in PostHog."
        case .dashboard, .featureFlag, .survey, .folder:
            "These open in PostHog."
        }
    }
}

private extension ProjectSearchGroup {
    var rank: Int { ProjectSearchIndex.rank(type) }
}

// MARK: - Store

/// The project index, fetched once and filtered in memory.
@MainActor
@Observable
final class ProjectSearchStore {
    private(set) var entries: [FileSystemEntry] = []
    /// What PostHog says the project holds, which can exceed what one page
    /// returned. Stated on screen rather than quietly truncated.
    private(set) var total: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?

    private var loadedProjectID: Int?

    /// One request per project, then nothing.
    ///
    /// This is the whole premise of the screen. The rate-limit budget is
    /// organisation-wide and shared with the user's own production integrations,
    /// so a field that re-queried per keystroke would spend somebody else's
    /// budget on work a phone can do in memory over 200 rows.
    func load(client: PostHogClient, projectID: Int, force: Bool = false) async {
        guard force || loadedProjectID != projectID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<FileSystemEntry> = try await client.send(
                PostHogAPI.fileSystem(projectID: projectID)
            )
            entries = page.results
            total = page.count
            loadedAt = Date()
            loadedProjectID = projectID
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// How much of the project this screen is actually searching.
    ///
    /// A capped page searched silently is the kind of lie this app exists to
    /// avoid: a user who cannot find an object needs to know whether it is
    /// missing or merely past the cut.
    var coverageSummary: String? {
        guard !entries.isEmpty else { return nil }
        let shown = entries.count
        if let total, total > shown {
            return "Searching the first \(shown) of \(total) objects in this project."
        }
        return shown == 1 ? "1 object in this project." : "\(shown) objects in this project."
    }
}
