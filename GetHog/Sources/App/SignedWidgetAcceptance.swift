#if os(macOS)

import Foundation
import GetHogKit

/// A narrowly scoped request to prove the signed app-to-widget container.
///
/// This is compiled in Release because an unsigned or Debug build cannot prove
/// App Group sharing. It is not a demo-mode switch: the policy requires the
/// UI-test runner's own session/configuration witnesses, accepts no payload or
/// credential, and the publisher below can write only its fixed fictional
/// fixture. A normal launch cannot construct a request from product input.
struct SignedWidgetAcceptanceRequest: Equatable, Sendable {
    let runID: UUID

    var runTag: String {
        String(runID.uuidString.lowercased().prefix(8))
    }

    var completionAccessibilityIdentifier: String {
        "gethog.widget-acceptance.complete.\(runID.uuidString.lowercased())"
    }
}

enum SignedWidgetAcceptancePolicy {
    static let launchArgument = "-GetHogSignedWidgetAcceptance"
    static let gateKey = "GETHOG_SIGNED_WIDGET_ACCEPTANCE"
    static let gateValue = "xctest-fixed-fiction-v1"
    static let runIDKey = "GETHOG_SIGNED_WIDGET_ACCEPTANCE_RUN_ID"

    static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// Returns a request only for the exact XCUITest contract.
    ///
    /// The run id must be the test session id, not an arbitrary payload. Both
    /// XCTest paths must exist and have the expected bundle/configuration
    /// shapes. Credential-bearing and broad demo launches are refused even if
    /// every other field is present.
    static func request(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        releaseBuild: Bool = isReleaseBuild
    ) -> SignedWidgetAcceptanceRequest? {
        let allowedGetHogKeys: Set<String> = [gateKey, runIDKey]
        let hasUnexpectedGetHogInput = environment.keys.contains {
            $0.hasPrefix("GETHOG_") && !allowedGetHogKeys.contains($0)
        }
        guard releaseBuild,
              environment[gateKey] == gateValue,
              !hasUnexpectedGetHogInput,
              arguments.filter({ $0 == launchArgument }).count == 1,
              !arguments.contains(DemoTransport.launchArgument),
              let runIDValue = environment[runIDKey],
              let sessionValue = environment["XCTestSessionIdentifier"],
              runIDValue.caseInsensitiveCompare(sessionValue) == .orderedSame,
              let runID = UUID(uuidString: runIDValue),
              runID.uuidString.caseInsensitiveCompare(runIDValue) == .orderedSame,
              let configurationPath = environment["XCTestConfigurationFilePath"],
              configurationPath.hasSuffix(".xctestconfiguration"),
              fileExists(configurationPath),
              let bundlePath = environment["XCTestBundlePath"],
              bundlePath.hasSuffix("GetHogMacUITests.xctest"),
              fileExists(bundlePath)
        else { return nil }

        return SignedWidgetAcceptanceRequest(runID: runID)
    }
}

enum SignedWidgetAcceptanceFixture {
    static let projectID = 1_001
    static let dashboardID = 725_101
    static let projectName = "Signed Widget Acceptance"

    static func snapshot(
        for request: SignedWidgetAcceptanceRequest,
        capturedAt: Date
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: projectID,
            projectName: projectName,
            metrics: [
                SharedSnapshot.Metric(
                    id: "signed-widget-acceptance",
                    title: "Signed widget acceptance \(request.runTag)",
                    value: 42,
                    unit: nil,
                    previous: 40,
                    sparkline: [38, 39, 40, 41, 42],
                    dashboardID: dashboardID
                )
            ],
            metricSource: .pinnedDashboard,
            flags: [],
            projectRegion: .usCloud,
            authSessionID: request.runID,
            capturedAt: capturedAt
        )
    }
}

enum SignedWidgetAcceptanceError: Error, Equatable {
    case unsharedContainer
}

struct SignedWidgetAcceptanceCompletion: Equatable, Sendable {
    let runID: UUID

    var accessibilityIdentifier: String {
        "gethog.widget-acceptance.complete.\(runID.uuidString.lowercased())"
    }
}

enum SignedWidgetAcceptancePublisher {
    /// Replaces all project-scoped state, atomically writes this run's tagged
    /// fixture, invokes WidgetKit's synchronous reload request, and only then
    /// returns the completion witness the UI exposes to XCUITest.
    @MainActor
    static func publish(
        request: SignedWidgetAcceptanceRequest,
        store: SharedSnapshotStore = .shared,
        capturedAt: Date = Date(),
        reloadTimelines: () -> Void
    ) throws -> SignedWidgetAcceptanceCompletion {
        guard store.isSharedContainer else {
            throw SignedWidgetAcceptanceError.unsharedContainer
        }
        store.clearProjectData()
        try store.write(SignedWidgetAcceptanceFixture.snapshot(for: request, capturedAt: capturedAt))
        reloadTimelines()
        return SignedWidgetAcceptanceCompletion(runID: request.runID)
    }
}

#endif
