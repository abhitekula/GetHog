import SwiftUI
import UIKit

/// One place every inbound link lands before the UI reads it.
///
/// Two things arrive here: a `gethog://` URL from `onOpenURL`, and a home
/// screen quick action, which is turned into the *same* URL the moment it is
/// received. That is deliberate — "a quick action lands exactly where a deep
/// link would" is only true by construction if the two are literally the same
/// value by the time anything routes them.
///
/// A mailbox rather than a notification alone because of cold launch: a scene
/// connecting with a shortcut item, and a URL opened while the app was not
/// running, both arrive before `AppModel.bootstrap()` has finished and long
/// before `RootView` has a `.ready` body to route with. A posted notification
/// would simply be missed. So the value is held until somebody takes it, and
/// the notification exists only to prod an app that is already running.
///
/// Consume-once, for the reason `IntentNavigationTarget` documents: a link left
/// behind would re-navigate on every later foreground pass, which reads as the
/// app refusing to let you leave.
@MainActor
enum LinkInbox {
    private static var pending: URL?

    /// Posted so an already-running app routes immediately rather than waiting
    /// for its next `onAppear`.
    static let didChangeNotification = Notification.Name("app.gethog.linkInbox")

    static func deliver(_ url: URL) {
        pending = url
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func consume() -> URL? {
        defer { pending = nil }
        return pending
    }

    // MARK: Staged queries

    /// A term a link asked a screen to type into its own search field.
    ///
    /// Keyed by destination so two screens with search fields cannot take each
    /// other's term — the project index searches object names, the Events screen
    /// searches event names, and a term meant for one is nonsense in the other.
    private static var pendingQueries: [AppTab: String] = [:]

    static func stage(query: String, for tab: AppTab) {
        pendingQueries[tab] = query
    }

    static func consumeQuery(for tab: AppTab) -> String? {
        pendingQueries.removeValue(forKey: tab)
    }
}

// MARK: - Intents

extension IntentNavigationTarget {

    /// The link an intent's hand-off stands for.
    ///
    /// Intents run out of process against whichever project shared defaults name,
    /// so they never carry one of their own — `nil` here means "the selected
    /// project", which by then is the project the intent itself resolved against.
    var linkTarget: PostHogLinkTarget {
        let link: PostHogLink = switch self {
        case .dashboard(let id): .dashboard(id: id)
        // Numeric, and `InsightEntity.webPath` already builds the console URL
        // this way; the console resolves either form.
        case .insight(let id): .insight(shortID: String(id))
        case .featureFlag(let id): .featureFlag(id: id)
        case .events: .screen(.events)
        case .search: .screen(.search)
        }
        return PostHogLinkTarget(projectID: nil, link: link)
    }

    /// The term this hand-off wants typed once the screen is showing, if any.
    var stagedQuery: (tab: AppTab, term: String)? {
        switch self {
        case .events(let search): search.isEmpty ? nil : (.events, search)
        case .search(let term): term.isEmpty ? nil : (.search, term)
        case .dashboard, .insight, .featureFlag: nil
        }
    }
}

// MARK: - Refusals

/// Something a link asked for that the app could not do, in the user's terms.
///
/// Only ever set on failure. A link that worked navigates and says nothing —
/// the destination is the confirmation, and the project it landed in is the
/// navigation subtitle of the screen it landed on.
struct LinkNotice {
    let title: String
    let message: String
    /// Where the reader can still get what they asked for, when anywhere.
    let webURL: URL?

    /// A URL that named nothing this app has.
    ///
    /// Offers the browser only for a web link. A `gethog://` URL that failed
    /// to parse has nowhere else to go, and a button that opened it again would
    /// simply fail again.
    static func unrecognised(_ url: URL) -> LinkNotice {
        let isWeb = url.scheme == "http" || url.scheme == "https"
        return LinkNotice(
            title: "GetHog can't open that link",
            message: isWeb
                ? "\(url.absoluteString) isn't a PostHog page GetHog has a screen for. You can still open it in the console."
                : "\(url.absoluteString) doesn't name anything in GetHog.",
            webURL: isWeb ? url : nil
        )
    }

    /// A link for a project this credential cannot see.
    ///
    /// Named plainly, with the id, because the usual cause is a colleague's link
    /// from an environment this key was never scoped to — and the fix is to add
    /// the project to the key, which the user can only do if they know which
    /// project was asked for.
    static func inaccessibleProject(id: Int) -> LinkNotice {
        LinkNotice(
            title: "That link is for another project",
            message: "It points at PostHog project \(id), which this API key can't see. GetHog has left you where you were rather than showing a different project's data under this link's name.",
            webURL: nil
        )
    }

    /// An object this app has no screen for.
    static func noScreen(link: PostHogLink, webURL: URL?) -> LinkNotice {
        let message = switch link {
        case .insight:
            "GetHog draws an insight as a tile on the dashboard it sits on and has no screen for one on its own."
        default:
            "GetHog has no screen for this kind of object."
        }
        return LinkNotice(
            title: "No screen for that",
            message: webURL == nil ? message : "\(message) It opens in the PostHog console.",
            webURL: webURL
        )
    }
}

// MARK: - Quick action delivery

/// Exists only to give the scene a delegate of our own.
///
/// Quick actions cannot be received any other way in a scene-based app:
/// `application(_:performActionFor:)` is the pre-scene API and iOS does not call
/// it once `UIApplicationSceneManifest` is present — which it is, generated by
/// `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`. The scene delegate's
/// `windowScene(_:performActionFor:)` is the only surviving entry point, and
/// returning a `UISceneConfiguration` from here is the only way for a SwiftUI
/// `App` to name one.
///
/// It deliberately implements nothing else. SwiftUI still owns the window and
/// the scene's content; this delegate only forwards the shortcut item.
final class GetHogAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {

    /// Cold launch: the app was not running, so the shortcut arrives as part of
    /// the scene's connection options rather than as a call of its own.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        guard let item = options.shortcutItem else { return }
        QuickActions.receive(item)
    }

    /// Warm launch: the app was already running or suspended.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem
    ) async -> Bool {
        await QuickActions.receive(shortcutItem)
        return true
    }
}
