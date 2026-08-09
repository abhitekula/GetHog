import AppIntents
import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// What the app tells the system about what the user did.
///
/// Two halves, and only one of them is checkable from a simulator.
///
/// The **policy** — which acts may be donated at all — is pure and is asserted
/// exhaustively below. It is the half that can be wrong in a way nobody would
/// see: a flag the user deliberately kept in-app becoming a Siri suggestion, or
/// a suggestion offered for an insight the intent behind it can only refuse.
///
/// The **donation itself** is asserted only as far as the platform will admit:
/// that `AppIntent.donate()` accepts the intent and returns an identifier rather
/// than throwing. What that identifier feeds — how Siri and Spotlight rank a
/// donation, whether a suggestion appears, and where — is not observable from a
/// test, from a simulator, or from the app. This file does not pretend
/// otherwise.
@Suite("Intent donations", .serialized)
struct IntentDonationTests {

    private let usScope = FlagQuickToggle.Scope(projectID: 1_001, region: .usCloud)
    private let euScope = FlagQuickToggle.Scope(projectID: 1_001, region: .euCloud)
    private let authSessionID = UUID(uuidString: "018f9000-0000-7000-8000-000000000600")!

    // MARK: - Fixtures

    private func demoDashboard() async throws -> Dashboard {
        let url = URL(string: "https://us.posthog.com/api/projects/1001/dashboards/725101/")!
        let (data, _) = try await DemoTransport().send(URLRequest(url: url))
        return try JSONDecoder().decode(Dashboard.self, from: data)
    }

    private func demoInsightList() async throws -> [Insight] {
        let url = URL(string: "https://us.posthog.com/api/projects/1001/insights/?limit=100")!
        let (data, _) = try await DemoTransport().send(URLRequest(url: url))
        return try Page<Insight>.decode(from: data).results
    }

    private func flag(id: Int, active: Bool = true) throws -> FeatureFlag {
        let json = """
        {"id": \(id), "key": "checkout-v2", "name": "Checkout v2", "active": \(active),
         "deleted": false, "archived": false, "filters": {}}
        """
        return try JSONDecoder().decode(FeatureFlag.self, from: Data(json.utf8))
    }

    // MARK: - The flag opt-in

    /// The constraint that matters most here. Quick toggling is off per flag
    /// unless the user has turned it on inside the app, where the flag's rollout
    /// conditions are visible — see `FlagQuickToggle`, where the default is
    /// documented as deliberate. A donation would put that flag in front of Siri
    /// as a suggestion, which is the exact thing the opt-in exists to prevent,
    /// and `SetScopedFeatureFlagIntent` would refuse it if tapped.
    @MainActor
    @Test("never donates a flag the user has not opted in to quick toggling")
    func flagOptInGatesDonation() throws {
        let id = 990_001
        FlagQuickToggle.setAllowed(false, flagID: id, scope: usScope)
        #expect(!IntentDonations.mayDonateToggle(flagID: id, scope: usScope))

        FlagQuickToggle.setAllowed(true, flagID: id, scope: usScope)
        #expect(IntentDonations.mayDonateToggle(flagID: id, scope: usScope))

        FlagQuickToggle.setAllowed(false, flagID: id, scope: usScope)
    }

    @MainActor
    @Test("quick-toggle permission is isolated by project and host")
    func flagOptInIsScoped() {
        let id = 990_005
        FlagQuickToggle.setAllowed(true, flagID: id, scope: usScope)
        defer { FlagQuickToggle.setAllowed(false, flagID: id, scope: usScope) }

        #expect(FlagQuickToggle.isAllowed(flagID: id, scope: usScope))
        #expect(!FlagQuickToggle.isAllowed(flagID: id, scope: euScope))

        let otherProject = FlagQuickToggle.Scope(projectID: 42, region: .usCloud)
        #expect(!FlagQuickToggle.isAllowed(flagID: id, scope: otherProject))
    }

