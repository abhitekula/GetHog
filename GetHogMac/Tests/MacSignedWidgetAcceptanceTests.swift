import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Signed widget acceptance boundary")
@MainActor
struct MacSignedWidgetAcceptanceTests {

    private let sessionID = "11111111-2222-3333-4444-555555555555"
    private let configurationPath = "/tmp/GetHogMacUITests.xctestconfiguration"
    private let bundlePath = "/tmp/GetHogMacUITests.xctest"

    @Test("only the exact credential-free XCTest contract enables the Release seam")
    func exactPolicyGate() throws {
        let environment = acceptedEnvironment()
        let request = try #require(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument],
            fileExists: { [configurationPath, bundlePath].contains($0) },
            releaseBuild: true
        ))

        #expect(request.runID.uuidString.lowercased() == sessionID)

        var mutations: [[String: String]] = []
        mutations.append(environment.filter { $0.key != SignedWidgetAcceptancePolicy.gateKey })
        mutations.append(environment.merging([
            SignedWidgetAcceptancePolicy.gateKey: "wrong-version"
        ]) { _, new in new })
        mutations.append(environment.filter { $0.key != "XCTestConfigurationFilePath" })
        mutations.append(environment.filter { $0.key != "XCTestBundlePath" })
        mutations.append(environment.filter { $0.key != "XCTestSessionIdentifier" })
        mutations.append(environment.merging([
            SignedWidgetAcceptancePolicy.runIDKey: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        ]) { _, new in new })
        mutations.append(environment.merging(["GETHOG_API_KEY": "must-be-rejected"]) { _, new in new })
        mutations.append(environment.merging(["GETHOG_ACCEPTANCE_PAYLOAD": "must-be-rejected"]) { _, new in new })

        for mutation in mutations {
            #expect(SignedWidgetAcceptancePolicy.request(
                environment: mutation,
                arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument],
                fileExists: { [configurationPath, bundlePath].contains($0) },
                releaseBuild: true
            ) == nil)
        }
        #expect(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog"],
            fileExists: { [configurationPath, bundlePath].contains($0) },
            releaseBuild: true
        ) == nil)
        #expect(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument, "-GetHogDemo"],
            fileExists: { [configurationPath, bundlePath].contains($0) },
            releaseBuild: true
        ) == nil)
        #expect(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument],
            fileExists: { _ in false },
            releaseBuild: true
        ) == nil)
        #expect(SignedWidgetAcceptancePolicy.request(
            environment: environment,
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument],
            fileExists: { [configurationPath, bundlePath].contains($0) },
            releaseBuild: false
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
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument],
            fileExists: { [configurationPath, bundlePath].contains($0) },
            releaseBuild: true
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
        #expect(snapshot.metrics.first?.title == "Signed widget acceptance 11111111")
        #expect(snapshot.metrics.first?.dashboardID == SignedWidgetAcceptanceFixture.dashboardID)
        #expect(completion.accessibilityIdentifier == "gethog.widget-acceptance.complete.\(sessionID)")
        #expect(store.pendingFlagWrite() == nil)
        #expect(store.pendingOpen() == nil)
    }

    @Test("publication refuses a private fallback container")
    func publicationRequiresResolvedSharedContainer() throws {
        let request = try #require(SignedWidgetAcceptancePolicy.request(
            environment: acceptedEnvironment(),
            arguments: ["GetHog", SignedWidgetAcceptancePolicy.launchArgument],
            fileExists: { [configurationPath, bundlePath].contains($0) },
            releaseBuild: true
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

    private func acceptedEnvironment() -> [String: String] {
        [
            SignedWidgetAcceptancePolicy.gateKey: SignedWidgetAcceptancePolicy.gateValue,
            SignedWidgetAcceptancePolicy.runIDKey: sessionID,
            "XCTestConfigurationFilePath": configurationPath,
            "XCTestBundlePath": bundlePath,
            "XCTestSessionIdentifier": sessionID,
        ]
    }
}
