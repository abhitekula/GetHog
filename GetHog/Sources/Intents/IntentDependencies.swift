import AppIntents
import Foundation
import GetHogKit
import os

/// Everything an App Intent needs to reach PostHog, assembled without the app.
///
/// This exists because intents do **not** run inside the app's session. The
/// system executes them on its own schedule — from Siri, Spotlight, a Shortcut,
/// a widget tap — where there is no `AppModel` to borrow: it is `@MainActor`,
/// it is built by `GetHogApp`, and it may never have been constructed in the
/// process handling this call. So the credential is read straight from the
/// Keychain, the project id from shared defaults, and a short-lived client is
/// built per invocation.
///
/// Deliberately *not* memoised across invocations. A Focus filter or a project
/// switch can change the answer between two runs, and a cached project id would
/// silently report another project's numbers — the one failure mode an
/// analytics client must never have.
///
/// **Which process that is, established rather than assumed.** An App Intent is
/// performed by whichever bundle *declared* it, so "not the app's session" does
/// not have to mean "not the app's process". Every type in this directory is
/// declared by the app target and only the app target — `project.yml` used to
/// compile the whole directory into `GetHogWidgets` as well, which put a
/// second, identical copy of `GetMetricValueIntent`, `SearchEventsIntent`,
/// `SetFeatureFlagIntent`, `OpenDashboardIntent`, `ProjectFocusFilter` and
/// `ShowGetHogSearchResultsIntent` in the widget extension's
/// `Metadata.appintents`, alongside a second `AppShortcutsProvider` whose Siri
/// phrases were trained against `app.gethog.GetHog.Widgets`. Read out of
/// the built `.appex`, not inferred. That is gone: the extension's metadata now
/// lists only its own widget and Control Center intents, so everything here runs
/// in the app — which is where the rate-limit governor, the keychain and
/// somewhere to show a 403 all are.
struct IntentDependencies: Sendable {

    /// Shared container for the app, the widget extension and Focus filters.
    ///
    /// The same identifier `GetHogKit.SharedSnapshotStore.appGroupIdentifier`
    /// uses, which is how the widget extension reaches the container without
    /// compiling anything from this directory.
    static let appGroupID = "group.app.gethog"

    /// Defaults key holding the selected project id. This exact string is the
    /// contract between `AppModel`, the Focus filter and every intent.
    static let selectedProjectKey = "selectedProjectID"

    /// Which keychain access group the credential is read from. `nil` means "the
    /// process default", and **the process default here is already the shared
    /// group** — this is not a placeholder waiting on an entitlement.
    ///
    /// The comment this replaces said to set it "once the app and its extensions
    /// share a `keychain-access-groups` entitlement", and described the default
    /// as per-bundle. Both halves were wrong by the time they were read. The
    /// entitlement has been in `GetHog.entitlements` and
    /// `GetHogWidgets.entitlements` all along, identically
    /// (`$(AppIdentifierPrefix)app.gethog.shared`), and the default access
    /// group is not per-bundle: it is the **first entry of the
    /// `keychain-access-groups` entitlement**, falling back to
    /// `application-identifier` only when that entitlement is absent.
    ///
    /// Measured rather than reasoned about, because getting it wrong signs a user
    /// out. In the app process, `SecItemAdd` with no `kSecAttrAccessGroup`
    /// followed by a read of the stored attribute returns
    /// `[REMOVED PRIVATE DATA].app.gethog.shared` — the shared group, not
    /// `[REMOVED PRIVATE DATA].app.gethog.GetHog`. `KeychainAccessGroupTests` is that
    /// measurement, kept as a test so a second entry added ahead of this one in
    /// the entitlement — which would silently move every stored credential —
    /// fails the build instead of the user.
    ///
    /// So there is nothing to migrate: naming the group explicitly would select
    /// the same group the empty query already selects. It is also not expressible
    /// here. `$(AppIdentifierPrefix)` is substituted by Xcode while processing
    /// the entitlements file and resolves to a team prefix that differs per
    /// signing identity; a literal in Swift would be correct on one machine and
    /// lock the user out on every other. Deriving it at runtime means probing the
    /// keychain with a throwaway item on every launch, to arrive at the value
    /// `nil` already produces.
    static let keychainAccessGroup: String? = nil