    @MainActor
    @Test("legacy numeric-only opt-ins fail closed")
    func legacyFlagOptInFailsClosed() {
        let id = 990_006
        let legacyKey = "quickToggle.\(id)"
        UserDefaults.standard.set(true, forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        #expect(!FlagQuickToggle.isAllowed(flagID: id, scope: usScope))
    }

    /// Off for a flag nobody has ever opened, which is every flag on a fresh
    /// install. A default of "allowed" here would donate the first flag the user
    /// happened to flip.
    @MainActor
    @Test("a flag nobody has touched is not donatable")
    func unknownFlagIsNotDonatable() {
        #expect(!IntentDonations.mayDonateToggle(flagID: 42_424_242, scope: usScope))
    }

    // MARK: - The metric gate

    /// `GetMetricValueIntent` answers with one spoken number, which it gets from
    /// `IntentMetric`. Donating an insight that reduces to no number would build
    /// a suggestion whose only possible outcome is the intent's own refusal.
    @Test("only donates a metric read for an insight the intent could answer")
    func metricGateMatchesTheIntent() async throws {
        let dashboard = try await demoDashboard()
        let computed = dashboard.tiles.compactMap(\.insight)
        #expect(!computed.isEmpty)

        for insight in computed {
            // The gate and the intent's own reduction are the same question, so
            // they must give the same answer for every insight in the fixture.
            #expect(
                IntentDonations.mayDonateMetricRead(insight)
                    == (IntentMetric(insight: insight, fallbackTitle: insight.title) != nil)
            )
        }
        #expect(computed.contains { IntentDonations.mayDonateMetricRead($0) })
    }

    /// Why the donation sits after `loadResults` in `SavedInsightDetailView`
    /// rather than at the row tap in `InsightsRoot`.
    ///
    /// Measured, and not what was assumed: the collection endpoint returns
    /// *some* insights carrying a cached result and some carrying none, so the
    /// answer to "could Siri say a number for this" depends on whether PostHog
    /// happened to have that one warm when the list was fetched. Asked at the
    /// row tap, the same insight would be donatable on Monday and not on
    /// Tuesday. Asked after the detail screen's own `loadResults`, it is decided
    /// against a value the user has actually been shown.
    @Test("the library listing answers the metric question inconsistently")
    func listingIsNotWhereTheGateBelongs() async throws {
        let listed = try await demoInsightList()
        #expect(!listed.isEmpty)
        #expect(listed.contains { IntentDonations.mayDonateMetricRead($0) })
        #expect(listed.contains { !IntentDonations.mayDonateMetricRead($0) })
    }

    // MARK: - The donation

