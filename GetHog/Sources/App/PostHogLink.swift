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
/// Every case is something the app can actually do something honest with, and
/// every case now opens in the app. `insight` was the exception for as long as
/// there was no screen behind it; `SavedInsightDetailView` is that screen.
enum PostHogLink: Hashable, Sendable {
    /// One of the app's own screens, with no particular object selected.
    case screen(AppTab)
    case dashboard(id: Int)
    case featureFlag(id: Int)
    case sessionRecording(id: String)
    case errorIssue(id: String)
    /// A saved insight, named the way the console names it.
    ///
    /// The payload is `shortID` because that is what a console URL carries — an
    /// 8-character handle like `demo0001`, which is also `file_system`'s `ref`
    /// for an insight row. It is a `String` rather than an `Int` for the same
    /// reason a session id is: it is not a number and parsing it as one would
    /// drop every real link.
    ///
    /// It is nonetheless permitted to *contain* a number. This app's own
    /// widgets and intents carry the numeric id — see
    /// `IntentNavigationTarget.linkTarget` — and PostHog resolves either form.
    /// `SavedInsightStore.resolve` decides which spelling it has been given
    /// without guessing: a string that parses as an `Int` is only ever looked up
    /// as a numeric id, so a handle that happened to be all digits can never
    /// silently select a different insight.
    case insight(shortID: String)

    /// Whether the app has a screen for this, or has to hand it to a browser.
    ///
    /// Every case is `true`. The property stays because it is the gate
    /// `RootView.open(_:)` checks before pushing, and deleting it would mean the
    /// next case added to this enum is pushed by default and lands on a blank
    /// screen — the answer has to keep being *stated* rather than assumed.
    var opensInApp: Bool {
        switch self {
        case .screen, .dashboard, .featureFlag, .sessionRecording, .errorIssue, .insight: true
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
        // Added when the saved-insight library shipped. Before it, `/insights`
        // was deliberately absent from this table and the parser refused the
        // bare path — there was no list to send anyone to. There is now, so the
        // section resolves like every other one and only the object below it
        // needs special handling.
        ("insights", .insights),
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
        // The console puts Support at `/support/tickets`, *not* under
        // `/conversations` — the shared prefix is an API-side accident and the
        // web routes keep the two products apart. `max` above is the other half
        // of the same pair, and mapping either one to `conversations` would send
        // a link to the wrong product.
        ("support", .support),
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
    /// then refuses. It keeps `gethog://tab/settings` (this app's own
    /// settings) distinct from the console's `/settings`, which is project
    /// configuration and something this app has no screen for.
    ///
    /// This used to claim the prefix "cannot collide with a real page". It can:
    /// the *second* segment is an `AppTab` case name, and `templates` is both a
    /// case and a `/replay/` list page. `link(from:)` therefore resolves this
    /// prefix before consulting `listPages`.
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
    /// `tickets` joins them because the console's Support inbox lives one
    /// segment down at `/support/tickets` — the section on its own is the
    /// product's landing page, and the list is where a shared link points.
    private static let listPages: Set<String> = [
        "recent", "home", "playlists", "templates", "tickets",
    ]

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

        // `tab/<case>` resolves before anything else, because the two namespaces
        // genuinely collide and the console's one used to win.
        //
        // `templates` is a `/replay/` list page *and*, since the dashboard
        // template gallery shipped, an `AppTab` case. So
        // `gethog://tab/templates` matched the list-page branch below, which
        // then looked `tab` up in `sections`, found nothing, and returned nil —
        // a quick action this app generated for its own screen, which its own
        // parser refused. Caught by the round-trip test rather than on device,
        // which is the whole reason that test exists.
        if section == tabPrefix {
            guard rest.count == 1 else { return nil }
            return AppTab(rawValue: rest[0]).map(PostHogLink.screen)
        }

        // A section on its own, or one of its list pages, is the screen.
        let tab = sections.first { $0.path == section }?.tab
        if rest.isEmpty || (rest.count == 1 && listPages.contains(rest[0].lowercased())) {
            return tab.map(PostHogLink.screen)
        }
        guard rest.count == 1, case let identifier = rest[0], !identifier.isEmpty else { return nil }

        switch section {
        case "dashboard":
            return Int(identifier).map(PostHogLink.dashboard)
        case "feature_flags":
            return Int(identifier).map(PostHogLink.featureFlag)
        case "replay":
            return .sessionRecording(id: identifier)
        case "error_tracking":
            return .errorIssue(id: identifier)
        case "insights":
            // The identifier is kept verbatim rather than parsed. A console
            // handle is an 8-character base-62 string; this app's own widgets
            // and intents write the numeric id into the same slot. Both are
            // valid, PostHog resolves both, and deciding which is which is
            // `SavedInsightStore.resolve`'s job — not this parser's, which must
            // not throw away a link it cannot classify.
            return .insight(shortID: identifier)
        default:
            return nil
        }
    }
}
