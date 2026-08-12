#if os(macOS) && GETHOG_WIDGET_ACCEPTANCE

import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Signed widget acceptance boundary")
@MainActor
struct MacSignedWidgetAcceptanceTests {

    private let sessionID = "018f1000-0000-7000-8000-000000000099"
    @Test("only the exact credential-free acceptance contract enables the test binary seam")
    func exactPolicyGate() throws {
        let environment = acceptedEnvironment()
        let request = try #require(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument]
        ))

        #expect(request.runID.uuidString.lowercased() == sessionID)

        var mutations: [[String: String]] = []
        mutations.append(environment.filter { $0.key != SignedWidgetAcceptancePolicy.gateKey })
        mutations.append(environment.merging([
            SignedWidgetAcceptancePolicy.gateKey: "wrong-version"
        ]) { _, new in new })
        mutations.append(environment.merging([
            SignedWidgetAcceptancePolicy.runIDKey: sessionID.uppercased()
        ]) { _, new in new })
        mutations.append(environment.merging([
            SignedWidgetAcceptancePolicy.runIDKey: "not-a-uuid"
        ]) { _, new in new })
        mutations.append(environment.merging(["GETHOG_API_KEY": "must-be-rejected"]) { _, new in new })
        mutations.append(environment.merging(["GETHOG_ACCEPTANCE_PAYLOAD": "must-be-rejected"]) { _, new in new })

        for mutation in mutations {
            #expect(SignedWidgetAcceptancePolicy.request(
                environment: mutation,
                arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument]
            ) == nil)
        }
        #expect(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog"]
        ) == nil)
        #expect(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument, "-GetHogDemo"]
        ) == nil)
        #expect(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: [
                "GetHog",
                SignedWidgetAcceptancePolicy.launchArgument,
                SignedWidgetAcceptancePolicy.launchArgument,
            ]
        ) == nil)
    }

    @Test("publication replaces stale state and completes only after the timeline reload")
    func publicationOrderingAndFreshness() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "signed-widget-acceptance-tests")
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedSnapshotStore(directory: directory, isSharedContainer: true)
        try store.write(SharedSnapshot(
            projectID: 9,
            projectName: "Stale fictional project",
            metrics: [],
            flags: [],
            capturedAt: Date(timeIntervalSinceReferenceDate: 1)
        ))
        try store.enqueue(PendingFlagWrite(
            flagID: 7,
            key: "stale-fictional-flag",
            desiredActive: true
        ))
        try store.enqueue(PendingOpen(metricID: "stale-fictional-metric"))
        let request = try #require(SignedWidgetAcceptancePolicy.request(
            environment: acceptedEnvironment(),
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument]
        ))
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var snapshotObservedDuringReload: SharedSnapshot?

        let completion = try SignedWidgetAcceptancePublisher.publish(
            request: request,
            store: store,
            capturedAt: now,
            reloadTimelines: { snapshotObservedDuringReload = store.loadOrNil() }
        )

        let snapshot = try #require(snapshotObservedDuringReload)
        #expect(snapshot.capturedAt == now)
        #expect(snapshot.projectID == SignedWidgetAcceptanceFixture.projectID)
        #expect(snapshot.metrics.first?.title == "Signed widget acceptance 018f1000")
        #expect(snapshot.metrics.first?.dashboardID == SignedWidgetAcceptanceFixture.dashboardID)
        #expect(completion.accessibilityIdentifier == "gethog.widget-acceptance.complete.\(sessionID)")
        #expect(store.pendingFlagWrite() == nil)
        #expect(store.pendingOpen() == nil)
    }

    @Test("publication refuses a private fallback container")
    func publicationRequiresResolvedSharedContainer() throws {
        let request = try #require(SignedWidgetAcceptancePolicy.request(
            environment: acceptedEnvironment(),
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument]
        ))
        let store = SharedSnapshotStore(
            directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            isSharedContainer: false
        )
        var reloaded = false

        #expect(throws: SignedWidgetAcceptanceError.unsharedContainer) {
            try SignedWidgetAcceptancePublisher.publish(
                request: request,
                store: store,
                capturedAt: Date(),
                reloadTimelines: { reloaded = true }
            )
        }
        #expect(!reloaded)
    }

    @Test("a strict-clear failure prevents snapshot write, reload, and completion")
    func strictClearFailureShortCircuitsPublication() throws {
        let request = try #require(SignedWidgetAcceptancePolicy.request(
            environment: acceptedEnvironment(),
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument]
        ))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedSnapshotStore(directory: directory, isSharedContainer: true)
        let stale = SharedSnapshot(
            projectID: 9,
            projectName: "Stale fictional project",
            metrics: [],
            flags: [],
            capturedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        try store.write(stale)
        var reloaded = false
        let clearingFailure = SharedSnapshotStore.ProjectDataClearError(failures: [
            .init(
                artifact: "snapshot",
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteNoPermission.rawValue
            )
        ])

        do {
            try SignedWidgetAcceptancePublisher.publish(
                request: request,
                store: store,
                capturedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                clearProjectData: { _ in throw clearingFailure },
                reloadTimelines: { reloaded = true }
            )
            Issue.record("Publication continued after strict clearing failed.")
        } catch let error as SharedSnapshotStore.ProjectDataClearError {
            #expect(error == clearingFailure)
        }

        #expect(store.loadOrNil() == stale)
        #expect(!reloaded)
    }

    private func acceptedEnvironment() -> [String: String] {
        [
            SignedWidgetAcceptancePolicy.gateKey: SignedWidgetAcceptancePolicy.gateValue,
            SignedWidgetAcceptancePolicy.runIDKey: sessionID,
        ]
    }
}

#endif
