import Foundation
import Observation
import GetHogKit

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

    private(set) var phase: Phase = .loading
    private(set) var client: PostHogClient?
    private(set) var me: MeResponse?
    private(set) var capabilities: CapabilityReport?
    private(set) var connectionError: String?

    var projects: [Project] = []
    var selectedProject: Project? {
        didSet {
            guard let selectedProject, selectedProject.id != oldValue?.id else { return }
            persistSelectedProject(selectedProject.id)
            Task { await refreshCapabilities() }
        }
    }

    let store: any CredentialStoring
    let cache = ResponseCache()
    private let governor = RateLimitGovernor()
    private let transport: any HTTPTransport

    init(
        store: any CredentialStoring = KeychainTokenStore(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.store = store
        self.transport = transport
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard let credential = try? store.load() else {
            phase = .onboarding
            return
        }
        do {
            try await activate(credential: credential)
        } catch {
            // A stored key that no longer works should land the user on
            // onboarding with an explanation, not an empty dashboard.
            connectionError = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
            phase = .onboarding
        }
    }

    /// Validates a credential and, on success, becomes the active session.
    func connect(key: String, region: PostHogRegion) async throws {
        let credential = StoredCredential(key: key, region: region)
        try await activate(credential: credential)
        try store.save(credential)
    }

    private func activate(credential: StoredCredential) async throws {
        let client = PostHogClient(
            auth: PersonalKeyAuthProvider(key: credential.key, region: credential.region),
            transport: transport,
            governor: governor
        )

        let me: MeResponse = try await client.send(PostHogAPI.me())

        self.client = client
        self.me = me
        self.projects = me.projects.isEmpty
            ? [me.currentProject].compactMap { $0 }
            : me.projects

        let storedID = credential.projectID ?? loadPersistedProjectID()
        self.selectedProject = projects.first { $0.id == storedID }
            ?? me.currentProject
            ?? projects.first

        self.connectionError = nil
        self.phase = .ready

        await refreshCapabilities()
    }

    func refreshCapabilities() async {
        guard let client, let project = selectedProject else { return }
        capabilities = await ScopePreflight(client: client).run(projectID: project.id)
    }

    func signOut() {
        try? store.clear()
        Task { await cache.clear() }
        client = nil
        me = nil
        capabilities = nil
        projects = []
        selectedProject = nil
        phase = .onboarding
    }

    // MARK: - Convenience

    var projectID: Int? { selectedProject?.id }

    func isAvailable(_ capability: Capability) -> Bool {
        capabilities?.isAvailable(capability) ?? true
    }

    func lockedScope(for capability: Capability) -> String? {
        guard case .locked(let scope) = capabilities?.status(capability) else { return nil }
        return scope ?? capability.requiredScopes.joined(separator: ", ")
    }

    /// Deep link into the equivalent page of the web console.
    func webURL(path: String) -> URL? {
        guard let client, let project = selectedProject else { return nil }
        return client.host
            .appendingPathComponent("project/\(project.id)")
            .appendingPathComponent(path)
    }

    private func persistSelectedProject(_ id: Int) {
        UserDefaults.standard.set(id, forKey: "selectedProjectID")
    }

    private func loadPersistedProjectID() -> Int? {
        let id = UserDefaults.standard.integer(forKey: "selectedProjectID")
        return id == 0 ? nil : id
    }
}