    static let log = Logger(subsystem: "app.gethog", category: "intents")

    /// Posted after something outside the app changes the selected project — a
    /// Focus filter, today. Lets a running app re-read the selection instead of
    /// waiting for its next cold launch.
    static let selectedProjectDidChangeNotification =
        Notification.Name("app.gethog.selectedProjectDidChange")

    let client: PostHogClient
    let projectID: Int

    /// Shared defaults, or `nil` when the App Group isn't provisioned (a plain
    /// `xcodebuild` run without the entitlement, for instance).
    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func credentialStore() -> KeychainTokenStore {
        KeychainTokenStore(accessGroup: keychainAccessGroup)
    }

    /// Builds a client and resolves the project to act on.
    ///
    /// - Parameter projectID: skips resolution when the caller already knows the
    ///   project (Spotlight reindexing after a switch, for example).
    static func resolve(projectID: Int? = nil) async throws -> IntentDependencies {
        let client = try makeClient()

        if let projectID {
            return IntentDependencies(client: client, projectID: projectID)
        }
        if let stored = storedProjectID() {
            return IntentDependencies(client: client, projectID: stored)
        }

        // Nothing persisted yet — a fresh install, or an intent invoked before
        // the app has ever chosen a project. One `/me` call settles it rather
        // than failing with a question the user can't answer from Siri.
        let me: MeResponse = try await client.send(PostHogAPI.me())
        guard let id = me.currentProject?.id ?? me.projects.first?.id else {
            throw IntentError.noProject
        }
        return IntentDependencies(client: client, projectID: id)
    }

    static func makeClient() throws -> PostHogClient {
        guard let credential = try? credentialStore().load() else {
            throw IntentError.notConnected
        }
        // A fresh governor per invocation: the app's rate-limit budget lives in
        // its own process and can't be consulted from here. Intents are
        // single-request-shaped, so the practical exposure is one call.
        return PostHogClient(
            auth: PersonalKeyAuthProvider(key: credential.key, region: credential.region)
        )
    }

    /// Prefers the App Group value, because that is the one a Focus filter or an
    /// extension can write. Falls back to `.standard`, which is where the app
    /// itself persists the selection today.
    static func storedProjectID() -> Int? {
        if let shared = sharedDefaults {
            let id = shared.integer(forKey: selectedProjectKey)
            if id != 0 { return id }
        }
        let id = UserDefaults.standard.integer(forKey: selectedProjectKey)
        return id == 0 ? nil : id
    }

    /// Writes to both stores on purpose: the App Group is the cross-process
    /// contract, `.standard` is what `AppModel` reads on launch. Writing only one
    /// would leave the app and its intents disagreeing about the current project.
    static func persistSelectedProject(_ id: Int) {
        sharedDefaults?.set(id, forKey: selectedProjectKey)
        UserDefaults.standard.set(id, forKey: selectedProjectKey)
    }

    /// Deep link into the equivalent page of the web console.
    func webURL(path: String) -> URL {
        client.host
            .appendingPathComponent("project/\(projectID)")
            .appendingPathComponent(path)
    }
}

// MARK: - Navigation hand-off

/// A one-shot navigation request handed from an intent to the app.
///
/// An intent that opens the app can't push a view itself, so it leaves the
/// destination here. Consume-once by design: a target left behind would
/// re-navigate on every later launch, which reads as the app ignoring the user.
enum IntentNavigationTarget: Equatable, Sendable {
    case dashboard(id: Int)
    case insight(id: Int)
    case featureFlag(id: Int)
    case events(search: String)
    /// The app's own search over every screen and every object in the project —
    /// where `ShowGetHogSearchResultsIntent` lands.
    case search(term: String)

    static let defaultsKey = "pendingIntentNavigation"

    /// Posted so an already-running app reacts immediately instead of waiting
    /// for its next foreground pass.
    static let didChangeNotification = Notification.Name("app.gethog.intentNavigationTarget")

