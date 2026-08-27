import Foundation
import Observation
import GetHogKit
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The authoritative result of a feature-flag PATCH. Callers that have a UI
/// consume the failure; out-of-process intent hand-off may deliberately ignore
/// it because it has nowhere to present one.
enum FlagWriteOutcome: Equatable, Sendable {
    case changed
    case failed(String)
}

/// The complete namespace in which a numeric feature-flag id is meaningful.
/// Project ids can repeat across US Cloud, EU Cloud, and self-hosted instances,
/// so region is part of the write authority rather than display metadata.
struct FlagWriteScope: Equatable, Sendable {
    let projectID: Int
    let projectRegion: PostHogRegion?
    let authSessionID: UUID
}

/// Session-wide state: who we are, which project we're looking at, and what the
/// current credential is actually allowed to do.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
    }

    /// What the saved credential needs after bootstrap failed. A transient
    /// outage keeps the key and can retry it; a rejected key is removed and
    /// needs replacement.
    enum StoredCredentialRecovery: Equatable {
        case retryable
        case replaceCredential(PostHogRegion)
    }

    private(set) var phase: Phase = .loading
    /// Stable across relaunches and retries of one saved credential, and
    /// replaced whenever a different key is connected. It is intentionally
    /// non-secret; its only purpose is to make old snapshot write authority
    /// expire without persisting or comparing the bearer key itself.
    private(set) var authSessionID: UUID?
    private(set) var client: PostHogClient?
    private(set) var me: MeResponse?
    private(set) var capabilities: CapabilityReport?
    private(set) var connectionError: String?
    private(set) var storedCredentialRecovery: StoredCredentialRecovery?

    var projects: [Project] = []
    var selectedProject: Project? {
        didSet {
            guard let selectedProject, selectedProject.id != oldValue?.id else { return }
            snapshotPublicationGeneration &+= 1
            if !isRuntimeDemo,
               let published = snapshotStore.loadOrNil(),
               published.projectID != selectedProject.id
                || published.projectRegion != activeRegion {
                clearPublishedProjectData()
            }
            persistSelectedProject(selectedProject.id)
            Task { await refreshCapabilities() }
        }
    }

    // MARK: - Organizations
    //
    // `/api/users/@me/` hydrates the projects of exactly one organization. For
    // everyone in a single organization — which is most people — that is the
    // whole story and nothing below ever costs a request. For everyone else it
    // was a wall: `MeResponse.organizations` was decoded and read by nothing, so
    // a user in two organizations could reach the projects of one and had no way
    // to learn that the others existed.

    /// Every organization the credential can see. One entry is the common case.
    private(set) var organizations: [OrganizationSummary] = []

    /// Which one `projects` currently describes.
    private(set) var selectedOrganizationID: String?

    /// Projects per organization, for the session.
    ///
    /// Kept rather than refetched because the set of projects in an organization
    /// does not change while somebody is looking at a chart, and switching back
    /// and forth to compare two projects is exactly what this control is for —
    /// paying a request each way would make comparing them cost more than
    /// looking at them. The rate-limit budget is organisation-wide and shared
    /// with whatever else the user has integrated.
    private var projectsByOrganization: [String: [Project]] = [:]

    /// True while an organization's projects are being fetched.
    private(set) var isSwitchingOrganization = false

    /// Why the last organization switch did not happen. Nil once acknowledged.
    var organizationError: String?

    /// Whether the organization is worth naming on screen at all.
    ///
    /// One organization is the overwhelmingly common case, and for that user the
    /// organization's name is a constant — printing it in every navigation
    /// subtitle would spend a line of chrome on a word that never changes. The
    /// moment there are two it stops being a constant and starts being the thing
    /// that decides whose numbers these are.
    var isMultiOrganization: Bool { organizations.count > 1 }

    var selectedOrganization: OrganizationSummary? {
        organizations.first { $0.id == selectedOrganizationID }
    }

    /// The scope a personal API key needs before any of this can work.
    ///
    /// Not a `Capability`: there is no screen to gate, and adding a case would
    /// change what onboarding asks every user to tick for a control most of them
    /// will never see.
    static let organizationReadScope = "organization:read"

    let store: any CredentialStoring
    let cache: ResponseCache
    private let governor = RateLimitGovernor()
    private let snapshotStore: SharedSnapshotStore
    private let snapshotRefresher: SnapshotRefreshCoordinator
    private var activeRegion: PostHogRegion?
    /// Changes whenever session state that authorizes snapshot side effects
    /// changes. A publication retains this alongside its full scope and must
    /// still match both after every suspension.
    private var snapshotPublicationGeneration: UInt64 = 0

    private enum SnapshotPublicationAuthority {
        case live(FlagWriteScope)
        case storedCredential(
            projectID: Int,
            projectRegion: PostHogRegion,
            authSessionID: UUID
        )

        var authSessionID: UUID {
            switch self {
            case .live(let scope): scope.authSessionID
            case .storedCredential(_, _, let authSessionID): authSessionID
            }
        }
    }

    private struct SnapshotPublicationContext {
        let generation: UInt64
        let authority: SnapshotPublicationAuthority
    }

    /// The live session scope a snapshot-backed write must still match. A nil
    /// region cannot authorize a write; legacy snapshots deliberately carry
    /// nil and are therefore treated as untrusted by equality with this value.
    var flagWriteScope: FlagWriteScope? {
        guard let project = selectedProject, let activeRegion, let authSessionID else { return nil }
        return FlagWriteScope(
            projectID: project.id,
            projectRegion: activeRegion,
            authSessionID: authSessionID
        )
    }

    /// The transport the model was built with, kept so `signOut()` can restore
    /// it after a runtime demo session swapped it out.
    private let baseTransport: any HTTPTransport
    private var transport: any HTTPTransport

    /// True only for a demo entered from onboarding at runtime, never for a
    /// model *built* around `DemoTransport` (the `-GetHogDemo` launch and the
    /// tests that inject it). The distinction carries the guards below: a
    /// launch-argument demo owns its whole simulator, while a runtime demo runs
    /// on a device whose widget cache and pending intents belong to the user's
    /// real workspace and must survive the visit untouched.
    private(set) var isRuntimeDemo = false

    /// Whether this session is browsing the bundled fictional data, however it
    /// got there.
    var isDemo: Bool { transport is DemoTransport }

    init(
        store: any CredentialStoring = KeychainTokenStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        snapshotStore: SharedSnapshotStore = .shared,
        cache: ResponseCache = ResponseCache()
    ) {
        self.store = store
        self.baseTransport = transport
        self.transport = transport
        self.snapshotStore = snapshotStore
        self.snapshotRefresher = SnapshotRefreshCoordinator(store: snapshotStore)
        self.cache = cache
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        phase = .loading
        connectionError = nil
        storedCredentialRecovery = nil
        guard let storedCredential = try? store.load() else {
            clearPublishedProjectData()
            phase = .onboarding
            return
        }
        let credential = credentialWithAuthenticationEpoch(storedCredential)
        do {
            try await activate(
                credential: credential,
                persistAfterAuthentication: storedCredential.authSessionID == nil
            )
        } catch {
            let postHogError = error as? PostHogError
            connectionError = postHogError?.localizedDescription ?? error.localizedDescription
            if postHogError == .unauthorized {
                storedCredentialRecovery = .replaceCredential(credential.region)
                // A 401 must not trap every subsequent launch in the same failed
                // bootstrap. The rejected secret does not remain in Keychain.
                try? store.clear()
            } else {
                // Only PostHog's explicit rejection implicates the credential.
                // Network/server faults, rate limits, and even a response this
                // build cannot decode all keep it so Retry can retry rather than
                // making somebody paste the same key again.
                storedCredentialRecovery = .retryable
            }
            clearPublishedProjectData()
            phase = .onboarding
        }
    }

    /// Retries the credential still in the store after a transient bootstrap
    /// failure. A rejected credential was deleted and therefore falls through
    /// to ordinary onboarding rather than looping.
    func retryStoredCredential() async {
        await bootstrap()
    }

    /// Validates a credential and, on success, becomes the active session.
    func connect(key: String, region: PostHogRegion) async throws {
        let credential = StoredCredential(
            key: key,
            region: region,
            authSessionID: UUID()
        )
        try await activate(credential: credential, persistAfterAuthentication: true)
    }

    /// Becomes a demo session: the bundled fixtures for a transport, the
    /// literal string "demo" for a credential, and nothing persisted anywhere —
    /// `activate` alone, never `connect`, so the keychain is not touched and
    /// the next launch still lands on onboarding. `signOut()` is the exit.
    func enterDemo() async {
        transport = DemoTransport()
        isRuntimeDemo = true
        do {
            try await activate(credential: StoredCredential(
                key: "demo",
                region: .usCloud,
                authSessionID: UUID()
            ))
        } catch {
            // Unreachable in practice — the fixtures ship in the bundle — but a
            // demo that failed to start must not leave the session wedged
            // between transports.
            transport = baseTransport
            isRuntimeDemo = false
            connectionError = error.localizedDescription
        }
    }

    private func credentialWithAuthenticationEpoch(
        _ credential: StoredCredential
    ) -> StoredCredential {
        guard credential.authSessionID == nil else { return credential }
        return StoredCredential(
            key: credential.key,
            region: credential.region,
            projectID: credential.projectID,
            authSessionID: UUID()
        )
    }

    private func activate(
        credential: StoredCredential,
        persistAfterAuthentication: Bool = false
    ) async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: credential.key, region: credential.region),
            transport: transport,
            governor: governor,
            responseCache: cache,
            responseCacheNamespace: credential.authSessionID?.uuidString
        )

        let me: MeResponse = try await client.send(PostHogAPI.me())

        // Authentication succeeded, so a legacy payload may now be migrated;
        // a brand-new replacement is saved at the same boundary. Persist before
        // any selected-project task can publish the epoch to widgets.
        if persistAfterAuthentication {
            try store.save(credential)
        }

        snapshotPublicationGeneration &+= 1
        self.authSessionID = credential.authSessionID
        if !isRuntimeDemo,
           let published = snapshotStore.loadOrNil(),
           published.authSessionID != credential.authSessionID {
            clearPublishedProjectData()
        }
        self.client = client
        self.activeRegion = credential.region
        self.me = me
        self.projects = me.projects.isEmpty
            ? [me.currentProject].compactMap { $0 }
            : me.projects
        self.organizations = me.allOrganizations
        self.selectedOrganizationID = me.currentOrganizationID
        if let currentOrgID = me.currentOrganizationID {
            // The one organization whose projects arrived free with the identity
            // request. Seeding the cache with it means returning to it later
            // costs nothing.
            projectsByOrganization[currentOrgID] = projects
        }

        let storedID = credential.projectID ?? loadPersistedProjectID()
        self.selectedProject = projects.first { $0.id == storedID }
            ?? me.currentProject
            ?? projects.first

        self.connectionError = nil
        self.storedCredentialRecovery = nil
        self.phase = .ready

        // Restoring the organization comes *after* `.ready`, deliberately. It is
        // the one bootstrap step that can cost a request, and blocking the first
        // screen on it would make launch slower for the single-organization user
        // who can never need it. The projects already on screen belong to the
        // identity response's own organization, so nothing shown before this
        // lands is wrong — it is just not yet the organization the user left off
        // in.
        //
        // Only ever reached when the user has genuinely switched at some point:
        // a stored id equal to the current organization, or absent, does nothing.
        if let storedOrgID = loadPersistedOrganizationID(),
           storedOrgID != me.currentOrganizationID,
           organizations.contains(where: { $0.id == storedOrgID }) {
            await selectOrganization(id: storedOrgID, restoringProjectID: storedID)
        }

        await refreshCapabilities()
        await publishWidgetSnapshot()
    }

    // MARK: - Switching organization

    /// Moves to another organization, bringing its projects with it.
    ///
    /// Nothing on screen changes until the projects are in hand. That is the
    /// whole shape of this method: an organization with an empty project list is
    /// indistinguishable from an organization whose fetch has not finished, and
    /// this app treats a screen showing the wrong project's numbers as a
    /// correctness bug — so it never shows an in-between state where the
    /// organization has moved and the project has not.
    ///
    /// On failure nothing moves at all and `organizationError` says why. There is
    /// no partial success to roll back, which is the one way this differs from
    /// `FlagToggleController`: a read that failed simply did not happen.
    ///
    /// - Parameter restoringProjectID: which project to land on, when the caller
    ///   knows. Used at launch to restore the exact project the user left; a
    ///   switch made by hand has no such expectation and lands on the first.
    func selectOrganization(id: String, restoringProjectID: Int? = nil) async {
        guard id != selectedOrganizationID || projects.isEmpty else { return }
        guard let organization = organizations.first(where: { $0.id == id }) else { return }
        organizationError = nil

        if let cached = projectsByOrganization[id], !cached.isEmpty {
            adopt(projects: cached, organizationID: id, preferring: restoringProjectID)
            return
        }

        guard let client else { return }
        isSwitchingOrganization = true
        defer { isSwitchingOrganization = false }

        do {
            let page: Page<Project> = try await client.send(
                PostHogAPI.organizationProjects(organizationID: id)
            )
            guard !page.results.isEmpty else {
                organizationError = """
                    \(organization.name) came back with no projects, so nothing was switched. \
                    An organization can genuinely have none; if this one has some, your \
                    personal API key may not be able to see them.
                    """
                return
            }
            projectsByOrganization[id] = page.results
            adopt(projects: page.results, organizationID: id, preferring: restoringProjectID)
        } catch {
            organizationError = switchFailureMessage(for: error, organization: organization)
        }
    }

    /// Swaps in another organization's projects as one step.
    private func adopt(projects newProjects: [Project], organizationID: String, preferring id: Int?) {
        projects = newProjects
        selectedOrganizationID = organizationID
        persistSelectedOrganization(organizationID)
        // `didSet` on `selectedProject` does the rest — persisting it, refreshing
        // capabilities, republishing the widget snapshot and reindexing Spotlight
        // — because moving organization changes every one of those exactly the
        // way moving project does.
        selectedProject = newProjects.first { $0.id == id } ?? newProjects.first
    }

    /// Names the failure in terms of what the user can do about it.
    private func switchFailureMessage(
        for error: any Error,
        organization: OrganizationSummary
    ) -> String {
        guard let posthogError = error as? PostHogError else {
            return "Couldn't switch to \(organization.name). \(error.localizedDescription)"
        }
        switch posthogError {
        case .forbidden:
            // Project-scoped personal keys cannot access organization endpoints;
            // a key without the organization read scope cannot either. Both
            // causes are named because the refusal does not distinguish them,
            // and guessing one would send the user to the wrong setting.
            return """
                Couldn't switch to \(organization.name): PostHog refused the request. \
                A personal API key scoped to specific projects can't read organizations at all, \
                and a key without the \(Self.organizationReadScope) scope can't either. \
                Check both on the key in PostHog, then try again.
                """
        case .unauthorized:
            return "Couldn't switch to \(organization.name): your API key was rejected. Reconnect in Settings."
        default:
            return "Couldn't switch to \(organization.name). \(posthogError.localizedDescription)"
        }
    }

    func refreshCapabilities() async {
        guard let client, let scope = flagWriteScope else { return }
        do {
            let report = try await ScopePreflight(client: client)
                .runRequiringValidCredential(projectID: scope.projectID)
            // A project or credential replacement may have completed while the
            // probes were suspended. Its report belongs to the captured epoch,
            // not whichever session happens to be current when it returns.
            guard flagWriteScope == scope else { return }
            capabilities = report
        } catch PostHogError.unauthorized {
            await invalidateRejectedCredential(ifCurrent: scope)
        } catch {
            // ScopePreflight turns every non-authentication failure into a
            // capability-local `.failed` result. This remains defense-in-depth
            // if a future implementation gains another throwing dependency.
        }
    }

    /// Applies a capability preflight's authentication rejection only while the
    /// exact session that made the request is still current. Internal so both
    /// app test hosts can deterministically exercise the late-response boundary
    /// without holding a live transport request open. `signOut` remains the one
    /// owner of credential, session and customer-data teardown; restoring the
    /// rejection afterward preserves the reconnect reason for onboarding.
    func invalidateRejectedCredential(ifCurrent rejectedScope: FlagWriteScope) async {
        guard flagWriteScope == rejectedScope,
              let region = rejectedScope.projectRegion else { return }
        await signOut()
        connectionError = PostHogError.unauthorized.localizedDescription
        storedCredentialRecovery = .replaceCredential(region)
    }

    // MARK: - Widget snapshot

    /// Publishes the values widgets and Control Center read.
    ///
    /// Foreground publication and out-of-process widget refreshes share the same
    /// coordinator and App Group lease, so they cannot race to publish different
    /// snapshots. Opening the app remains an unconditional refresh.
    @discardableResult
    func publishWidgetSnapshot() async -> Bool {
        // The widget cache renders the user's real workspace on their home
        // screen. A demo entered from onboarding must not overwrite it with
        // fiction that would outlive the visit; the launch-argument demo keeps
        // publishing, because tests and screenshots own their whole simulator.
        guard !isRuntimeDemo else { return false }
        guard let client,
              let project = selectedProject,
              let activeRegion,
              let scope = flagWriteScope else { return false }
        let context = SnapshotPublicationContext(
            generation: snapshotPublicationGeneration,
            authority: .live(scope)
        )
        return await publish(
            using: client,
            projectID: project.id,
            projectName: project.name,
            projectRegion: activeRegion,
            trigger: .foreground,
            context: context
        )
    }

    /// Revalidates the authority that began a publication. Foreground work must
    /// still belong to the exact session project, host, and credential epoch;
    /// a fresh background process must still have no adopted session and the
    /// same durable credential must remain in the store.
    private func snapshotPublicationIsCurrent(
        _ context: SnapshotPublicationContext
    ) -> Bool {
        guard context.generation == snapshotPublicationGeneration else { return false }
        switch context.authority {
        case .live(let scope):
            guard flagWriteScope == scope,
                  let credential = try? store.load() else { return false }
            return credential.region == scope.projectRegion
                && credential.authSessionID == scope.authSessionID
        case .storedCredential(let projectID, let projectRegion, let authSessionID):
            guard client == nil, self.authSessionID == nil, selectedProject == nil,
                  let credential = try? store.load() else { return false }
            let storedProjectID = IntentDependencies.storedProjectID() ?? credential.projectID
            return credential.region == projectRegion
                && credential.authSessionID == authSessionID
                && (storedProjectID == nil || storedProjectID == projectID)
        }
    }

    /// The fetch itself, decoupled from the session so a background wake can run
    /// it against a client it built for one call without disturbing `phase`,
    /// `selectedProject`, or anything else the UI observes.
    private func publish(
        using client: PostHogClient,
        projectID: Int,
        projectName: String,
        projectRegion: PostHogRegion,
        trigger: SnapshotRefreshTrigger,
        now: Date = Date(),
        context: SnapshotPublicationContext
    ) async -> Bool {
        guard snapshotPublicationIsCurrent(context) else { return false }
        let refreshScope = SnapshotRefreshScope(
            projectID: projectID,
            projectName: projectName,
            region: projectRegion,
            authSessionID: context.authority.authSessionID
        )
        let quickToggleScope = FlagQuickToggle.Scope(
            projectID: projectID,
            region: projectRegion
        )
        let result = await snapshotRefresher.refresh(
            trigger: trigger,
            client: client,
            scope: refreshScope,
            now: now,
            quickToggleAllowed: { flagID in
                FlagQuickToggle.isAllowed(flagID: flagID, scope: quickToggleScope)
            },
            isAuthorized: { [weak self] in
                guard let self else { return false }
                return await self.snapshotPublicationIsCurrent(context)
            }
        )

        switch result {
        case .refreshed(_, let pinnedDashboard):
            guard snapshotPublicationIsCurrent(context) else { return false }
            if let pinnedDashboard {
                QuickActions.recordPinnedDashboard(
                    id: pinnedDashboard.id,
                    title: pinnedDashboard.title,
                    projectID: projectID
                )
                QuickActions.refresh(projectID: projectID)
            }
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            return true
        case .current, .coalesced:
            return true
        case .failed, .superseded:
            return false
        }
    }

    // MARK: - Background refresh

    /// Whether a background wake is worth scheduling at all.
    var hasStoredCredential: Bool { (try? store.load()) != nil }

    /// When the widgets' data was last written, wherever it was written from.
    ///
    /// The snapshot is its own record of freshness, so the refresh cadence needs
    /// no separate bookkeeping that could disagree with it.
    var lastSnapshotDate: Date? { snapshotStore.loadOrNil()?.capturedAt }

    /// One coalesced refresh for the retained Mac background scheduler.
    ///
    /// A background launch is a fresh process with no session. The last
    /// snapshot identifies the project, so this rebuilds only the scoped API
    /// client needed by the shared coordinator.
    func performBackgroundRefresh(now: Date = Date()) async -> Bool {
        guard !isRuntimeDemo else { return false }
        let previous = snapshotStore.loadOrNil()
        let storedCredential = try? store.load()
        let currentRegion = activeRegion ?? storedCredential?.region
        let currentAuthSessionID = authSessionID ?? storedCredential?.authSessionID
        let storedProjectID = IntentDependencies.storedProjectID()

        // Validate scope before the cadence shortcut. Otherwise a recent US
        // snapshot can survive an EU credential rotation merely because it is
        // not due yet, and every extension keeps rendering the old account.
        if let previous,
           previous.projectRegion != currentRegion
            || previous.authSessionID != currentAuthSessionID {
            clearPublishedProjectData()
            return false
        }

        let selectedProjectID = selectedProject?.id ?? storedProjectID
        let projectChanged = previous.map { previous in
            selectedProjectID.map { $0 != previous.projectID } == true
        } ?? false
        if projectChanged {
            // A Focus filter or intent can change the selection without ever
            // constructing this AppModel. The prior snapshot's timestamp still
            // decides whether this wake may spend requests, but none of its
            // project data may remain visible or be carried into the new scope.
            clearPublishedProjectData()
        }

        guard SnapshotRefreshPolicy.shouldRefresh(
            trigger: .macBackground,
            capturedAt: previous?.capturedAt,
            now: now
        ) else {
            return !projectChanged
        }

        if let client, let selectedProject, let activeRegion, let scope = flagWriteScope {
            let context = SnapshotPublicationContext(
                generation: snapshotPublicationGeneration,
                authority: .live(scope)
            )
            return await publish(
                using: client,
                projectID: selectedProject.id,
                projectName: selectedProject.name,
                projectRegion: activeRegion,
                trigger: .macBackground,
                now: now,
                context: context
            )
        }

        guard let credential = storedCredential,
              let credentialAuthSessionID = credential.authSessionID else { return false }
        // Without a previous snapshot there is no project to refresh and no
        // widget showing anything to correct. Discovering one would cost six
        // requests to learn what the next foreground launch learns for free.
        guard let previous else { return false }
        let projectID = storedProjectID ?? previous.projectID
        let projectName = projectID == previous.projectID
            ? previous.projectName
            : "Project \(projectID)"

        // Built here rather than stored: the wake must not leave a half-started
        // session behind for the next foreground launch to inherit. It shares
        // this model's governor, so background traffic counts against the same
        // budget and shows up in the Settings meter like everything else.
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: credential.key, region: credential.region),
            transport: transport,
            governor: governor
        )
        let context = SnapshotPublicationContext(
            generation: snapshotPublicationGeneration,
            authority: .storedCredential(
                projectID: projectID,
                projectRegion: credential.region,
                authSessionID: credentialAuthSessionID
            )
        )
        return await publish(
            using: client,
            projectID: projectID,
            projectName: projectName,
            projectRegion: credential.region,
            trigger: .macBackground,
            now: now,
            context: context
        )
    }

    /// The window the widget's ingestion section is aggregated over.
    ///
    /// The Ingestion screen's own default. Forty-eight hours would be more
    /// current but would miss a problem that started three days ago and never
    /// stopped, and — more importantly — a widget that reported a different
    /// number from the screen it opens would make both of them untrustworthy.
    static let snapshotIngestionWindow = SnapshotRefreshCoordinator.ingestionWindow

    /// The out-of-process widget and menu-bar hand-off owns the same feature-
    /// flag mutation as the on-screen controller. Keep its unnamed-403 fallback
    /// linked to the catalog rather than retaining another scope spelling.
    static var requiredFlagWriteScope: String {
        APIKeyScopeGuidance.optionalWriteDescriptor(for: .featureFlags).scope
    }

    // The tile-to-metric reduction lives in the kit, as
    // `SharedSnapshot.Metric.init?(tile:dashboardID:)`. It was duplicated
    // here, and a rule with two copies is a rule that can disagree with
    // itself — which is what the funnel branch's permanent false decline to
    // the Lock Screen was: a category error fixed in one copy at a time.
    // `AppModelTests`' tile suite now pins the kit initialiser from this
    // side, beside the kit's own "Dashboard tile reduced to a snapshot
    // metric" suite; the funnel rationale travels with the code.

    // MARK: - Intent hand-off

    /// Applies work an out-of-process intent could not finish itself.
    ///
    /// The extension has no keychain access, no rate-limit governor and nowhere
    /// to show a 403, so a flag toggle requested from a widget is recorded and
    /// completed here instead.
    func consumePendingIntentWork() async {
        // A widget-recorded toggle names a flag in the user's real workspace.
        // Consuming it against the demo fixtures would both lose the request
        // and claim it was honored; it stays pending for the real session.
        guard !isRuntimeDemo else { return }
        if let pending = snapshotStore.pendingFlagWrite() {
            snapshotStore.clearPendingFlagWrite()
            guard let projectID = pending.projectID,
                  let projectRegion = pending.projectRegion,
                  let authSessionID = pending.authSessionID else {
                // Records written by an older extension have no authenticated
                // provenance. They remain decodable so an upgrade cannot wedge
                // the hand-off file, but they are deliberately not writeable.
                return
            }
            let quickToggleScope = FlagQuickToggle.Scope(
                projectID: projectID,
                region: projectRegion
            )
            guard FlagQuickToggle.isAllowed(
                flagID: pending.flagID,
                scope: quickToggleScope
            ) else { return }
            let expectedScope = FlagWriteScope(
                projectID: projectID,
                projectRegion: projectRegion,
                authSessionID: authSessionID
            )
            _ = await setFlag(
                id: pending.flagID,
                active: pending.desiredActive,
                expectedScope: expectedScope
            )
        }
    }

    @discardableResult
    func setFlag(id: Int, active: Bool) async -> FlagWriteOutcome {
        guard let scope = flagWriteScope else {
            return .failed("GetHog isn't connected to a project.")
        }
        return await setFlag(id: id, active: active, expectedScope: scope)
    }

    /// Applies a snapshot-originated write only while that snapshot still names
    /// the active project and host. This check runs when the async call enters
    /// the main actor — after any caller-side biometric suspension — so a stale
    /// same-numeric-id flag can never be substituted into the current project.
    @discardableResult
    func setFlag(
        id: Int,
        active: Bool,
        expectedScope: FlagWriteScope
    ) async -> FlagWriteOutcome {
        guard expectedScope.projectRegion != nil, flagWriteScope == expectedScope else {
            return .failed("The project changed before the flag could be updated.")
        }
        guard let client, let project = selectedProject else {
            return .failed("GetHog isn't connected to a project.")
        }
        do {
            _ = try await client.data(
                for: PostHogAPI.setFlagActive(projectID: project.id, flagID: id, active: active)
            )
        } catch {
            if let posthog = error as? PostHogError,
               case .forbidden(missingScope: nil, detail: let detail) = posthog {
                let said = detail.map { " PostHog said: \($0)" } ?? ""
                return .failed(
                    """
                    PostHog refused the flag change and didn't say which permission was missing.\
                    \(said) If your key is missing the \(Self.requiredFlagWriteScope) scope, \
                    adding it may fix this; otherwise ask an organization admin to check your role.
                    """
                )
            }
            return .failed(error.localizedDescription)
        }
        await publishWidgetSnapshot()
        return .changed
    }

    func signOut() async {
        // The client remains retained until its lease is durably revoked. Cache
        // publication and revocation serialize in ResponseCache: a publication
        // that linearized first is removed by the ordered clear, while one that
        // reaches the actor later observes revocation and cannot commit.
        if let client {
            await client.revokeCachePublication()
        }
        await cache.clear()

        snapshotPublicationGeneration &+= 1
        let preserveSharedProjectData = isRuntimeDemo
        // Also the exit from a runtime demo: the fixtures must not answer the
        // next connection's requests.
        transport = baseTransport
        isRuntimeDemo = false
        try? store.clear()
        // The retained Mac scheduler must stop with the credential. iOS has no
        // app-owned background scheduler; widgets refresh independently.
        #if os(macOS)
        BackgroundRefresh.cancel()
        #endif
        // Dashboard and flag names are project data — they name a customer's
        // business — and must not survive on the home screen past the credential
        // that could read them. A runtime demo has no credential to revoke and
        // deliberately never took ownership of the real workspace's shared
        // snapshot or pending records, so leaving it must not clear them.
        QuickActions.clear()
        if !preserveSharedProjectData {
            clearPublishedProjectData()
        }
        client = nil
        activeRegion = nil
        authSessionID = nil
        me = nil
        capabilities = nil
        connectionError = nil
        storedCredentialRecovery = nil
        projects = []
        selectedProject = nil
        // Organization names name a customer's business exactly as project names
        // do, and the cached project lists are that customer's data. Neither may
        // outlive the credential that could read them.
        organizations = []
        selectedOrganizationID = nil
        projectsByOrganization = [:]
        organizationError = nil
        UserDefaults.standard.removeObject(forKey: "selectedOrganizationID")
        phase = .onboarding
    }

    private func clearPublishedProjectData() {
        snapshotStore.clearProjectData()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Convenience

    var projectID: Int? { selectedProject?.id }

    /// Whether a capability's screen may open.
    ///
    /// Permissive by design, at both levels: no report yet means the preflight
    /// has not run, and a probe that failed means it ran without getting an
    /// answer. Neither is evidence against the key, and only evidence may close
    /// a screen. `CapabilityReport.isAvailable` carries the same rule for the
    /// three-state probe result.
    func isAvailable(_ capability: Capability) -> Bool {
        capabilities?.isAvailable(capability) ?? true
    }

    /// The scope to add, and `nil` whenever there is no denial behind it.
    ///
    /// This used to pattern-match `.locked` here while `isAvailable` compared
    /// against `.available`, so the two disagreed about `.failed`: the screen
    /// locked, this returned `nil`, and the lock then made an unqualified claim
    /// about the user's key with nothing behind it. One implementation now.
    func lockedScope(for capability: Capability) -> String? {
        capabilities?.lockedScope(for: capability)
    }

    /// Why the permission check could not reach a verdict, when it could not.
    func probeFailure(for capability: Capability) -> String? {
        capabilities?.probeFailure(capability)
    }

    /// Deep link into the equivalent page of the web console.
    func webURL(path: String) -> URL? {
        guard let client, let project = selectedProject else { return nil }
        return client.host
            .appendingPathComponent("project/\(project.id)")
            .appendingPathComponent(path)
    }

    /// What happened when a link asked for a particular project.
    enum ProjectSwitch: Equatable, Sendable {
        /// Already looking at it; nothing moved.
        case current
        /// Switched, and the new project's name, so the caller can say which.
        case switched(name: String)
        /// This credential has no such project. Never resolved to anything else.
        case inaccessible
    }

    /// Moves to the project a link named, or refuses.
    ///
    /// The refusal is the point. A link carries a project id, and the id it
    /// carries is routinely not the one on screen — a colleague's link, a link
    /// from a week ago, a link from the other environment. Falling back to the
    /// selected project would render that link's dashboard id against a
    /// *different* project's data: the same numbers-under-the-wrong-name bug the
    /// project switcher sits on every screen to prevent. So an id this key
    /// cannot see stops here and is reported.
    func selectProject(id: Int) -> ProjectSwitch {
        if id == selectedProject?.id { return .current }
        guard let project = projects.first(where: { $0.id == id }) else { return .inaccessible }
        selectedProject = project
        return .switched(name: project.name)
    }

    /// Picks up a project chosen outside the app — by a Focus filter or an
    /// intent — without clobbering the user's choice if it hasn't changed.
    func adoptExternallySelectedProject() {
        guard let id = IntentDependencies.storedProjectID(),
              id != selectedProject?.id,
              let project = projects.first(where: { $0.id == id })
        else { return }
        selectedProject = project
    }

    private func persistSelectedProject(_ id: Int) {
        // Written to both stores: the app reads `.standard`, while intents and
        // widgets run in other processes and can only see the App Group.
        UserDefaults.standard.set(id, forKey: "selectedProjectID")
        IntentDependencies.persistSelectedProject(id)
        Task {
            await publishWidgetSnapshot()
            await SpotlightIndexer.reindex(projectID: id)
        }
    }

    private func loadPersistedProjectID() -> Int? {
        let id = UserDefaults.standard.integer(forKey: "selectedProjectID")
        return id == 0 ? nil : id
    }

    /// Written to `.standard` alone, unlike the project id.
    ///
    /// The project id also goes to the App Group because widgets and intents run
    /// in other processes and need it. The organization id has no such reader:
    /// nothing outside the app knows what an organization is, and a widget's
    /// project id already identifies its project unambiguously.
    private func persistSelectedOrganization(_ id: String) {
        UserDefaults.standard.set(id, forKey: "selectedOrganizationID")
    }

    private func loadPersistedOrganizationID() -> String? {
        UserDefaults.standard.string(forKey: "selectedOrganizationID")
    }
}