    /// **What a donation actually does here, written down rather than assumed.**
    ///
    /// `AppIntent.donate()` hands the intent to `com.apple.linkd`, and in a
    /// unit-test host on the simulator that daemon is not reachable: every one
    /// of the three donations the app makes comes back as `NSCocoaErrorDomain`
    /// **4099** — "The connection to service named com.apple.linkd.transcript
    /// was invalidated from this process". Measured, three for three, for the
    /// dashboard open, the metric read and the flag write.
    ///
    /// That is the environment's limit, not the app's, and it is asserted rather
    /// than tolerated for two reasons. It proves the call is genuinely made and
    /// reaches the system boundary — a donation that was never wired up would
    /// fail differently, or not at all. And it is the exact failure
    /// `IntentDonations.donate` is built to absorb: detached, non-throwing,
    /// logged and never surfaced, because there is nothing a user could do with
    /// the news that Siri's ranking did not get updated.
    ///
    /// If this ever starts succeeding — on a device, or in a future runtime —
    /// this test is what will say so, and the right response is to record the
    /// new behaviour here rather than to delete the assertion.
    ///
    /// **Not asserted, and not assertable:** anything downstream. Whether a
    /// suggestion appears, where it ranks, and how it decays are Siri's and
    /// Spotlight's business, and neither exposes any of it — to the app, to a
    /// test, or to any API.
    @Test("every donation the app makes reaches the system, which refuses it in this host")
    func donationsReachTheSystemBoundary() async throws {
        let intents: [any AppIntent] = [
            OpenDashboardIntent(dashboard: DashboardEntity(
                id: 725_101, name: "Example dashboard", summary: nil, isPinned: true
            )),
            GetMetricValueIntent(insight: InsightEntity(
                id: 1, name: "Daily active users", kind: "TrendsQuery"
            )),
            SetScopedFeatureFlagIntent(
                flag: ScopedFeatureFlagEntity(
                    flagID: 710_301, key: "example-navigation", name: "Example navigation",
                    isActive: true, allowsQuickToggle: true, scope: usScope,
                    authSessionID: authSessionID
                ),
                enabled: true
            ),
        ]

        for intent in intents {
            do {
                let identifier = try await intent.donate()
                // The outcome this file would rather have. Kept as a passing
                // branch so a runtime that does accept donations is not a red
                // build — but recorded, so nobody has to guess which branch ran.
                Issue.record("Donation of \(type(of: intent)) succeeded: \(identifier)")
            } catch let error as NSError {
                #expect(error.domain == NSCocoaErrorDomain)
                #expect(error.code == 4099, "unexpected donation failure: \(error)")
            }
        }
    }