    static func request(_ target: IntentNavigationTarget) {
        IntentDependencies.sharedDefaults?.set(target.rawValue, forKey: defaultsKey)
        UserDefaults.standard.set(target.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Returns the pending target and clears it.
    static func consume() -> IntentNavigationTarget? {
        let raw = IntentDependencies.sharedDefaults?.string(forKey: defaultsKey)
            ?? UserDefaults.standard.string(forKey: defaultsKey)
        IntentDependencies.sharedDefaults?.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return raw.flatMap(IntentNavigationTarget.init(rawValue:))
    }

    var rawValue: String {
        switch self {
        case .dashboard(let id): "dashboard:\(id)"
        case .insight(let id): "insight:\(id)"
        case .featureFlag(let id): "flag:\(id)"
        case .events(let search): "events:\(search)"
        case .search(let term): "search:\(term)"
        }
    }

    init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        let kind = String(rawValue[rawValue.startIndex..<separator])
        let value = String(rawValue[rawValue.index(after: separator)...])
        switch kind {
        case "dashboard": guard let id = Int(value) else { return nil }; self = .dashboard(id: id)
        case "insight": guard let id = Int(value) else { return nil }; self = .insight(id: id)
        case "flag": guard let id = Int(value) else { return nil }; self = .featureFlag(id: id)
        case "events": self = .events(search: value)
        case "search": self = .search(term: value)
        default: return nil
        }
    }
}

// MARK: - Errors

/// Every case names what the user can do next. An intent failure is read aloud
/// or shown as one line in Shortcuts — there is no screen to explain it on, so
/// "something went wrong" would leave the user with nowhere to go.
enum IntentError: Error, CustomLocalizedStringResourceConvertible, Equatable {
    case notConnected
    case noProject
    case unauthorized
    /// The key authenticated but lacks a scope. `scope` is PostHog's own string.
    case missingScope(scope: String, action: String)
    case rateLimited(retryAfter: Int)
    case entityUnavailable(kind: String, name: String)
    case unsupportedInsight(name: String, kind: String)
    case authenticationDenied(flagKey: String, detail: String)
    case failed(action: String, detail: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected:
            "Open GetHog and connect your PostHog account first."
        case .noProject:
            "No PostHog project is selected. Open GetHog and choose a project."
        case .unauthorized:
            "Your PostHog API key was rejected. Open GetHog and reconnect in Settings."
        case .missingScope(let scope, let action):
            "Couldn't \(action): your personal API key is missing the \(scope) scope. Add it to the key in PostHog, then try again."
        case .rateLimited(let retryAfter):
            "PostHog is rate limiting requests. Try again in \(retryAfter) seconds."
        case .entityUnavailable(let kind, let name):
            "Couldn't find the \(kind) “\(name)” in the selected project. Open GetHog to check which project is active."
        case .unsupportedInsight(let name, let kind):
            "“\(name)” is a \(kind) insight, which GetHog can't summarise as a single number. Open it in GetHog to see the full chart."
        case .authenticationDenied(let flagKey, let detail):
            "Not authenticated, so \(flagKey) was left unchanged. \(detail)"
        case .failed(let action, let detail):
            "Couldn't \(action). \(detail)"
        }
    }

    /// Translates a transport-level failure into something actionable.
    ///
    /// - Parameters:
    ///   - action: a verb phrase completing "Couldn't …", e.g. `"read that metric"`.
    ///   - writeScope: named when a 403 is expected to be a missing write scope.
    static func from(
        _ error: any Error,
        action: String,
        writeScope: String? = nil
    ) -> IntentError {
        if let intentError = error as? IntentError { return intentError }
        guard let posthog = error as? PostHogError else {
            return .failed(action: action, detail: error.localizedDescription)
        }
        switch posthog {
        case .unauthorized:
            return .unauthorized
        case .forbidden(let missingScope, _):
            // A read-scoped key passes every earlier check and only fails here,
            // so this is the first moment the user can learn what to tick.
            return .missingScope(scope: missingScope ?? writeScope ?? "the required", action: action)
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: Int(retryAfter.rounded()))
        default:
            return .failed(action: action, detail: posthog.localizedDescription)
        }
    }
}
