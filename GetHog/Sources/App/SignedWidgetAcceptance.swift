#if os(macOS) && GETHOG_WIDGET_ACCEPTANCE

import Foundation
import GetHogKit

/// A narrowly scoped request to prove the signed app-to-widget container.
///
/// This exists only in the dedicated, test-built Release acceptance slice. An
/// ordinary Debug/Release/archive compilation omits the entire file because
/// the project never defines `GETHOG_WIDGET_ACCEPTANCE`.
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

    /// Returns a request only for the exact credential-free XCUITest contract.
    /// The compilation condition is the primary boundary; these checks keep
    /// the test-only binary deterministic and prevent payload injection.
    static func request(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> SignedWidgetAcceptanceRequest? {
        let allowedGetHogKeys: Set<String> = [gateKey, runIDKey]
        let hasUnexpectedGetHogInput = environment.keys.contains {
            $0.hasPrefix("GETHOG_") && !allowedGetHogKeys.contains($0)
        }
        guard environment[gateKey] == gateValue,
              !hasUnexpectedGetHogInput,
              arguments.filter({ $0 == launchArgument }).count == 1,
              arguments.filter({ $0.hasPrefix("-GetHog") }).count == 1,
              !arguments.contains(DemoTransport.launchArgument),
              let runIDValue = environment[runIDKey],
              let runID = UUID(uuidString: runIDValue),
              runID.uuidString.lowercased() == runIDValue
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
        clearProjectData: (SharedSnapshotStore) throws -> Void = {
            try $0.clearProjectDataStrict()
        },
        reloadTimelines: () -> Void
    ) throws -> SignedWidgetAcceptanceCompletion {
        guard store.isSharedContainer else {
            throw SignedWidgetAcceptanceError.unsharedContainer
        }
        try clearProjectData(store)
        try store.write(SignedWidgetAcceptanceFixture.snapshot(for: request, capturedAt: capturedAt))
        reloadTimelines()
        return SignedWidgetAcceptanceCompletion(runID: request.runID)
    }
}

#endif
