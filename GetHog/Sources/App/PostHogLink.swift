import Foundation

// Inbound links, which is `AppModel.webURL(path:)` run backwards.
//
// **These are not universal links, and cannot be.** A universal link needs an
// `apple-app-site-association` file served from the root of every host it
// claims — `us.posthog.com`, `eu.posthog.com` and whatever host a self-hosted
// deployment runs on. We control none of them, and PostHog would have to ship
// this app's team id in their own file for iOS to honour the association. So
// tapping a posthog.com link in Mail still opens Safari, and always will until
// PostHog publishes that file.
//
// What is left is a custom scheme, `gethog://`, which needs nobody's
// cooperation, plus the same parser applied to a posthog.com URL the user
// pastes or shares into the app. That covers the case this is actually for —
// somebody sends you a link to an issue and you want it on your phone — without
// claiming a capability the app does not have.
//
// The parsing is pure and lives here rather than in a view, because "which
// object does this URL name" is the part that can be wrong in a way no
// screenshot would show.

// MARK: - Destination

/// What a link points at.
///
/// Every case is something the app can actually do something honest with —
/// including `insight`, which it can only hand to the console, and says so.
enum PostHogLink: Hashable, Sendable {
    /// One of the app's own screens, with no particular object selected.
    case screen(AppTab)
    case dashboard(id: Int)
    case featureFlag(id: Int)
    case sessionRecording(id: String)
    case errorIssue(id: String)
    /// A saved insight. GetHog draws an insight as a tile on the dashboard it
    /// sits on and has no screen for one on its own — the same limit
    /// `ProjectSearchIndex.webFallbackNote` states on the search screen — so this
    /// resolves to the console rather than to a screen that doesn't exist.
    case insight(shortID: String)

    /// Whether the app has a screen for this, or has to hand it to a browser.
    var opensInApp: Bool {
        switch self {
        case .screen, .dashboard, .featureFlag, .sessionRecording, .errorIssue: true
        case .insight: false
        }
    }

    /// Path under `project/<id>/` in the console, ready for
    /// `AppModel.webURL(path:)`. Nil for a screen, which names no object.
    var webPath: String? {
        switch self {
        case .screen: nil
        case .dashboard(let id): "dashboard/\(id)"
        case .featureFlag(let id): "feature_flags/\(id)"
        case .sessionRecording(let id): "replay/\(id)"
        case .errorIssue(let id): "error_tracking/\(id)"
        case .insight(let shortID): "insights/\(shortID)"
        }
    }
}

/// A destination together with the project it was named in.
///
/// The project is carried separately and never folded into the destination,
/// because it is the half that has to be *checked*: an id read out of a URL for
/// a project this key cannot see must produce a refusal, not another project's
/// dashboard 128.
struct PostHogLinkTarget: Hashable, Sendable {
    /// Nil when the link named no project — a `gethog://` shorthand, which
    /// means "in whichever project is selected".
    let projectID: Int?
    let link: PostHogLink
}

// MARK: - Parsing

enum PostHogLinkParser {

    /// Declared in `CFBundleURLTypes`; nothing else may claim it.
    static let scheme = "gethog"

    /// The console sections this app has a screen for.
    ///
    /// One table, read in both directions, so a generated quick-action URL and
    /// the parser that has to accept it back cannot drift apart. First match
    /// wins when generating, which is why the canonical spelling comes first and
    /// the console's aliases follow it.
    private static let sections: [(path: String, tab: AppTab)] = [
        ("dashboard", .dashboards),
        ("activity", .events),
        ("events", .events),
        ("replay", .sessions),
        ("feature_flags", .flags),
        ("error_tracking", .errorTracking),
        ("web", .webAnalytics),
        ("heatmaps", .clickmap),
        ("persons", .people),
        ("groups", .groups),
        ("sql", .sql),
        ("llm-analytics", .llm),
        ("logs", .logs),
        ("experiments", .experiments),
        ("surveys", .surveys),
        ("early_access_features", .earlyAccess),
        ("pipeline", .pipelines),
        ("annotations", .annotations),
        ("notebooks", .notebooks),
        ("max", .max),
        // No console page of its own — the console's own search is a palette,
        // not a URL — but the scheme needs a way to name the app's fifth tab,
        // which is where a quick action for "find anything" has to land.
        ("search", .search),
    ]

    /// Prefix under which any screen can be named by its own case name.
    ///
    /// Roughly half the app's 28 screens have no console page to be the inbound
    /// form of — Inbox, Health, Renders, Settings and the rest — and `url(for:)`
    /// has to be total, or a quick action could be generated that the parser
    /// then refuses. The console never uses a `/tab/` segment, so this cannot
    /// collide with a real page; in particular it keeps `gethog://tab/settings`
    /// (this app's own settings) distinct from the console's `/settings`, which
    /// is project configuration and something this app has no screen for.
    private static let tabPrefix = "tab"

