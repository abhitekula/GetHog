import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch model")
@MainActor
struct WatchModelTests {

    @Test("a refresh reduces the pinned dashboard's tiles to metrics")
    func refreshReducesDashboardTiles() async {
        let store = WatchFixtures.tempStore()
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: store
        )

        await model.refresh()

        #expect(model.phase == .ready)
        #expect(model.snapshot?.metrics.count == 2)
        let first = try? #require(model.snapshot?.metrics.first)
        #expect(first?.id == "501")
        #expect(first?.value == 3)
        #expect(first?.previous == 2)
        #expect(first?.sparkline == [1, 2, 3])
        // Only a trends tile has a time axis, so only it gets a render model.
        #expect(model.headlineRender != nil)
        #expect(model.snapshot?.metric(id: "502")?.value == 393)
    }

    @Test("a refresh writes the snapshot the widgets read")
    func refreshWritesSnapshotToStore() async throws {
        let store = WatchFixtures.tempStore()
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: store
        )

        await model.refresh()

        let written = try #require(store.loadOrNil())
        #expect(written.projectID == 1001)
        #expect(written.projectName == "Synthetic Analytics")
        #expect(written.projectRegion == .usCloud)
        #expect(written.capturedAt == WatchFixtures.now)
        #expect(written.metrics.count == 2)
    }

    @Test("the headline honours the chosen metric id")
    func headlineHonorsChosenID() async {
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: WatchFixtures.tempStore(),
            headline: "502"
        )

        await model.refresh()

        #expect(model.headlineMetric?.id == "502")
        #expect(model.headlineMetric?.value == 393)
        // A bold-number tile has no dated series, so there is no chart to draw.
        #expect(model.headlineRender == nil)
    }

    @Test("a headline id the board no longer holds falls back to the first metric")
    func headlineFallsBackToFirstMetric() async {
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: WatchFixtures.tempStore(),
            headline: "does-not-exist"
        )

        await model.refresh()

        #expect(model.headlineMetric?.id == "501")
    }

    @Test("an offline refresh keeps the snapshot it already had")
    func offlineRefreshPreservesPreviousSnapshot() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(capturedAt: WatchFixtures.now.addingTimeInterval(-7200))
        try store.write(seeded)
        let model = WatchFixtures.model(transport: OfflineTransport(), store: store)

        await model.refresh(force: true)

        // Stale numbers with an honest age beat a blank wrist.
        #expect(model.phase == .ready)
        #expect(store.loadOrNil() == seeded)
        #expect(model.snapshot == seeded)
        #expect(model.refreshGuidance == .iPhoneOffline)
        #expect(model.refreshGuidance?.message ==
            "Your iPhone may be offline. Connect it to the internet, then try again.")
    }

    @Test("an offline refresh with nothing to fall back on guides the user to the iPhone")
    func offlineRefreshWithNoSnapshotFails() async {
        let model = WatchFixtures.model(
            transport: OfflineTransport(), store: WatchFixtures.tempStore()
        )

        await model.refresh()

        let copy = "Your iPhone may be offline. Connect it to the internet, then try again."
        #expect(model.phase == .failed(copy))
        #expect(model.refreshGuidance == .iPhoneOffline)
        #expect(
            WatchCredentialEntryState(
                phase: model.phase,
                refreshGuidance: model.refreshGuidance
            ) == nil
        )
    }

    @Test("a non-offline request failure keeps generic copy without blaming the credential")
    func genericRequestFailureDoesNotBlameThePhone() async {
        let model = WatchFixtures.model(
            transport: UnavailableTransport(), store: WatchFixtures.tempStore()
        )

        await model.refresh()

        #expect(model.phase == .failed("PostHog couldn't be reached."))
        #expect(model.refreshGuidance == nil)
        #expect(model.refreshFailure == .retryable)
        #expect(model.canRetryRefresh)
        #expect(
            WatchCredentialEntryState(
                phase: model.phase,
                refreshGuidance: model.refreshGuidance,
                refreshFailure: model.refreshFailure
            ) == nil
        )
    }

    @Test("only a genuine authentication rejection offers credential replacement")
    func onlyAuthenticationFailureOffersCredentialReplacement() async {
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: [], unmatchedError: .unauthorized),
            store: WatchFixtures.tempStore()
        )

        await model.refresh()

        let message = "Your API key was rejected. Check the key and try again."
        #expect(model.phase == .failed(message))
        #expect(model.refreshFailure == .authentication)
        #expect(!model.canRetryRefresh)
        #expect(
            WatchCredentialEntryState(
                phase: model.phase,
                refreshFailure: model.refreshFailure,
                credentialRegion: model.credentialRegion
            ) == .replacement(message: message, region: .usCloud)
        )
    }

    @Test("authentication rejection stays actionable when stale metrics exist")
    func authenticationFailureWithSnapshotOffersReplacement() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(
            capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        try store.write(seeded)
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: [], unmatchedError: .unauthorized),
            store: store
        )

        await model.refresh(force: true)

        let message = "Your API key was rejected. Check the key and try again."
        #expect(model.snapshot == seeded)
        #expect(model.phase == .failed(message))
        #expect(model.refreshFailure == .authentication)
        #expect(
            WatchCredentialEntryState(
                phase: model.phase,
                refreshFailure: model.refreshFailure,
                credentialRegion: model.credentialRegion
            ) == .replacement(message: message, region: .usCloud)
        )
    }

    @Test("rate limits, server errors, and malformed responses never offer key replacement")
    func nonAuthenticationFailuresNeverOfferCredentialReplacement() async {
        let cases: [(PostHogError, WatchRefreshFailure)] = [
            (.rateLimited(retryAfter: 30), .retryable),
            (.http(status: 503, detail: nil), .retryable),
            (.decoding("Synthetic malformed payload"), .invalidResponse),
            (.forbidden(missingScope: "insight:read"), .other),
        ]

        for (error, expected) in cases {
            let model = WatchFixtures.model(
                transport: RouteTransport(routes: [], unmatchedError: error),
                store: WatchFixtures.tempStore()
            )

            await model.refresh()

            #expect(model.refreshFailure == expected)
            #expect(
                WatchCredentialEntryState(
                    phase: model.phase,
                    refreshFailure: model.refreshFailure
                ) == nil
            )
        }
    }

    @Test("a malformed decoded section is retained as invalid response recovery")
    func malformedSectionIsClassifiedWithoutReplacingTheKey() async {
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/query/",
                    bodyContains: "ErrorTrackingQuery",
                    body: "not-json"
                ),
            ],
            unmatchedError: .transport("Synthetic unavailable failure")
        )
        let model = WatchFixtures.model(
            transport: transport, store: WatchFixtures.tempStore()
        )

        await model.refresh()

        let message = "PostHog's response wasn't in a shape this app could read."
        #expect(model.phase == .failed(message))
        #expect(model.refreshFailure == .invalidResponse)
        #expect(model.canRetryRefresh)
        #expect(
            WatchCredentialEntryState(
                phase: model.phase, refreshFailure: model.refreshFailure
            ) == nil
        )
    }

    @Test("a partial refresh still surfaces the offline sections")
    func partialRefreshKeepsOfflineGuidance() async {
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/feature_flags/",
                    body: WatchFixtures.flags
                ),
            ],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let model = WatchFixtures.model(
            transport: transport, store: WatchFixtures.tempStore()
        )

        await model.refresh()

        // Flags answered, so this is a real partial snapshot rather than the
        // stale fallback branch. The sections that hit -1009 still need their
        // actionable recovery instead of disappearing behind `.ready`.
        #expect(model.phase == .ready)
        #expect(model.snapshot?.flags.count == 2)
        #expect(model.refreshGuidance == .iPhoneOffline)
    }

    @Test("a partial activity response cannot hide permission failures behind no metrics")
    func partialActivityPermissionFailureHasTruthfulPresentation() async {
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/query/",
                    bodyContains: "HogQLQuery",
                    body: WatchFixtures.events(1)
                ),
            ],
            unmatchedError: .forbidden(missingScope: "insight:read")
        )
        let model = WatchFixtures.model(
            transport: transport, store: WatchFixtures.tempStore()
        )

        await model.refresh()

        let message = "Your API key is missing the insight:read scope."
        #expect(model.phase == .ready)
        #expect(model.headlineMetric == nil)
        #expect(model.activity.count == 1)
        #expect(model.refreshFailure == .other)
        #expect(model.refreshFailureMessage == message)
        #expect(
            WatchMetricsContentState(
                phase: model.phase,
                hasHeadline: model.headlineMetric != nil,
                refreshGuidance: model.refreshGuidance,
                refreshFailure: model.refreshFailure,
                refreshFailureMessage: model.refreshFailureMessage,
                credentialRegion: model.credentialRegion
            ) == .failure(message)
        )
        #expect(
            WatchCredentialEntryState(
                phase: model.phase,
                refreshGuidance: model.refreshGuidance,
                refreshFailure: model.refreshFailure
            ) == nil
        )
    }

    @Test("partial success never hides an authentication rejection")
    func partialSuccessWithAuthenticationFailureOffersReplacement() async {
        let transport = RouteTransport(
            routes: [
                .init(pathContains: "/feature_flags/", body: WatchFixtures.flags),
            ],
            unmatchedError: .unauthorized
        )
        let model = WatchFixtures.model(
            transport: transport, store: WatchFixtures.tempStore()
        )

        await model.refresh()

        let message = "Your API key was rejected. Check the key and try again."
        #expect(model.snapshot?.flags.count == 2)
        #expect(model.snapshot?.projectRegion == .usCloud)
        #expect(model.phase == .failed(message))
        #expect(model.refreshFailure == .authentication)
        #expect(
            WatchCredentialEntryState(
                phase: model.phase,
                refreshFailure: model.refreshFailure,
                credentialRegion: model.credentialRegion
            ) == .replacement(message: message, region: .usCloud)
        )
    }

    @Test("a partial offline refresh merges fresh flags with carried metrics")
    func partialOfflineRefreshMergesTheCarriedSnapshot() async throws {
        let store = WatchFixtures.tempStore()
        let carriedAt = WatchFixtures.now.addingTimeInterval(-3600)
        let carriedFlag = SharedSnapshot.Flag(
            id: 77, key: "carried-flag", active: false, quickToggleAllowed: false
        )
        let seeded = WatchFixtures.snapshot(flags: [carriedFlag], capturedAt: carriedAt)
        try store.write(seeded)
        let transport = RouteTransport(
            routes: [.init(pathContains: "/feature_flags/", body: WatchFixtures.flags)],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let model = WatchFixtures.model(transport: transport, store: store)

        await model.refresh(force: true)

        let merged = try #require(model.snapshot)
        #expect(merged.metrics == seeded.metrics)
        #expect(merged.flags.count == 2)
        #expect(merged.flags != seeded.flags)
        // One timestamp cannot claim the carried metrics became fresh merely
        // because flags answered, so the conservative age is retained.
        #expect(merged.capturedAt == carriedAt)
        #expect(store.loadOrNil() == merged)
        #expect(model.refreshGuidance == .iPhoneOffline)
    }

    @Test("an unrelated partial response never replaces a carried snapshot with fresh empties")
    func unrelatedPartialResponseDoesNotStampAnEmptySnapshotFresh() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(
            flags: [
                SharedSnapshot.Flag(
                    id: 77, key: "carried-flag", active: true, quickToggleAllowed: false
                ),
            ],
            capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        try store.write(seeded)
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/query/",
                    bodyContains: "ErrorTrackingQuery",
                    body: WatchFixtures.errors
                ),
            ],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let model = WatchFixtures.model(transport: transport, store: store)

        await model.refresh(force: true)

        #expect(model.snapshot == seeded)
        #expect(store.loadOrNil() == seeded)
        #expect(model.refreshGuidance == .iPhoneOffline)
        #expect(model.phase == .ready)
    }

    @Test("automatic refresh waits fifteen minutes even after a retryable partial failure")
    func automaticRefreshHonorsToleranceAfterRetryableFailure() async {
        let clock = LockedWatchTestClock(WatchFixtures.now)
        let transport = FailFirstWatchRequestTransport(pathContains: "/feature_flags/")
        let model = WatchFixtures.model(
            transport: transport,
            store: WatchFixtures.tempStore(),
            now: { clock.now() }
        )

        await model.refresh(force: true)
        #expect(await transport.requestCount == 5)
        #expect(model.flagsRefreshFailure?.canRetry == true)

        clock.advance(by: WatchModel.refreshTolerance - 1)
        await model.refresh()
        #expect(await transport.requestCount == 5)

        clock.advance(by: 1)
        await model.refresh()
        #expect(await transport.requestCount == 10)
        #expect(model.flagsRefreshFailure == nil)
    }

    @Test("explicit retry forces exactly one five-request attempt inside the tolerance")
    func explicitRetryForcesOneAttempt() async {
        let clock = LockedWatchTestClock(WatchFixtures.now)
        let transport = FailFirstWatchRequestTransport(pathContains: "/feature_flags/")
        let model = WatchFixtures.model(
            transport: transport,
            store: WatchFixtures.tempStore(),
            now: { clock.now() }
        )

        await model.refresh(force: true)
        #expect(await transport.requestCount == 5)
        #expect(model.flagsRefreshFailure?.canRetry == true)

        await model.retry()

        #expect(await transport.requestCount == 10)
        #expect(model.flagsRefreshFailure == nil)
        #expect(model.shortlistFlags.count == 2)
    }

    @Test("explicit retry keeps failure and rows visible while one generation runs")
    func explicitRetryKeepsFailureAndRowsVisibleWhileOneGenerationRuns() async throws {
        let store = WatchFixtures.tempStore()
        let capturedAt = WatchFixtures.now.addingTimeInterval(-600)
        let carriedFlag = SharedSnapshot.Flag(
            id: 77, key: "carried-flag", active: true, quickToggleAllowed: false
        )
        try store.write(WatchFixtures.snapshot(
            flags: [carriedFlag], capturedAt: capturedAt
        ))
        try WatchFlagsReceipt(
            projectID: 1001,
            projectRegion: .usCloud,
            capturedAt: capturedAt
        ).write(to: store)

        let transport = HeldRetryWatchRequestTransport()
        let model = WatchFixtures.model(transport: transport, store: store)

        await model.refresh(force: true)

        let initialFailure = try #require(model.flagsRefreshFailure)
        #expect(await transport.requestCount == 5)
        #expect(model.flagsContentState == .carried(
            [carriedFlag],
            failure: initialFailure,
            capturedAt: capturedAt
        ))

        let first = Task { @MainActor in await model.retry() }
        let second = Task { @MainActor in await model.retry() }
        let retryIsHeld = await transport.waitUntilRetryIsHeld()
        #expect(retryIsHeld)
        guard retryIsHeld else {
            await transport.releaseRetry()
            await first.value
            await second.value
            return
        }

        #expect(model.flagsRefreshFailure == initialFailure)
        #expect(model.shortlistFlags == [carriedFlag])
        #expect(model.flagsContentState == .carried(
            [carriedFlag],
            failure: initialFailure,
            capturedAt: capturedAt
        ))

        await transport.releaseRetry()
        await first.value
        await second.value

        #expect(await transport.requestCount == 10)
        #expect(model.flagsRefreshFailure == nil)
        #expect(model.shortlistFlags.map(\.key) == ["example-a", "example-b"])
    }

    @Test("concurrent refresh calls coalesce within one configuration generation")
    func concurrentRefreshesCoalesceWithinOneGeneration() async {
        let transport = HeldFirstWatchRequestTransport()
        let model = WatchFixtures.model(
            transport: transport,
            store: WatchFixtures.tempStore()
        )

        let first = Task { @MainActor in await model.refresh(force: true) }
        await transport.waitUntilFirstRequestIsHeld()
        let second = Task { @MainActor in await model.refresh(force: true) }
        // Give the second main-actor task a bounded opportunity to enter the
        // refresh wrapper while the first network request is still suspended.
        for _ in 0..<50 { await Task.yield() }

        await transport.releaseFirstRequest()
        await first.value
        await second.value

        #expect(await transport.requestCount == 5)
        #expect(model.phase == .ready)
    }

    @Test("flags presentation separates unasked, loading, answered, and failed states")
    func flagsContentStateSeparatesUnaskedLoadingAnsweredEmptyAndFailure() async throws {
        let noCredential = WatchModel(
            credential: nil,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: OfflineTransport(),
            store: WatchFixtures.tempStore(),
            authenticate: { _ in true },
            now: { WatchFixtures.now }
        )
        #expect(noCredential.flagsContentState == .needsCredential)

        let loading = WatchFixtures.model(
            transport: OfflineTransport(), store: WatchFixtures.tempStore()
        )
        #expect(loading.flagsContentState == .loading)

        let legacyEmptyStore = WatchFixtures.tempStore()
        try legacyEmptyStore.write(WatchFixtures.snapshot())
        let legacyEmpty = WatchFixtures.model(
            transport: OfflineTransport(), store: legacyEmptyStore
        )
        #expect(legacyEmpty.flagsContentState == .notChecked)

        let empty = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                flags: #"{"count":0,"next":null,"previous":null,"results":[]}"#
            )),
            store: WatchFixtures.tempStore()
        )
        await empty.refresh(force: true)
        #expect(empty.flagsContentState == .empty(capturedAt: WatchFixtures.now))

        let carriedAt = WatchFixtures.now.addingTimeInterval(-600)
        let carriedFlag = SharedSnapshot.Flag(
            id: 77, key: "carried-flag", active: true, quickToggleAllowed: false
        )
        let rowsStore = WatchFixtures.tempStore()
        try rowsStore.write(WatchFixtures.snapshot(
            flags: [carriedFlag], capturedAt: carriedAt
        ))
        let rows = WatchFixtures.model(
            transport: OfflineTransport(), store: rowsStore
        )
        #expect(rows.flagsContentState == .rows([carriedFlag], capturedAt: carriedAt))

        let retryableFailure = WatchSectionFailure(
            message: "PostHog couldn't be reached.", canRetry: true
        )
        let failure = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(extra: [
                .init(
                    pathContains: "/feature_flags/",
                    body: #"{"detail":"Synthetic flags failure."}"#,
                    status: 503
                ),
            ])),
            store: WatchFixtures.tempStore()
        )
        await failure.refresh(force: true)
        #expect(failure.flagsContentState == .failure(retryableFailure))

        let carriedStore = WatchFixtures.tempStore()
        try carriedStore.write(WatchFixtures.snapshot(
            flags: [carriedFlag], capturedAt: carriedAt
        ))
        let carried = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(extra: [
                .init(
                    pathContains: "/feature_flags/",
                    body: #"{"detail":"Synthetic flags failure."}"#,
                    status: 503
                ),
            ])),
            store: carriedStore
        )
        await carried.refresh(force: true)
        #expect(
            carried.flagsContentState == .carried(
                [carriedFlag],
                failure: retryableFailure,
                capturedAt: carriedAt
            )
        )
    }

    @Test("flags receipt survives relaunch only for matching project scope")
    func flagsReceiptSurvivesRelaunchOnlyForMatchingProjectScope() async {
        let emptyFlags = #"{"count":0,"next":null,"previous":null,"results":[]}"#

        let matchingStore = WatchFixtures.tempStore()
        let first = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                flags: emptyFlags
            )),
            store: matchingStore
        )
        await first.refresh(force: true)
        #expect(first.flagsContentState == .empty(capturedAt: WatchFixtures.now))

        let relaunched = WatchFixtures.model(
            transport: OfflineTransport(), store: matchingStore
        )
        #expect(relaunched.flagsContentState == .empty(capturedAt: WatchFixtures.now))

        let projectStore = WatchFixtures.tempStore()
        let projectSeed = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                flags: emptyFlags
            )),
            store: projectStore
        )
        await projectSeed.refresh(force: true)
        let differentProject = WatchModel(
            credential: StoredCredential(
                key: "test-key-0002", region: .usCloud, projectID: 1002
            ),
            projectName: "Different synthetic project",
            headlineMetricID: nil,
            watches: [],
            transport: OfflineTransport(),
            store: projectStore,
            authenticate: { _ in true },
            now: { WatchFixtures.now }
        )
        #expect(differentProject.flagsContentState == .loading)

        let regionStore = WatchFixtures.tempStore()
        let regionSeed = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                flags: emptyFlags
            )),
            store: regionStore
        )
        await regionSeed.refresh(force: true)
        let differentRegion = WatchModel(
            credential: StoredCredential(
                key: "test-key-0003", region: .euCloud, projectID: 1001
            ),
            projectName: "Different synthetic region",
            headlineMetricID: nil,
            watches: [],
            transport: OfflineTransport(),
            store: regionStore,
            authenticate: { _ in true },
            now: { WatchFixtures.now }
        )
        #expect(differentRegion.flagsContentState == .loading)
    }

    @Test("flags, health, and activity failures differ from successful empty responses")
    func partialSectionFailuresAreDistinctFromSuccessfulEmptyResponses() async {
        let empty = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                flags: #"{"count":0,"next":null,"previous":null,"results":[]}"#,
                errors: #"{"results":[]}"#,
                events: WatchFixtures.events(0)
            )),
            store: WatchFixtures.tempStore()
        )
        await empty.refresh(force: true)
        #expect(empty.shortlistFlags.isEmpty)
        #expect(empty.flagsRefreshFailure == nil)
        #expect(empty.flagsContentState == .empty(capturedAt: WatchFixtures.now))
        #expect(empty.health.errorPulse?.activeCount == 0)
        #expect(empty.healthRefreshFailure == nil)
        #expect(empty.activity.isEmpty)
        #expect(empty.activityCapturedAt != nil)
        #expect(empty.activityRefreshFailure == nil)

        let flags = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(extra: [
                .init(
                    pathContains: "/feature_flags/",
                    body: #"{"detail":"Synthetic flags failure."}"#,
                    status: 503
                ),
            ])),
            store: WatchFixtures.tempStore()
        )
        await flags.refresh(force: true)
        #expect(flags.phase == .ready)
        #expect(flags.shortlistFlags.isEmpty)
        #expect(flags.flagsRefreshFailure?.canRetry == true)
        #expect(flags.flagsContentState == .failure(WatchSectionFailure(
            message: "PostHog couldn't be reached.", canRetry: true
        )))

        let carriedStore = WatchFixtures.tempStore()
        let carriedAt = WatchFixtures.now.addingTimeInterval(-300)
        let carriedFlag = SharedSnapshot.Flag(
            id: 77, key: "carried-flag", active: false, quickToggleAllowed: false
        )
        try? carriedStore.write(WatchFixtures.snapshot(
            flags: [carriedFlag], capturedAt: carriedAt
        ))
        let carriedFlags = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(extra: [
                .init(
                    pathContains: "/feature_flags/",
                    body: #"{"detail":"Synthetic flags failure."}"#,
                    status: 503
                ),
            ])),
            store: carriedStore
        )
        await carriedFlags.refresh(force: true)
        #expect(carriedFlags.flagsContentState == .carried(
            [carriedFlag],
            failure: WatchSectionFailure(
                message: "PostHog couldn't be reached.", canRetry: true
            ),
            capturedAt: carriedAt
        ))

        let health = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(extra: [
                .init(
                    pathContains: "/query/",
                    bodyContains: "ErrorTrackingQuery",
                    body: #"{"detail":"Synthetic health failure."}"#,
                    status: 503
                ),
            ])),
            store: WatchFixtures.tempStore()
        )
        await health.refresh(force: true)
        #expect(health.phase == .ready)
        #expect(health.health.errorPulse == nil)
        #expect(health.healthRefreshFailure?.canRetry == true)

        let activity = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(extra: [
                .init(
                    pathContains: "/query/",
                    bodyContains: "HogQLQuery",
                    body: #"{"detail":"Synthetic activity failure."}"#,
                    status: 503
                ),
            ])),
            store: WatchFixtures.tempStore()
        )
        await activity.refresh(force: true)
        #expect(activity.phase == .ready)
        #expect(activity.activity.isEmpty)
        #expect(activity.activityCapturedAt == nil)
        #expect(activity.activityRefreshFailure?.canRetry == true)
    }

    @Test("a refresh spends exactly five requests, each within its budget")
    func refreshSpendsExactlyFiveRequests() async throws {
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchFixtures.model(transport: transport, store: WatchFixtures.tempStore())

        await model.refresh()

        let budget = QueryBudget.wrist
        let paths = await transport.requestedPaths()
        let bodies = await transport.requestBodies()
        #expect(paths.count == 5)
        // Every size and every range is the wrist budget's, not a literal
        // beside it: these assertions are written against `QueryBudget.wrist`
        // on purpose, so a page size that drifts away from the kit's value
        // fails here rather than quietly costing five times the rows.
        #expect(paths.contains {
            $0.contains("/dashboards/?") && $0.contains("limit=\(budget.pageSize)")
        })
        #expect(paths.contains {
            $0.contains("/dashboards/9001/") && $0.contains("refresh=force_cache")
        })
        #expect(paths.contains {
            $0.contains("/feature_flags/?") && $0.contains("limit=\(budget.pageSize)")
        })

        let pulse = try #require(bodies.first { $0.contains("ErrorTrackingQuery") })
        #expect(pulse.contains(budget.dateFrom))
        #expect(pulse.contains("occurrences"))

        let feed = try #require(bodies.first { $0.contains("HogQLQuery") })
        #expect(feed.contains("LIMIT \(budget.pageSize)"))
        // The whole point of the trimmed feed: no per-row JSON extraction.
        #expect(!feed.contains("properties"))
        // The flags page fetches exactly what the shortlist draws.
        #expect(WatchModel.flagShortlistCap == budget.pageSize)
        #expect(WatchActivity.maxLines == budget.pageSize)
    }

    @Test("the budgeted requests are the kit's own, not a second spelling")
    func budgetedEndpointsMatchTheKit() {
        let budget = WatchModel.budget
        #expect(budget == QueryBudget.wrist)
        #expect(
            PostHogAPI.dashboards(projectID: 1001, budget: budget).query
                == PostHogAPI.dashboards(projectID: 1001, limit: budget.pageSize).query
        )
        #expect(
            PostHogAPI.featureFlags(projectID: 1001, budget: budget).query
                == PostHogAPI.featureFlags(projectID: 1001, limit: budget.pageSize).query
        )
        // One day, spelled once: the pulse's string range and the feed's Date
        // floor both come off the same budget.
        #expect(budget.dateFrom == "-\(budget.hours)h")
        #expect(
            budget.since(now: WatchFixtures.now)
                == WatchFixtures.now.addingTimeInterval(-Double(budget.hours) * 3600)
        )
    }

    @Test("flags drop tombstones and never claim a quick toggle")
    func flagsFilterTombstonesAndNeverAllowQuickToggle() async {
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: WatchFixtures.tempStore()
        )

        await model.refresh()

        #expect(model.snapshot?.flags.count == 2)
        #expect(model.snapshot?.flags.allSatisfy { !$0.quickToggleAllowed } == true)
        #expect(model.snapshot?.quickToggleFlags.isEmpty == true)
    }

    @Test("a successful flag write rewrites the model and the stored snapshot")
    func setFlagRewritesSnapshotOnSuccess() async throws {
        let store = WatchFixtures.tempStore()
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
            extra: [
                .init(
                    pathContains: "/feature_flags/2/",
                    body: #"{"id":2,"key":"example-b","active":true}"#
                ),
            ]
        ))
        let model = WatchFixtures.model(transport: transport, store: store)
        await model.refresh()

        let failure = await model.setFlag(id: 2, active: true)

        #expect(failure == nil)
        #expect(model.snapshot?.flag(id: 2)?.active == true)
        #expect(store.loadOrNil()?.flag(id: 2)?.active == true)
        // The untouched flag is untouched.
        #expect(store.loadOrNil()?.flag(id: 1)?.active == true)
    }

    @Test("flag write names the catalog fallback when a 403 omits its scope")
    func setFlagUsesFeatureFlagScopeFallback() async {
        #expect(
            WatchModel.requiredFlagWriteScope
                == APIKeyScopeGuidance.optionalWriteDescriptor(for: .featureFlags).scope
        )
        let model = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes(
                extra: [
                    .init(
                        pathContains: "/feature_flags/2/",
                        body: #"{"detail":"Synthetic permission refusal"}"#,
                        status: 403
                    ),
                ]
            )),
            store: WatchFixtures.tempStore()
        )
        await model.refresh()

        let failure = await model.setFlag(id: 2, active: true)

        #expect(failure?.contains("feature_flag:write") == true)
    }

    @Test("a fresh snapshot throttles the refresh away, and still has a trend to draw")
    func freshSnapshotThrottlesRefresh() async throws {
        let store = WatchFixtures.tempStore()
        try store.write(
            WatchFixtures.snapshot(capturedAt: WatchFixtures.now.addingTimeInterval(-300))
        )
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchFixtures.model(transport: transport, store: store)

        await model.refresh()

        #expect(await transport.requests.isEmpty)
        #expect(model.phase == .ready)
        // The throttled relaunch is the *common* glance-again path, so what it
        // can draw is what the Metrics page usually looks like. There is no
        // in-memory render — nothing was fetched — and the trend therefore has
        // to come off the persisted snapshot.
        #expect(model.headlineRender == nil)
        let sparkline = try #require(model.headlineMetric?.sparkline)
        #expect(sparkline.count > 1)
        #expect(WatchSparklineMath.fractions(sparkline).count == sparkline.count)
    }

    @Test("a throttled relaunch carries the feed forward instead of claiming no events")
    func throttledRelaunchCarriesTheFeed() async {
        let store = WatchFixtures.tempStore()
        let first = WatchFixtures.model(
            transport: RouteTransport(routes: WatchFixtures.fullRefreshRoutes()),
            store: store
        )
        await first.refresh()
        #expect(first.activity.count == 3)
        #expect(first.activityCapturedAt == WatchFixtures.now)

        // A second launch inside the throttle window spends no requests. The
        // Activity page must still show what the first launch read.
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let second = WatchFixtures.model(transport: transport, store: store)
        await second.refresh()

        #expect(await transport.requests.isEmpty)
        #expect(second.activity.count == 3)
        #expect(second.activityCapturedAt == WatchFixtures.now)
    }

    @Test("an events query that failed leaves the feed and its age alone")
    func failedEventsQueryKeepsTheCarriedFeed() async throws {
        let store = WatchFixtures.tempStore()
        // Activity has no project id of its own, so it is trusted only beside
        // the matching project snapshot that gives the file its scope.
        try store.write(
            WatchFixtures.snapshot(capturedAt: WatchFixtures.now.addingTimeInterval(-3600))
        )
        let seeded = ActivityFeed(
            lines: [ActivityLine(id: "example-row-0001", event: "carried_event", timestamp: nil)],
            capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        try WatchActivity.write(seeded, to: store)
        // Every route but the events query answers.
        let routes = WatchFixtures.fullRefreshRoutes().filter { $0.bodyContains != "HogQLQuery" }
        let model = WatchFixtures.model(transport: RouteTransport(routes: routes), store: store)

        await model.refresh(force: true)

        #expect(model.snapshot?.capturedAt == WatchFixtures.now)
        #expect(model.activity == seeded.lines)
        #expect(model.activityCapturedAt == seeded.capturedAt)
        #expect(WatchActivity.read(from: store) == seeded)
    }

    /// The promise the empty state makes: "Open GetHog on your iPhone to hand
    /// this watch its key." Before `adopt`, doing exactly that changed nothing
    /// until the app was force-quit and relaunched — the credential reached the
    /// keychain and the running model went on saying the same sentence.
    @Test("a hand-off that lands while the app is running resolves the empty state")
    func adoptingAHandoffResolvesNeedsKey() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let store = WatchFixtures.tempStore()
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: nil,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            now: { WatchFixtures.now }
        )
        await model.refresh()
        #expect(model.phase == .needsKey)
        #expect(await transport.requests.isEmpty)

        // The phone's transfer lands: keychain, watch list, defaults.
        let credentials = InMemoryTokenStore()
        let defaults = try #require(UserDefaults(suiteName: "GetHogWatchTests-\(UUID().uuidString)"))
        WatchSessionListener.apply(
            WatchKeyTransfer(
                key: "test-key-0001", region: .usCloud, projectID: 1001,
                projectName: "Synthetic Analytics", headlineMetricID: "502",
                watches: [
                    MetricWatch(
                        id: "example-watch-1", metricID: "502",
                        title: "Example total", condition: .above(40)
                    ),
                ]
            ),
            credentials: credentials, snapshots: store, defaults: defaults,
            mutationCoordinator: mutationCoordinator, notify: {}
        )

        await model.adopt(
            WatchHandoff.current(
                credentials: credentials, defaults: defaults, snapshots: store,
                mutationCoordinator: mutationCoordinator
            )
        )

        #expect(model.phase == .ready)
        #expect(model.headlineMetricID == "502")
        #expect(model.headlineMetric?.value == 393)
        #expect(model.snapshot?.projectName == "Synthetic Analytics")
        // Forced, so the hand-off is not swallowed by a snapshot that happens
        // to be fresh — this is a different project's numbers.
        #expect(await transport.requests.count == 5)
        // The new thresholds were evaluated, not the ones the model was born
        // with: 393 is above 40.
        #expect(model.health.rows.count == 1)
        #expect(model.health.firingCount == 1)
    }

    @Test("a refresh started before hand-off cannot overwrite the adopted project")
    func preHandoffRefreshCannotOverwriteAdoptedProject() async {
        let transport = HandoffRaceTransport()
        let store = WatchFixtures.tempStore()
        let model = WatchFixtures.model(transport: transport, store: store)

        let staleRefresh = Task { @MainActor in
            await model.refresh(force: true)
        }
        await transport.waitUntilOldRequestIsHeld()

        let adoptedRefresh = Task { @MainActor in
            await model.adopt(
                WatchHandoff(
                    credential: StoredCredential(
                        key: "test-key-adopted-0002", region: .usCloud, projectID: 42
                    ),
                    projectName: "Adopted Synthetic Project",
                    headlineMetricID: "502",
                    watches: [],
                    watchesDegraded: false
                )
            )
        }
        await adoptedRefresh.value

        // Deliver the old project's response last. It is no longer allowed to
        // mutate model state or the widget file.
        await transport.releaseOldRequest()
        await staleRefresh.value

        #expect(model.snapshot?.projectID == 42)
        #expect(model.snapshot?.projectName == "Adopted Synthetic Project")
        #expect(store.loadOrNil()?.projectID == 42)
        #expect(model.phase == .ready)
    }

    @Test("offline adoption clears the previous project from UI and widget storage")
    func offlineAdoptionClearsThePreviousProject() async throws {
        let store = WatchFixtures.tempStore()
        let oldFlag = SharedSnapshot.Flag(
            id: 77, key: "project-a-flag", active: true, quickToggleAllowed: false
        )
        let projectA = WatchFixtures.snapshot(
            flags: [oldFlag], capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        try store.write(projectA)
        try WatchActivity.write(
            ActivityFeed(
                lines: [
                    ActivityLine(
                        id: "project-a-event", event: "project_a_event", timestamp: nil
                    ),
                ],
                capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
            ),
            to: store
        )
        try store.writeBreachingWatchIDs(["project-a-watch"])
        var reloadCount = 0
        var everyReloadFollowedClearing = true
        let model = WatchFixtures.model(
            transport: OfflineTransport(),
            store: store,
            snapshotDidChange: {
                reloadCount += 1
                everyReloadFollowedClearing = everyReloadFollowedClearing
                    && store.loadOrNil() == nil
                    && WatchActivity.read(from: store) == nil
                    && store.breachingWatchIDs().isEmpty
            }
        )
        #expect(model.headlineMetric != nil)
        #expect(!model.activity.isEmpty)

        await model.adopt(
            WatchHandoff(
                credential: StoredCredential(
                    key: "test-key-project-b", region: .usCloud, projectID: 42
                ),
                projectName: "Synthetic Project B",
                headlineMetricID: nil,
                watches: [],
                watchesDegraded: false
            )
        )

        #expect(model.snapshot == nil)
        #expect(model.headlineMetric == nil)
        #expect(model.shortlistFlags.isEmpty)
        #expect(model.activity.isEmpty)
        #expect(model.activityCapturedAt == nil)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(model.refreshGuidance == .iPhoneOffline)
        #expect(reloadCount == 1)
        #expect(everyReloadFollowedClearing)
    }

    @Test("same numeric project in another region clears data and cannot write the old flag")
    func sameProjectIDDifferentRegionClearsAndRefusesOldFlag() async throws {
        let store = WatchFixtures.tempStore()
        try store.write(
            WatchFixtures.snapshot(
                flags: [
                    SharedSnapshot.Flag(
                        id: 77, key: "us-project-flag", active: true,
                        quickToggleAllowed: false
                    ),
                ],
                projectRegion: .usCloud
            )
        )
        let transport = RouteTransport(
            routes: [],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let model = WatchFixtures.model(transport: transport, store: store)

        await model.adopt(
            WatchHandoff(
                credential: StoredCredential(
                    key: "eu-test-key", region: .euCloud, projectID: 1001
                ),
                projectName: "Synthetic EU Project",
                headlineMetricID: nil,
                watches: [],
                watchesDegraded: false
            )
        )
        let requestsAfterAdoption = await transport.requests.count
        let failure = await model.setFlag(id: 77, active: false)

        #expect(model.snapshot == nil)
        #expect(store.loadOrNil() == nil)
        #expect(failure == "Refresh this project before changing a flag.")
        #expect(await transport.requests.count == requestsAfterAdoption)
        #expect(await transport.requests.allSatisfy { $0.url?.host == "eu.posthog.com" })
    }

    @Test("relaunch rejects same-id snapshot and activity from another region")
    func relaunchRejectsMismatchedStoredProvenance() async throws {
        let store = WatchFixtures.tempStore()
        try store.write(
            WatchFixtures.snapshot(
                flags: [
                    SharedSnapshot.Flag(
                        id: 77, key: "project-a-flag", active: true,
                        quickToggleAllowed: false
                    ),
                ],
                projectRegion: .usCloud
            )
        )
        try WatchActivity.write(
            ActivityFeed(
                lines: [
                    ActivityLine(
                        id: "project-a-event", event: "project_a_event", timestamp: nil
                    ),
                ],
                capturedAt: WatchFixtures.now
            ),
            to: store
        )
        try store.writeBreachingWatchIDs(["project-a-watch"])
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        var reloadCount = 0
        var reloadedAfterClearing = false
        let model = WatchModel(
            credential: StoredCredential(
                key: "test-key-project-b", region: .euCloud, projectID: 1001
            ),
            projectName: "Synthetic Project B",
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            authenticate: { _ in true },
            snapshotDidChange: {
                reloadCount += 1
                reloadedAfterClearing = store.loadOrNil() == nil
                    && WatchActivity.read(from: store) == nil
                    && store.breachingWatchIDs().isEmpty
            },
            now: { WatchFixtures.now }
        )

        #expect(model.snapshot == nil)
        #expect(model.headlineMetric == nil)
        #expect(model.shortlistFlags.isEmpty)
        #expect(model.activity.isEmpty)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadCount == 1)
        #expect(reloadedAfterClearing)

        let failure = await model.setFlag(id: 77, active: false)
        #expect(failure == "Refresh this project before changing a flag.")
        #expect(await transport.requests.isEmpty)
    }

    @Test("verified manual credential restores matching stale data on an offline restart")
    func verifiedManualCredentialRestoresMatchingDataOnOfflineRestart() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(
            flags: [
                SharedSnapshot.Flag(
                    id: 77, key: "matching-project-flag", active: true,
                    quickToggleAllowed: false
                ),
            ],
            capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        let feed = ActivityFeed(
            lines: [
                ActivityLine(
                    id: "matching-project-event",
                    event: "matching_project_event",
                    timestamp: nil
                ),
            ],
            capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        try store.write(seeded)
        try WatchActivity.write(feed, to: store)
        try store.writeBreachingWatchIDs(["matching-project-watch"])
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/users/@me/",
                    body: WatchFixtures.me(projectID: 1001)
                ),
            ],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let credentials = InMemoryTokenStore(
            credential: StoredCredential(
                key: "manual-test-key", region: .usCloud, projectID: nil
            )
        )
        var reloadSnapshots: [SharedSnapshot?] = []
        var reloadActivities: [ActivityFeed?] = []
        var reloadBreaches: [Set<String>] = []
        let model = WatchModel(
            credential: try credentials.load(),
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            authenticate: { _ in true },
            snapshotDidChange: {
                reloadSnapshots.append(store.loadOrNil())
                reloadActivities.append(WatchActivity.read(from: store))
                reloadBreaches.append(store.breachingWatchIDs())
            },
            now: { WatchFixtures.now }
        )

        // The unverified credential may belong to another project. The files
        // survive only in the model's private quarantine. Their active App
        // Group URLs must be empty too, or a widget could still render a
        // different project's metric before `/me` proves the full identity.
        #expect(model.snapshot == nil)
        #expect(model.shortlistFlags.isEmpty)
        #expect(model.activity.isEmpty)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadSnapshots.count == 1)
        #expect(reloadSnapshots[0] == nil)
        #expect(reloadActivities[0] == nil)
        #expect(reloadBreaches[0].isEmpty)

        await model.refresh()

        #expect(model.snapshot == seeded)
        #expect(model.shortlistFlags.map(\.id) == [77])
        #expect(model.activity == feed.lines)
        #expect(model.activityCapturedAt == feed.capturedAt)
        #expect(model.phase == .ready)
        #expect(model.refreshGuidance == .iPhoneOffline)
        #expect(store.loadOrNil() == seeded)
        #expect(WatchActivity.read(from: store) == feed)
        #expect(store.breachingWatchIDs() == ["matching-project-watch"])
        #expect(reloadSnapshots.count == 2)
        #expect(reloadSnapshots[1] == seeded)
        #expect(reloadActivities[1] == feed)
        #expect(reloadBreaches[1] == ["matching-project-watch"])

        let persisted = try #require(try credentials.load())
        #expect(persisted.projectID == 1001)
        #expect(persisted.key == "manual-test-key")
        #expect(persisted.region == .usCloud)

        // A subsequent launch no longer has to resolve identity before it can
        // trust this same-scope fallback. Even fully offline, it renders the
        // stale snapshot immediately and retains it through the failed refresh.
        let restarted = WatchModel(
            credential: persisted,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: OfflineTransport(),
            store: store,
            credentialStore: credentials,
            authenticate: { _ in true },
            snapshotDidChange: {},
            now: { WatchFixtures.now }
        )
        #expect(restarted.snapshot == seeded)
        #expect(restarted.activity == feed.lines)
        #expect(restarted.phase == .ready)

        await restarted.refresh(force: true)

        #expect(restarted.snapshot == seeded)
        #expect(restarted.activity == feed.lines)
        #expect(restarted.phase == .ready)
        #expect(restarted.refreshGuidance == .iPhoneOffline)
    }

    @Test("manual credential clears mismatching quarantine after identity resolves")
    func manualCredentialClearsMismatchingQuarantineAfterMe() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot()
        try store.write(seeded)
        try WatchActivity.write(
            ActivityFeed(
                lines: [
                    ActivityLine(
                        id: "old-project-event", event: "old_project_event", timestamp: nil
                    ),
                ],
                capturedAt: WatchFixtures.now
            ),
            to: store
        )
        try store.writeBreachingWatchIDs(["old-project-watch"])
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/users/@me/",
                    body: WatchFixtures.me(projectID: 42, name: "Synthetic Project B")
                ),
            ],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let credentials = InMemoryTokenStore(
            credential: StoredCredential(
                key: "manual-test-key", region: .usCloud, projectID: nil
            )
        )
        var reloadCount = 0
        var reloadFollowedClearing = false
        let model = WatchModel(
            credential: try credentials.load(),
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            authenticate: { _ in true },
            snapshotDidChange: {
                reloadCount += 1
                reloadFollowedClearing = store.loadOrNil() == nil
                    && WatchActivity.read(from: store) == nil
                    && store.breachingWatchIDs().isEmpty
            },
            now: { WatchFixtures.now }
        )

        #expect(model.snapshot == nil)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadCount == 1)
        #expect(reloadFollowedClearing)

        await model.refresh()

        #expect(model.snapshot == nil)
        #expect(model.activity.isEmpty)
        #expect(model.phase == .failed(
            "Your iPhone may be offline. Connect it to the internet, then try again."
        ))
        #expect(model.refreshGuidance == .iPhoneOffline)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadCount == 1)
        #expect(reloadFollowedClearing)
        let persisted = try #require(try credentials.load())
        #expect(persisted.projectID == 42)
    }

    @Test("offline identity lookup preserves manual credential quarantine without rendering it")
    func offlineMePreservesInvisibleManualCredentialQuarantine() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(
            flags: [
                SharedSnapshot.Flag(
                    id: 77, key: "unverified-project-flag", active: true,
                    quickToggleAllowed: false
                ),
            ]
        )
        try store.write(seeded)
        try WatchActivity.write(
            ActivityFeed(
                lines: [
                    ActivityLine(
                        id: "unverified-event", event: "unverified_event", timestamp: nil
                    ),
                ],
                capturedAt: WatchFixtures.now
            ),
            to: store
        )
        try store.writeBreachingWatchIDs(["unverified-watch"])
        let transport = RouteTransport(
            routes: [],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let credentials = InMemoryTokenStore(
            credential: StoredCredential(
                key: "manual-test-key", region: .usCloud, projectID: nil
            )
        )
        var reloadCount = 0
        var everyReloadSawEmptyActiveFiles = true
        let model = WatchModel(
            credential: try credentials.load(),
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            authenticate: { _ in true },
            snapshotDidChange: {
                reloadCount += 1
                everyReloadSawEmptyActiveFiles = everyReloadSawEmptyActiveFiles
                    && store.loadOrNil() == nil
                    && WatchActivity.read(from: store) == nil
                    && store.breachingWatchIDs().isEmpty
            },
            now: { WatchFixtures.now }
        )

        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadCount == 1)
        #expect(everyReloadSawEmptyActiveFiles)

        await model.refresh()
        let requestCount = await transport.requests.count
        let flagFailure = await model.setFlag(id: 77, active: false)

        #expect(model.snapshot == nil)
        #expect(model.shortlistFlags.isEmpty)
        #expect(model.activity.isEmpty)
        #expect(model.phase == .failed(
            "Your iPhone may be offline. Connect it to the internet, then try again."
        ))
        #expect(model.refreshGuidance == .iPhoneOffline)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(flagFailure == "Not signed in.")
        #expect(await transport.requests.count == requestCount)
        #expect(reloadCount == 1)
        #expect(everyReloadSawEmptyActiveFiles)
        let unresolved = try #require(try credentials.load())
        #expect(unresolved.projectID == nil)
    }

    @Test("identity resolution never persists a DEBUG-only credential")
    func resolvedDebugCredentialRemainsInMemoryOnly() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot()
        try store.write(seeded)
        let emptyKeychain = InMemoryTokenStore()
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/users/@me/",
                    body: WatchFixtures.me(projectID: 1001)
                ),
            ],
            unmatchedError: .network(
                code: NSURLErrorNotConnectedToInternet,
                description: "Synthetic offline failure"
            )
        )
        let model = WatchModel(
            // Mirrors WatchHandoff.current's DEBUG environment fallback: the
            // running model has a key, but the keychain does not.
            credential: StoredCredential(
                key: "debug-environment-key", region: .usCloud, projectID: nil
            ),
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: emptyKeychain,
            credentialSource: .processOnly,
            authenticate: { _ in true },
            snapshotDidChange: {},
            now: { WatchFixtures.now }
        )

        await model.refresh()

        #expect(model.snapshot == seeded)
        #expect(model.phase == .ready)
        #expect(model.refreshGuidance == .iPhoneOffline)
        let storedCredential = try emptyKeychain.load()
        #expect(storedCredential == nil)
    }

    @Test("a stored credential missing before identity resolves cannot restore quarantine")
    func missingStoredCredentialCannotRestoreQuarantine() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot()
        let seededActivity = ActivityFeed(
            lines: [
                ActivityLine(
                    id: "missing-key-event", event: "missing_key_event", timestamp: nil
                ),
            ],
            capturedAt: WatchFixtures.now
        )
        try store.write(seeded)
        try WatchActivity.write(seededActivity, to: store)
        try store.writeBreachingWatchIDs(["missing-key-watch"])
        let unresolved = StoredCredential(
            key: "removed-manual-key", region: .usCloud, projectID: nil
        )
        let credentials = InMemoryTokenStore(credential: unresolved)
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/users/@me/",
                    body: WatchFixtures.me(projectID: 1001)
                ),
            ]
        )
        var reloadSnapshots: [SharedSnapshot?] = []
        var reloadActivities: [ActivityFeed?] = []
        var reloadBreaches: [Set<String>] = []
        let model = WatchModel(
            credential: unresolved,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: {
                reloadSnapshots.append(store.loadOrNil())
                reloadActivities.append(WatchActivity.read(from: store))
                reloadBreaches.append(store.breachingWatchIDs())
            },
            now: { WatchFixtures.now }
        )

        // Simulates a real Keychain record disappearing after launch but
        // before `/me` answers. That is not the explicit DEBUG process-only
        // path and must never inherit its permission to restore old files.
        try credentials.clear()
        await model.refresh()

        #expect(model.snapshot == nil)
        #expect(model.activity.isEmpty)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadSnapshots == [nil])
        #expect(reloadActivities == [nil])
        #expect(reloadBreaches == [[]])
        #expect(try credentials.load() == nil)
        #expect(await transport.requests.count == 1)
        #expect(model.phase == .needsKey)
        #expect(!model.hasCredential)
    }

    @Test("a stored credential read failure cannot restore quarantine")
    func throwingStoredCredentialCannotRestoreQuarantine() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let store = WatchFixtures.tempStore()
        try store.write(WatchFixtures.snapshot())
        let unresolved = StoredCredential(
            key: "unreadable-manual-key", region: .usCloud, projectID: nil
        )
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/users/@me/",
                    body: WatchFixtures.me(projectID: 1001)
                ),
            ]
        )
        var reloads: [SharedSnapshot?] = []
        let model = WatchModel(
            credential: unresolved,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: ThrowingCredentialLoadStore(),
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: { reloads.append(store.loadOrNil()) },
            now: { WatchFixtures.now }
        )

        await model.refresh()

        #expect(model.snapshot == nil)
        #expect(store.loadOrNil() == nil)
        #expect(reloads == [nil])
        #expect(await transport.requests.count == 1)
        #expect(model.phase == .failed(
            "The Watch couldn't read its saved API key. Try again."
        ))
        #expect(model.refreshFailure == .retryable)
        #expect(model.canRetryRefresh)
    }

    @Test("a replaced stored credential cannot restore the old credential's quarantine")
    func replacedStoredCredentialCannotRestoreOldQuarantine() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let store = WatchFixtures.tempStore()
        try store.write(WatchFixtures.snapshot())
        let unresolved = StoredCredential(
            key: "old-manual-key", region: .usCloud, projectID: nil
        )
        let replacement = StoredCredential(
            key: "replacement-key", region: .euCloud, projectID: 42
        )
        let credentials = InMemoryTokenStore(credential: unresolved)
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/users/@me/",
                    body: WatchFixtures.me(projectID: 1001)
                ),
            ]
        )
        var reloads: [SharedSnapshot?] = []
        let model = WatchModel(
            credential: unresolved,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: { reloads.append(store.loadOrNil()) },
            now: { WatchFixtures.now }
        )
        try credentials.save(replacement)

        await model.refresh()

        #expect(model.snapshot == nil)
        #expect(store.loadOrNil() == nil)
        #expect(reloads == [nil])
        #expect(try credentials.load() == replacement)
        #expect(await transport.requests.count == 1)
        #expect(model.phase == .failed(
            "The saved API key changed before project verification finished. Try again."
        ))
        #expect(model.refreshFailure == .retryable)
        #expect(model.canRetryRefresh)
    }

    @Test("new hand-off intent blocks old identity credential and quarantine publication")
    func handoffAndResolvedIdentityMutateCredentialsAtomically() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let oldCredential = StoredCredential(
            key: "old-manual-key", region: .usCloud, projectID: nil
        )
        let credentials = HeldCredentialLoadStore(credential: oldCredential)
        credentials.holdNextLoad()
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(
            flags: [
                SharedSnapshot.Flag(
                    id: 77, key: "old-project-flag", active: true,
                    quickToggleAllowed: false
                ),
            ]
        )
        let seededActivity = ActivityFeed(
            lines: [
                ActivityLine(
                    id: "old-project-event", event: "old_project_event", timestamp: nil
                ),
            ],
            capturedAt: WatchFixtures.now
        )
        try store.write(seeded)
        try WatchActivity.write(seededActivity, to: store)
        try store.writeBreachingWatchIDs(["old-project-watch"])
        var reloadSnapshots: [SharedSnapshot?] = []
        var reloadActivities: [ActivityFeed?] = []
        var reloadBreaches: [Set<String>] = []
        let model = WatchModel(
            credential: oldCredential,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: RouteTransport(
                routes: [
                    .init(
                        pathContains: "/users/@me/",
                        body: WatchFixtures.me(projectID: 1001)
                    ),
                ],
                unmatchedError: .network(
                    code: NSURLErrorNotConnectedToInternet,
                    description: "Synthetic offline failure"
                )
            ),
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: {
                reloadSnapshots.append(store.loadOrNil())
                reloadActivities.append(WatchActivity.read(from: store))
                reloadBreaches.append(store.breachingWatchIDs())
            },
            now: { WatchFixtures.now }
        )
        let handoffDefaultsSuite = "GetHogWatchTests-\(UUID().uuidString)"
        let refreshRevision = mutationCoordinator.currentRevision

        #expect(reloadSnapshots == [nil])
        #expect(reloadActivities == [nil])
        #expect(reloadBreaches == [[]])

        let coordination = Task.detached { () throws -> (UInt64, StoredCredential?, Bool) in
            try credentials.waitUntilHeldLoadIsCaptured()
            defer { credentials.releaseLoad() }
            let apply = Task.detached {
                guard let handoffDefaults = UserDefaults(
                    suiteName: handoffDefaultsSuite
                ) else { return false }
                return WatchSessionListener.apply(
                    WatchKeyTransfer(
                        key: "new-handoff-key",
                        region: .euCloud,
                        projectID: 42,
                        projectName: "Synthetic Replacement"
                    ),
                    credentials: credentials,
                    snapshots: store,
                    defaults: handoffDefaults,
                    mutationCoordinator: mutationCoordinator,
                    mutationDidAnnounce: { revision in
                        credentials.recordHandoffIntent(revision: revision)
                    },
                    notify: {}
                )
            }

            // Intent is announced before the hand-off waits for the mutation
            // lock. That positive revision, plus the still-old credential,
            // proves the replacement is queued behind the frozen `/me` load
            // without using a timeout as a proxy for blocked state.
            let announcedRevision = try credentials.waitUntilHandoffIntentIsAnnounced()
            let credentialWhileBlocked = credentials.currentCredential()
            credentials.releaseLoad()
            return (announcedRevision, credentialWhileBlocked, await apply.value)
        }
        let refresh = Task { @MainActor in await model.refresh() }
        let (announcedRevision, credentialWhileBlocked, applied) = try await coordination.value
        await refresh.value

        let finalCredential = try #require(try credentials.load())
        #expect(announcedRevision > refreshRevision)
        #expect(credentialWhileBlocked == oldCredential)
        #expect(applied)
        #expect(finalCredential.key == "new-handoff-key")
        #expect(finalCredential.region == .euCloud)
        #expect(finalCredential.projectID == 42)
        #expect(model.snapshot == nil)
        #expect(model.activity.isEmpty)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadSnapshots == [nil])
        #expect(reloadActivities == [nil])
        #expect(reloadBreaches == [[]])
        #expect(!credentials.didSynchronizationTimeout)
    }

    @Test("a hand-off queued before refresh blocks the old client before its first request")
    func queuedHandoffBlocksOldRefreshAtEntry() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let pause = PausedMutationIntent()
        let store = WatchFixtures.tempStore()
        try store.write(WatchFixtures.snapshot())
        try WatchActivity.write(
            ActivityFeed(
                lines: [
                    ActivityLine(
                        id: "queued-old-event", event: "queued_old_event", timestamp: nil
                    ),
                ],
                capturedAt: WatchFixtures.now
            ),
            to: store
        )
        try store.writeBreachingWatchIDs(["queued-old-watch"])
        let oldCredential = StoredCredential(
            key: "queued-old-key", region: .usCloud, projectID: nil
        )
        let credentials = InMemoryTokenStore(credential: oldCredential)
        let transport = RouteTransport(
            routes: [
                .init(
                    pathContains: "/users/@me/",
                    body: WatchFixtures.me(projectID: 1001)
                ),
            ]
        )
        var reloadSnapshots: [SharedSnapshot?] = []
        let model = WatchModel(
            credential: oldCredential,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: { reloadSnapshots.append(store.loadOrNil()) },
            now: { WatchFixtures.now }
        )
        let defaultsSuite = "GetHogWatchTests-\(UUID().uuidString)"
        let apply = Task.detached {
            guard let defaults = UserDefaults(suiteName: defaultsSuite) else { return false }
            return WatchSessionListener.apply(
                WatchKeyTransfer(
                    key: "queued-new-key", region: .euCloud, projectID: 42,
                    projectName: "Queued Synthetic Replacement"
                ),
                credentials: credentials,
                snapshots: store,
                defaults: defaults,
                mutationCoordinator: mutationCoordinator,
                mutationDidAnnounce: { revision in pause.pause(revision: revision) },
                notify: {}
            )
        }
        defer { pause.resume() }
        let announcedRevision = try await Task.detached {
            try pause.waitUntilAnnounced()
        }.value

        let refresh = Task { @MainActor in await model.refresh() }
        for _ in 0..<100 where !mutationCoordinator.hasSettlementWaiters {
            await Task.yield()
        }

        #expect(announcedRevision > 0)
        #expect(mutationCoordinator.hasPendingMutation)
        #expect(mutationCoordinator.hasSettlementWaiters)
        #expect(await transport.requests.isEmpty)
        #expect(model.snapshot == nil)
        #expect(model.activity.isEmpty)
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadSnapshots == [nil])

        pause.resume()
        #expect(await apply.value)
        await refresh.value
        #expect(!mutationCoordinator.hasPendingMutation)
        #expect(mutationCoordinator.currentRevision == announcedRevision)
        #expect(try credentials.load() == StoredCredential(
            key: "queued-new-key", region: .euCloud, projectID: 42
        ))
        #expect(store.loadOrNil() == nil)
        #expect(WatchActivity.read(from: store) == nil)
        #expect(store.breachingWatchIDs().isEmpty)
        #expect(reloadSnapshots == [nil])
        #expect(!pause.didSynchronizationTimeout)
    }

    @Test("a transfer committed before notification observation is reconciled from stores")
    func missedTransferNotificationIsReconciled() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let credentials = InMemoryTokenStore()
        let store = WatchFixtures.tempStore()
        let defaultsSuite = "GetHogWatchTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: nil,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: {},
            now: { WatchFixtures.now }
        )

        // The callback is intentionally swallowed: this is the launch window
        // after WCSession activation and before the view subscribes.
        let applied = WatchSessionListener.apply(
            WatchKeyTransfer(
                key: "missed-notification-key", region: .euCloud,
                projectID: 42, projectName: "Missed Synthetic Project"
            ),
            credentials: credentials,
            snapshots: store,
            defaults: defaults,
            mutationCoordinator: mutationCoordinator,
            projectDataDidChange: {},
            notify: {}
        )
        #expect(applied)
        #expect(model.phase == .needsKey)

        await model.reconcile(WatchHandoff.current(
            credentials: credentials,
            defaults: defaults,
            snapshots: store,
            mutationCoordinator: mutationCoordinator
        ))

        #expect(model.phase == .ready)
        #expect(model.hasCredential)
        #expect(model.snapshot?.projectID == 42)
        #expect(model.snapshot?.projectRegion == .euCloud)
        #expect(await transport.requests.count == 5)
    }

    @Test("a failed rollback at the same revision adopts the replacement credential")
    func equalRevisionReplacementCredentialIsReconciled() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let oldCredential = StoredCredential(
            key: "failed-rollback-old-key", region: .usCloud, projectID: 1001
        )
        let replacement = StoredCredential(
            key: "failed-rollback-new-key", region: .euCloud, projectID: 42
        )
        let credentials = InMemoryTokenStore(credential: oldCredential)
        let store = WatchFixtures.tempStore()
        let oldSnapshot = WatchFixtures.snapshot()
        try store.write(oldSnapshot)
        let defaultsSuite = "GetHogWatchTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: oldCredential,
            projectName: "Old Synthetic Project",
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: {},
            now: { WatchFixtures.now }
        )
        #expect(model.snapshot == oldSnapshot)

        // A failed changed-scope apply does not advance the committed revision.
        // If its credential rollback also fails, however, the replacement key
        // remains beside the deliberately blanked project files and defaults.
        store.clearSnapshot()
        WatchActivity.clear(from: store)
        store.clearBreachingWatchIDs()
        try store.writeMetricWatches([])
        try credentials.save(replacement)

        let failedRollbackHandoff = WatchHandoff.current(
            credentials: credentials,
            defaults: defaults,
            snapshots: store,
            mutationCoordinator: mutationCoordinator
        )
        #expect(failedRollbackHandoff.credentialRevision == 0)
        #expect(failedRollbackHandoff.credential == replacement)

        await model.reconcile(failedRollbackHandoff)

        #expect(model.phase == .ready)
        #expect(model.snapshot?.projectID == 42)
        #expect(model.snapshot?.projectRegion == .euCloud)
        #expect(model.snapshot?.projectName == "PostHog")
        let requestedPaths = await transport.requestedPaths()
        #expect(requestedPaths.count == 5)
        #expect(requestedPaths.allSatisfy { $0.contains("/api/projects/42/") })
        #expect(requestedPaths.allSatisfy { !$0.contains("/api/projects/1001/") })
    }

    @Test("an unchanged credential at the same revision remains a reconciliation no-op")
    func equalRevisionUnchangedCredentialDoesNotRefresh() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let credentials = InMemoryTokenStore(credential: WatchFixtures.credential)
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot()
        try store.write(seeded)
        let defaultsSuite = "GetHogWatchTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.set("Synthetic Analytics", forKey: WatchSettings.projectNameKey)
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: WatchFixtures.credential,
            projectName: "Synthetic Analytics",
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: {},
            now: { WatchFixtures.now }
        )

        await model.reconcile(WatchHandoff.current(
            credentials: credentials,
            defaults: defaults,
            snapshots: store,
            mutationCoordinator: mutationCoordinator
        ))

        #expect(model.snapshot == seeded)
        #expect(model.phase == .ready)
        #expect(await transport.requests.isEmpty)
    }

    @Test("a later committed intent refreshes after an older waiter is refused")
    func laterIntentWinsAndPublishesAfterSettlement() async throws {
        let mutationCoordinator = WatchCredentialMutationCoordinator()
        let pause = PausedMutationIntent()
        let credentials = InMemoryTokenStore()
        let store = WatchFixtures.tempStore()
        let defaultsSuite = "GetHogWatchTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: nil,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: store,
            credentialStore: credentials,
            mutationCoordinator: mutationCoordinator,
            authenticate: { _ in true },
            snapshotDidChange: {},
            now: { WatchFixtures.now }
        )

        let olderApply = Task.detached {
            guard let queuedDefaults = UserDefaults(suiteName: defaultsSuite) else {
                return false
            }
            return WatchSessionListener.apply(
                WatchKeyTransfer(
                    key: "older-queued-key", region: .usCloud,
                    projectID: 1001, projectName: "Older Synthetic Project"
                ),
                credentials: credentials,
                snapshots: store,
                defaults: queuedDefaults,
                mutationCoordinator: mutationCoordinator,
                mutationDidAnnounce: { revision in pause.pause(revision: revision) },
                projectDataDidChange: {},
                notify: {}
            )
        }
        defer { pause.resume() }
        let olderRevision = try await Task.detached {
            try pause.waitUntilAnnounced()
        }.value

        // The coordinator lock is deliberately non-fair. Revision 2 reaches
        // it while revision 1 is paused, commits, and announces an adoption
        // that cannot publish until the older pending intent is disposed of.
        let newerApplied = WatchSessionListener.apply(
            WatchKeyTransfer(
                key: "newer-winning-key", region: .euCloud,
                projectID: 42, projectName: "Newer Synthetic Project"
            ),
            credentials: credentials,
            snapshots: store,
            defaults: defaults,
            mutationCoordinator: mutationCoordinator,
            projectDataDidChange: {},
            notify: {}
        )
        let winningRevision = mutationCoordinator.currentRevision
        #expect(newerApplied)
        #expect(winningRevision > olderRevision)
        #expect(mutationCoordinator.hasPendingMutation)

        let reconciliation = Task { @MainActor in
            await model.reconcile(WatchHandoff.current(
                credentials: credentials,
                defaults: defaults,
                snapshots: store,
                mutationCoordinator: mutationCoordinator
            ))
        }
        for _ in 0..<100 where !mutationCoordinator.hasSettlementWaiters {
            await Task.yield()
        }
        #expect(model.hasCredential)
        #expect(mutationCoordinator.hasSettlementWaiters)
        #expect(await transport.requests.isEmpty)

        pause.resume()
        #expect(!(await olderApply.value))
        await reconciliation.value

        #expect(!mutationCoordinator.hasPendingMutation)
        #expect(mutationCoordinator.currentRevision == winningRevision)
        #expect(try credentials.load() == StoredCredential(
            key: "newer-winning-key", region: .euCloud, projectID: 42
        ))
        #expect(model.phase == .ready)
        #expect(model.snapshot?.projectID == 42)
        #expect(model.snapshot?.projectRegion == .euCloud)
        #expect(await transport.requests.count == 5)
        #expect(!pause.didSynchronizationTimeout)
    }

    @Test("legacy snapshot without region provenance is cleared conservatively")
    func relaunchRejectsLegacySnapshotWithoutProvenance() {
        let store = WatchFixtures.tempStore()
        try? store.write(WatchFixtures.snapshot(projectRegion: nil))

        let model = WatchFixtures.model(
            transport: OfflineTransport(), store: store
        )

        #expect(model.snapshot == nil)
        #expect(model.headlineMetric == nil)
        #expect(store.loadOrNil() == nil)
    }

    @Test("same-project credential rotation keeps its stale fallback")
    func sameProjectCredentialRotationKeepsStaleFallback() async throws {
        let store = WatchFixtures.tempStore()
        let seeded = WatchFixtures.snapshot(
            capturedAt: WatchFixtures.now.addingTimeInterval(-3600)
        )
        try store.write(seeded)
        let model = WatchFixtures.model(transport: OfflineTransport(), store: store)

        await model.adopt(
            WatchHandoff(
                credential: StoredCredential(
                    key: "rotated-test-key", region: .usCloud, projectID: 1001
                ),
                projectName: "Synthetic Analytics",
                headlineMetricID: nil,
                watches: [],
                watchesDegraded: false
            )
        )

        #expect(model.snapshot == seeded)
        #expect(model.headlineMetric?.id == seeded.metrics.first?.id)
        #expect(store.loadOrNil() == seeded)
        #expect(model.phase == .ready)
        #expect(model.refreshGuidance == .iPhoneOffline)
    }

    @Test("a hand-off that cleared the credential returns to the empty state")
    func adoptingAnEmptyHandoffReturnsToNeedsKey() async {
        let store = WatchFixtures.tempStore()
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchFixtures.model(transport: transport, store: store)
        await model.refresh()
        #expect(model.phase == .ready)

        await model.adopt(
            WatchHandoff(
                credential: nil, projectName: nil, headlineMetricID: nil,
                watches: [], watchesDegraded: false
            )
        )

        #expect(model.phase == .needsKey)
        // Nothing further was asked for on a credential that no longer exists.
        #expect(await transport.requests.count == 5)
        #expect(model.health == .empty)
    }

    @Test("no credential means no requests and a phase that says why")
    func noCredentialNeedsKey() async {
        let transport = RouteTransport(routes: WatchFixtures.fullRefreshRoutes())
        let model = WatchModel(
            credential: nil,
            projectName: nil,
            headlineMetricID: nil,
            watches: [],
            transport: transport,
            store: WatchFixtures.tempStore(),
            authenticate: { _ in true },
            now: { WatchFixtures.now }
        )

        await model.refresh()

        #expect(model.phase == .needsKey)
        #expect(await transport.requests.isEmpty)
    }

    @Test("a rejected credential keeps the replacement form available")
    func failedPhaseOffersCredentialReplacement() {
        let message = "The synthetic key was rejected."
        let selfHostedURL = URL(string: "https://watch.example.invalid")!

        #expect(WatchCredentialEntryState(phase: .needsKey) == .missing)
        #expect(WatchCredentialEntryState(phase: .failed(message)) == nil)
        #expect(
            WatchCredentialEntryState(
                phase: .failed(message),
                refreshFailure: .authentication,
                credentialRegion: .euCloud
            ) == .replacement(message: message, region: .euCloud)
        )
        #expect(
            WatchCredentialEntryState(
                phase: .failed(message),
                refreshFailure: .authentication,
                credentialRegion: .selfHosted(selfHostedURL)
            ) == .replacement(
                message: message,
                region: .selfHosted(selfHostedURL)
            )
        )
        #expect(
            WatchCredentialEntryState(
                phase: .failed(message), refreshFailure: .authentication
            ) == nil
        )
        #expect(WatchCredentialEntryState(phase: .loading) == nil)
        #expect(WatchCredentialEntryState(phase: .ready) == nil)
    }

    @Test("replacement draft preselects the existing endpoint")
    func replacementDraftPreselectsExistingEndpoint() {
        let selfHostedURL = URL(string: "https://watch.example.invalid")!

        #expect(
            WatchManualCredentialDraft(state: .missing)
                == WatchManualCredentialDraft(region: .usCloud, selfHostedURL: "")
        )
        #expect(
            WatchManualCredentialDraft(
                state: .replacement(message: "Rejected", region: .euCloud)
            ) == WatchManualCredentialDraft(region: .euCloud, selfHostedURL: "")
        )
        #expect(
            WatchManualCredentialDraft(
                state: .replacement(
                    message: "Rejected",
                    region: .selfHosted(selfHostedURL)
                )
            ) == WatchManualCredentialDraft(
                region: .selfHosted,
                selfHostedURL: "https://watch.example.invalid"
            )
        )
    }

    @Test("the Watch test host resolves the exact iOS-style App Group identifier")
    func watchHostUsesTheUnprefixedAppGroupIdentifier() {
        #expect(SharedSnapshotStore.bundleAppGroupIdentifier == "group.app.gethog")
        #expect(SharedSnapshotStore.shared.isSharedContainer)
    }
}