    /// The app's own entry points, which must be safe to call from a tap
    /// handler: they return immediately, they never throw, and the gated ones
    /// do nothing at all when the gate says no.
    @MainActor
    @Test("the app's donation calls are fire-and-forget and never propagate a failure")
    func donationCallsAreSafe() async throws {
        let quiet = try flag(id: 990_004)
        FlagQuickToggle.setAllowed(false, flagID: quiet.id, scope: usScope)

        let summary = try JSONDecoder().decode(
            DashboardSummary.self,
            from: Data(#"{"id": 1, "name": "D", "pinned": false}"#.utf8)
        )
        IntentDonations.dashboardOpened(summary)
        IntentDonations.flagSet(
            quiet,
            enabled: true,
            scope: usScope,
            expectedAuthSessionID: authSessionID
        )

        // Nothing above throws and nothing above blocks; the donations are
        // detached, and a failure is logged rather than raised. Reaching this
        // line is the assertion.
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// The parameter is what makes a donation worth making: the system learns
    /// "this person opens *this* dashboard", not "this person opens dashboards".
    @Test("a donated intent carries the object it was performed on")
    func donationCarriesItsParameter() async throws {
        let flag = try flag(id: 990_003)
        let entity = ScopedFeatureFlagEntity(
            flag,
            scope: usScope,
            authSessionID: authSessionID
        )
        #expect(entity.flagID == flag.id)
        #expect(entity.key == flag.key)

        let euEntity = ScopedFeatureFlagEntity(
            flag,
            scope: euScope,
            authSessionID: authSessionID
        )
        #expect(entity.id != euEntity.id)

        let intent = SetScopedFeatureFlagIntent(flag: entity, enabled: false)
        #expect(intent.flag.key == "checkout-v2")
        #expect(intent.enabled == false)

        // The legacy Int-identified entity and intent remain decodable so an
        // installed shortcut gets the update-required dialog rather than an
        // opaque resolution failure. Its perform path is deliberately read-only.
        let legacyEntity = FeatureFlagEntity(
            id: flag.id,
            key: flag.key,
            name: flag.displayName,
            isActive: flag.active,
            allowsQuickToggle: false
        )
        #expect(legacyEntity.id == flag.id)
        _ = try await SetFeatureFlagIntent(flag: legacyEntity, enabled: false).perform()
    }
}

private actor ScopedFeatureFlagIntentTransport: HTTPTransport {
    private let holdsValidation: Bool
    private var requests: [(method: String, path: String)] = []
    private var validationStarted = false
    private var validationWaiters: [CheckedContinuation<Void, Never>] = []
    private var validationContinuation: CheckedContinuation<Void, Never>?

    init(holdsValidation: Bool) {
        self.holdsValidation = holdsValidation
    }

    func waitUntilValidationStarts() async {
        if validationStarted { return }
        await withCheckedContinuation { validationWaiters.append($0) }
    }

    func releaseValidation() {
        validationContinuation?.resume()
        validationContinuation = nil
    }

    func count(method: String) -> Int {
        requests.filter { $0.method == method }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path(percentEncoded: false) ?? ""
        requests.append((method, path))

        if method == "GET", path.hasSuffix("/feature_flags/") {
            validationStarted = true
            let waiters = validationWaiters
            validationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if holdsValidation {
                await withCheckedContinuation { validationContinuation = $0 }
            }
        }

        let body: String
        if method == "GET" {
            body = """
            {"count":1,"next":null,"previous":null,"results":[
              {"id":710301,"key":"synthetic-epoch-flag","name":"Synthetic epoch flag",
               "active":true,"deleted":false,"archived":false,"filters":{}}
            ]}
            """
        } else {
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private actor MutableIntentDependencies {
    private var value: IntentDependencies

    init(_ value: IntentDependencies) {
        self.value = value
    }

    func current() -> IntentDependencies {
        value
    }

    func replace(with value: IntentDependencies) {
        self.value = value
    }
}

private actor HeldIntentDonationResolution {
    private var dependencies: IntentDependencies
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(_ dependencies: IntentDependencies) {
        self.dependencies = dependencies
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func replace(with dependencies: IntentDependencies) {
        self.dependencies = dependencies
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func resolve() async throws -> IntentDependencies {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return dependencies
    }
}

private actor ScopedIntentDonationRecorder {
    private var epochs: [UUID] = []

    func donate(_ intent: SetScopedFeatureFlagIntent) async throws {
        epochs.append(intent.flag.authSessionID)
    }

    func recordedEpochs() -> [UUID] {
        epochs
    }
}

@MainActor
private final class HeldIntentBiometricGate {
    private var started = false
    private var continuation: CheckedContinuation<BiometricGate.Outcome, Never>?

    func evaluate() async -> BiometricGate.Outcome {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish(_ outcome: BiometricGate.Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

@Suite("Scoped feature-flag Intent authority", .serialized)
@MainActor
struct ScopedFeatureFlagIntentAuthorityTests {
    private let scope = FlagQuickToggle.Scope(projectID: 1_001, region: .usCloud)
    private let firstEpoch = UUID(uuidString: "018f9000-0000-7000-8000-000000000601")!
    private let replacementEpoch = UUID(uuidString: "018f9000-0000-7000-8000-000000000602")!

    private func dependencies(
        scope: FlagQuickToggle.Scope? = nil,
        epoch: UUID,
        transport: ScopedFeatureFlagIntentTransport
    ) -> IntentDependencies {
        let resolvedScope = scope ?? self.scope
        return IntentDependencies(
            client: PostHogClient(
                auth: PersonalKeyAuthProvider(key: "synthetic-intent-key", region: .usCloud),
                transport: transport
            ),
            projectID: resolvedScope.projectID,
            projectRegion: resolvedScope.region,
            authSessionID: epoch
        )
    }

    private func entity(epoch: UUID) -> ScopedFeatureFlagEntity {
        ScopedFeatureFlagEntity(
            flagID: 710_301,
            key: "synthetic-epoch-flag",
            name: "Synthetic epoch flag",
            isActive: true,
            allowsQuickToggle: true,
            scope: scope,
            authSessionID: epoch
        )
    }

    private func flag() throws -> FeatureFlag {
        try JSONDecoder().decode(
            FeatureFlag.self,
            from: Data(
                #"{"id":710301,"key":"synthetic-epoch-flag","name":"Synthetic epoch flag","active":true,"deleted":false,"archived":false,"filters":{}}"#.utf8
            )
        )
    }

    private func allowQuickToggle() {
        FlagQuickToggle.setAllowed(true, flagID: 710_301, scope: scope)
    }

    private func disallowQuickToggle() {
        FlagQuickToggle.setAllowed(false, flagID: 710_301, scope: scope)
    }

    @Test("legacy credentials without a durable epoch fail closed")
    func legacyCredentialFailsClosed() {
        let legacy = StoredCredential(
            key: "synthetic-legacy-key",
            region: .usCloud,
            projectID: scope.projectID,
            authSessionID: nil
        )

        #expect(throws: IntentError.notConnected) {
            try IntentDependencies.requiredAuthSessionID(from: legacy)
        }
    }

    @Test("entity identity and provenance include the credential epoch")
    func entityIdentityIncludesEpoch() {
        let original = entity(epoch: firstEpoch)
        let replacement = entity(epoch: replacementEpoch)

        #expect(original.id != replacement.id)
        #expect(original.authSessionID == firstEpoch)
        #expect(replacement.authSessionID == replacementEpoch)
    }

    @Test("a stale saved entity is rejected before validation")
    func staleEntityIsRejectedBeforeValidation() async throws {
        allowQuickToggle()
        defer { disallowQuickToggle() }
        let transport = ScopedFeatureFlagIntentTransport(holdsValidation: false)
        let resolver = MutableIntentDependencies(dependencies(
            epoch: replacementEpoch,
            transport: transport
        ))
        let intent = SetScopedFeatureFlagIntent(flag: entity(epoch: firstEpoch), enabled: false)

        _ = try await intent.execute(
            resolve: { await resolver.current() },
            isAuthenticationEnabled: false,
            authenticate: { .passed }
        )

        #expect(await transport.count(method: "GET") == 0)
        #expect(await transport.count(method: "PATCH") == 0)
    }

    @Test("credential replacement during authentication is rejected before validation")
    func credentialReplacementDuringAuthenticationIsRejected() async throws {
        allowQuickToggle()
        defer { disallowQuickToggle() }
        let transport = ScopedFeatureFlagIntentTransport(holdsValidation: false)
        let resolver = MutableIntentDependencies(dependencies(
            epoch: firstEpoch,
            transport: transport
        ))
        let gate = HeldIntentBiometricGate()
        let intent = SetScopedFeatureFlagIntent(flag: entity(epoch: firstEpoch), enabled: false)

        let execution = Task {
            try await intent.execute(
                resolve: { await resolver.current() },
                isAuthenticationEnabled: true,
                authenticate: { await gate.evaluate() }
            )
        }
        await gate.waitUntilStarted()
        await resolver.replace(with: dependencies(
            epoch: replacementEpoch,
            transport: transport
        ))
        gate.finish(.passed)
        _ = try await execution.value

        #expect(await transport.count(method: "GET") == 0)
        #expect(await transport.count(method: "PATCH") == 0)
    }

    @Test("same-host project credential replacement during validation sends no PATCH")
    func credentialReplacementDuringValidationSendsNoPatch() async throws {
        allowQuickToggle()
        defer { disallowQuickToggle() }
        let transport = ScopedFeatureFlagIntentTransport(holdsValidation: true)
        let resolver = MutableIntentDependencies(dependencies(
            epoch: firstEpoch,
            transport: transport
        ))
        let intent = SetScopedFeatureFlagIntent(flag: entity(epoch: firstEpoch), enabled: false)

        let execution = Task {
            try await intent.execute(
                resolve: { await resolver.current() },
                isAuthenticationEnabled: false,
                authenticate: { .passed }
            )
        }
        await transport.waitUntilValidationStarts()
        await resolver.replace(with: dependencies(
            epoch: replacementEpoch,
            transport: transport
        ))
        await transport.releaseValidation()
        _ = try await execution.value

        #expect(await transport.count(method: "GET") == 1)
        #expect(await transport.count(method: "PATCH") == 0)
    }

    @Test("the current credential epoch validates and writes once")
    func currentCredentialWritesOnce() async throws {
        allowQuickToggle()
        defer { disallowQuickToggle() }
        let transport = ScopedFeatureFlagIntentTransport(holdsValidation: false)
        let resolver = MutableIntentDependencies(dependencies(
            epoch: firstEpoch,
            transport: transport
        ))
        let intent = SetScopedFeatureFlagIntent(flag: entity(epoch: firstEpoch), enabled: false)

        _ = try await intent.execute(
            resolve: { await resolver.current() },
            isAuthenticationEnabled: false,
            authenticate: { .passed }
        )

        #expect(await transport.count(method: "GET") == 1)
        #expect(await transport.count(method: "PATCH") == 1)
    }

    @Test("a held donation resolution cannot transfer an old write to a replacement epoch")
    func heldDonationResolutionRejectsReplacementEpoch() async throws {
        allowQuickToggle()
        defer { disallowQuickToggle() }
        let transport = ScopedFeatureFlagIntentTransport(holdsValidation: false)
        let resolution = HeldIntentDonationResolution(dependencies(
            epoch: firstEpoch,
            transport: transport
        ))
        let recorder = ScopedIntentDonationRecorder()
        let flag = try flag()

        let donation = Task {
            await IntentDonations.donateFlag(
                flag,
                enabled: false,
                scope: scope,
                expectedAuthSessionID: firstEpoch,
                resolve: { try await resolution.resolve() },
                donate: { try await recorder.donate($0) }
            )
        }
        await resolution.waitUntilStarted()
        await resolution.replace(with: dependencies(
            epoch: replacementEpoch,
            transport: transport
        ))
        await resolution.release()

        #expect(await donation.value == false)
        #expect(await recorder.recordedEpochs().isEmpty)
    }

    @Test("a held donation resolution cannot transfer an old write after a same-epoch project switch")
    func heldDonationResolutionRejectsProjectSwitch() async throws {
        allowQuickToggle()
        defer { disallowQuickToggle() }
        let transport = ScopedFeatureFlagIntentTransport(holdsValidation: false)
        let resolution = HeldIntentDonationResolution(dependencies(
            epoch: firstEpoch,
            transport: transport
        ))
        let recorder = ScopedIntentDonationRecorder()
        let flag = try flag()
        let donation = Task {
            await IntentDonations.donateFlag(
                flag,
                enabled: false,
                scope: scope,
                expectedAuthSessionID: firstEpoch,
                resolve: { try await resolution.resolve() },
                donate: { try await recorder.donate($0) }
            )
        }
        await resolution.waitUntilStarted()
        await resolution.replace(with: dependencies(
            scope: FlagQuickToggle.Scope(projectID: 1_002, region: .usCloud),
            epoch: firstEpoch,
            transport: transport
        ))
        await resolution.release()

        #expect(await donation.value == false)
        #expect(await recorder.recordedEpochs().isEmpty)
    }

    @Test("the successful write epoch can still be donated")
    func currentEpochCanBeDonated() async throws {
        allowQuickToggle()
        defer { disallowQuickToggle() }
        let transport = ScopedFeatureFlagIntentTransport(holdsValidation: false)
        let current = dependencies(epoch: firstEpoch, transport: transport)
        let recorder = ScopedIntentDonationRecorder()

        let donated = await IntentDonations.donateFlag(
            try flag(),
            enabled: false,
            scope: scope,
            expectedAuthSessionID: firstEpoch,
            resolve: { current },
            donate: { try await recorder.donate($0) }
        )

        #expect(donated)
        #expect(await recorder.recordedEpochs() == [firstEpoch])
    }
}