    /// Console paths that live *under* a section but are still that section's
    /// list rather than one object in it.
    ///
    /// Without this, `/replay/recent` reads as a recording called "recent" and
    /// pushes a detail screen whose only possible outcome is "not found".
    ///
    /// The console's creation pages — `/dashboard/new` and friends — are
    /// deliberately *not* here. This app can read a project and flip a flag it
    /// has been opted in to; it cannot create a dashboard. Quietly landing on
    /// the list would answer a request to make something with a request to look
    /// at what already exists, so those are refused and say so.
    private static let listPages: Set<String> = ["recent", "home", "playlists", "templates"]

    /// The destination a URL names, or nil when there isn't one.
    ///
    /// Nil is a real answer and the caller must say so out loud: the console has
    /// pages this app has no equivalent for, and quietly landing on the nearest
    /// screen would be a worse lie than admitting the link went nowhere.
    static func parse(_ url: URL) -> PostHogLinkTarget? {
        let components: [String]
        switch url.scheme?.lowercased() {
        case scheme:
            // `gethog://project/42/dashboard/7` puts the first segment in the
            // host, so it has to be stitched back on before the two grammars are
            // the same one.
            guard let host = url.host(), !host.isEmpty else { return nil }
            components = [host] + pathSegments(of: url)
        case "http", "https":
            // Deliberately not restricted to posthog.com. The region is
            // user-configured and `PostHogRegion.selfHosted` accepts any host,
            // so a host allowlist would reject exactly the deployments that
            // cannot rely on the cloud URLs. Nothing is trusted from the host
            // anyway: the destination is resolved inside the account the app is
            // already signed in to, and an id from an unrelated site can only
            // ever produce "not found".
            components = pathSegments(of: url)
        default:
            // `mailto:`, `file:`, and anything with no scheme at all.
            return nil
        }

        // `/project/<id>/…` is the console's own prefix, and the id in it is the
        // whole reason this type carries a project separately.
        if components.count >= 2, components[0] == "project" || components[0] == "project_id" {
            guard let projectID = Int(components[1]) else { return nil }
            return link(from: Array(components.dropFirst(2)))
                .map { PostHogLinkTarget(projectID: projectID, link: $0) }
        }
        return link(from: components).map { PostHogLinkTarget(projectID: nil, link: $0) }
    }

    /// The URL that names a target, for a quick action item to carry.
    ///
    /// Always the custom scheme: a generated `https://us.posthog.com/…` would
    /// leave the app and open Safari, which is the opposite of what a home
    /// screen shortcut is for.
    static func url(for target: PostHogLinkTarget) -> URL {
        let suffix: String = switch target.link {
        case .screen(let tab):
            sections.first { $0.tab == tab }?.path ?? "\(tabPrefix)/\(tab.rawValue)"
        case .dashboard, .featureFlag, .sessionRecording, .errorIssue, .insight:
            target.link.webPath ?? ""
        }
        let path = target.projectID.map { "project/\($0)/\(suffix)" } ?? suffix
        // Percent-encoded because session and issue ids are opaque strings that
        // PostHog is free to put anything in.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // The force-unwrap is safe for the same reason: everything interpolated
        // above is either a literal from `sections` or percent-encoded here.
        return URL(string: "\(scheme)://\(encoded)")!
    }

    // MARK: Internals

    private static func pathSegments(of url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    /// The section-and-object half, with any `project/<id>` prefix removed.
    private static func link(from components: [String]) -> PostHogLink? {
        guard let section = components.first else { return nil }
        let rest = Array(components.dropFirst())

        // A section on its own, or one of its list pages, is the screen.
        let tab = sections.first { $0.path == section }?.tab
        if rest.isEmpty || (rest.count == 1 && listPages.contains(rest[0].lowercased())) {
            return tab.map(PostHogLink.screen)
        }
        guard rest.count == 1, case let identifier = rest[0], !identifier.isEmpty else { return nil }

        switch section {
        case tabPrefix:
            return AppTab(rawValue: identifier).map(PostHogLink.screen)
        case "dashboard":
            return Int(identifier).map(PostHogLink.dashboard)
        case "feature_flags":
            return Int(identifier).map(PostHogLink.featureFlag)
        case "replay":
            return .sessionRecording(id: identifier)
        case "error_tracking":
            return .errorIssue(id: identifier)
        case "insights":
            // Not in `sections`: the app has no insights list either, so
            // `/insights` on its own is refused while a single insight resolves
            // to something the app can at least be honest about.
            return .insight(shortID: identifier)
        default:
            return nil
        }
    }
}
