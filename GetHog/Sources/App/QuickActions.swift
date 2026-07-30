import Foundation
import UIKit

/// The home screen icon's long-press menu.
///
/// Four slots, and the criterion for spending one is "what would somebody open
/// this app to do in ten seconds" — not one per tab. Search is the fifth tab and
/// reaches every screen and every object in the project, so a shortcut that only
/// selects a tab the tab bar already shows buys nothing.
///
/// Two are fixed (`UIApplicationShortcutItems` in the Info.plist) because they
/// are always the right answer:
///
/// - **Search**, because it is the one field that reaches anything at all.
/// - **Errors**, because "is anything on fire" is the only question here with a
///   deadline on it.
///
/// Two are dynamic and come from what the app already knows:
///
/// - the **pinned dashboard**, which the widget snapshot already resolves on
///   every refresh, and
/// - the **last object opened**, recorded as the user navigates.
///
/// Both are written from data already in hand. Nothing here may fetch: the
/// rate-limit budget is organisation-wide and shared with the user's own
/// integrations, and a menu that costs two requests every time the icon is
/// long-pressed would spend somebody else's budget on decoration.
///
/// Deliberately *not* offered: a flag toggle. A quick action has no way to
/// confirm and nowhere to report a 403, and this app gates flag writes behind an
/// explicit per-flag opt-in and optionally Face ID — a shortcut that flipped
/// production behaviour from a long-press would walk straight through both.
@MainActor
enum QuickActions {

    /// One destination, in the form the menu needs it.
    ///
    /// The URL is the whole identity: it is `UIApplicationShortcutItemType`, and
    /// it is what comes back when the item is tapped. Storing anything else
    /// would give the menu a second opinion about where a row goes.
    private struct Ref: Codable, Hashable {
        let projectID: Int
        let url: String
        let title: String
        let subtitle: String
        let symbol: String
    }

    private struct State: Codable {
        /// The pinned dashboard, per project.
        var pinned: [Ref] = []
        /// Newest first, across projects, filtered to the selected one on use.
        var recent: [Ref] = []
    }

    private static let defaultsKey = "quickActionState"

    /// Small on purpose. This is a two-slot menu, not a history; keeping more
    /// only widens the window in which a deleted object is still offered.
    private static let recentLimit = 6

    // MARK: - Activation

    /// Turns a tapped shortcut into the deep link it stands for.
    ///
    /// The item's type *is* the URL, so this cannot route anywhere a pasted link
    /// would not — which is the only way to be sure a quick action does not
    /// quietly develop a destination of its own.
    static func receive(_ item: UIApplicationShortcutItem) {
        guard let url = URL(string: item.type) else { return }
        LinkInbox.deliver(url)
    }

    // MARK: - Recording

    /// Records the dashboard PostHog reports as pinned for this project.
    ///
    /// Called from the widget snapshot publish, which already resolves it —
    /// this adds no request of its own. Only a genuinely pinned dashboard is
    /// recorded: the snapshot falls back to the first dashboard when nothing is
    /// pinned, and labelling that one "Pinned" would be a small lie on a surface
    /// with no room to correct it.
    static func recordPinnedDashboard(id: Int, title: String, projectID: Int) {
        var state = load()
        state.pinned.removeAll { $0.projectID == projectID }
        state.pinned.append(
            Ref(
                projectID: projectID,
                url: PostHogLinkParser.url(
                    for: PostHogLinkTarget(projectID: projectID, link: .dashboard(id: id))
                ).absoluteString,
                title: title,
                subtitle: "Pinned dashboard",
                symbol: AppTab.dashboards.systemImage
            )
        )
        save(state)
    }

    /// Records that the user opened something, so the menu can offer it back.
    ///
    /// The project id is stored beside the object id and filtered on every
    /// rebuild. A shortcut carrying dashboard 128 from a project that is no
    /// longer selected would open one project's dashboard under another
    /// project's data — the failure the project switcher exists to prevent.
    static func recordVisit(_ link: PostHogLink, title: String, projectID: Int) {
        let url = PostHogLinkParser.url(
            for: PostHogLinkTarget(projectID: projectID, link: link)
        ).absoluteString
        var state = load()
        state.recent.removeAll { $0.url == url }
        state.recent.insert(
            Ref(
                projectID: projectID,
                url: url,
                title: title,
                subtitle: subtitle(for: link),
                symbol: symbol(for: link)
            ),
            at: 0
        )
        state.recent = Array(state.recent.prefix(recentLimit))
        save(state)
    }

    /// Drops everything remembered, on sign-out.
    ///
    /// The titles are project data — a dashboard called "Q3 churn — EMEA" names
    /// a customer's business — and they must not outlive the credential that
    /// could read them.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UIApplication.shared.shortcutItems = []
    }

    // MARK: - Publishing

    /// Rebuilds the dynamic half of the menu for the project now selected.
    ///
    /// iOS shows the Info.plist items first and these after, four in total, so
    /// this contributes at most two.
    static func refresh(projectID: Int?) {
        guard let projectID else {
            UIApplication.shared.shortcutItems = []
            return
        }
        let state = load()
        let pinned = state.pinned.first { $0.projectID == projectID }
        let recent = state.recent.first {
            // A recent that is the pinned dashboard would take the fourth slot
            // to repeat the third.
            $0.projectID == projectID && $0.url != pinned?.url
        }
        UIApplication.shared.shortcutItems = [pinned, recent].compactMap { $0 }.map(item(for:))
    }

    // MARK: - Internals

    private static func item(for ref: Ref) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: ref.url,
            localizedTitle: ref.title,
            localizedSubtitle: ref.subtitle,
            icon: UIApplicationShortcutIcon(systemImageName: ref.symbol),
            userInfo: nil
        )
    }

    private static func subtitle(for link: PostHogLink) -> String {
        switch link {
        case .dashboard: "Dashboard"
        case .featureFlag: "Feature flag"
        case .sessionRecording: "Session"
        case .errorIssue: "Error"
        case .insight: "Insight"
        case .screen: "Screen"
        }
    }

    private static func symbol(for link: PostHogLink) -> String {
        switch link {
        case .dashboard: AppTab.dashboards.systemImage
        case .featureFlag: AppTab.flags.systemImage
        case .sessionRecording: AppTab.sessions.systemImage
        case .errorIssue: AppTab.errorTracking.systemImage
        case .insight: "chart.line.uptrend.xyaxis"
        case .screen(let tab): tab.systemImage
        }
    }

    private static func load() -> State {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private static func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
