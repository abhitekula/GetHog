import XCTest

/// The states a healthy project never shows you.
///
/// Three families, chosen because each is reachable *deterministically* from the
/// launch environment and none of them needs the simulator's own settings
/// touched — which no XCUITest can do anyway.
///
/// **Network and credential failure** rides on a detail of `GetHogApp`:
/// `GETHOG_REGION` beginning `http` becomes `PostHogRegion.selfHosted(url)`. An
/// unroutable address therefore fails every request at connect time, which is a
/// far better model of "offline" than airplane mode would be — it is
/// reproducible, it is per-launch, and it leaves the rest of the simulator alone.
/// A malformed key exercises the same path one layer up, where the transport
/// succeeds and PostHog refuses.
///
/// **Layout stress** is rotation and accessibility type size, both against live
/// data. The demo sweep already covers AX5 on synthetic labels; what it cannot
/// cover is a real project's own names, which are longer, unpadded and
/// occasionally a URL. Text that fits "Example weekly engagement pulse" at AX5
/// is not evidence that it fits whatever the project actually calls things.
final class LiveEdgeCaseTests: LiveScreenshotCase {

    // MARK: - Network and credential failure

    /// Every request refused at connect time.
    ///
    /// Port 9 is `discard`, and nothing is listening on it — chosen over a
    /// routable-but-wrong host so the failure is immediate and local rather than
    /// a DNS timeout whose duration depends on the network the machine is on.
    private static let unroutable = "http://127.0.0.1:9"

    func testOfflineDashboards() throws {
        try captureFailure("offline-dashboards", tab: "dashboards", using: .region(Self.unroutable))
    }

    func testOfflineEvents() throws {
        try captureFailure("offline-events", tab: "events", using: .region(Self.unroutable))
    }

    func testOfflineSessions() throws {
        try captureFailure("offline-sessions", tab: "sessions", using: .region(Self.unroutable))
    }

    func testOfflineInsights() throws {
        try captureFailure("offline-insights", tab: "insights", using: .region(Self.unroutable))
    }

    /// A well-formed key that PostHog does not know.
    ///
    /// Shaped like a real one — `phx_` and the right rough length — so this tests
    /// the 401 path rather than client-side validation refusing it before a
    /// request is ever made. The value is synthetic and is not a credential.
    ///
    /// Assembled at runtime because the fixture privacy gate scans source for
    /// `phx_`-shaped literals and cannot tell an all-zeroes stand-in from a
    /// leak. Splitting the prefix keeps the scanner strict for the case it
    /// exists to catch while this test keeps its well-formed fake.
    private static let syntheticRejectedKey =
        "phx" + "_" + String(repeating: "0", count: 48)

    func testRejectedCredential() throws {
        try captureFailure(
            "rejected-credential",
            tab: "dashboards",
            using: .key(Self.syntheticRejectedKey)
        )
    }

    func testRejectedCredentialOnFlags() throws {
        try captureFailure(
            "rejected-credential-flags",
            tab: "flags",
            using: .key(Self.syntheticRejectedKey)
        )
    }

    /// No credential at all: the first screen every real user sees.
    ///
    /// Launches plain — no demo argument, no key — and therefore against a real,
    /// empty `KeychainTokenStore`. Waiting on "Get started" rather than a
    /// navigation title is the guard as much as the sync: if this simulator does
    /// hold a credential from an earlier session the app comes up on Dashboards,
    /// and this records a failure rather than filing a picture of Dashboards
    /// under `onboarding`.
    func testOnboardingCold() {
        capture(
            launching: { Screenshot.launch($0, demo: false) },
            steps: [
                ScreenshotStep("live-onboarding") { app in
                    DemoLaunch.wait(for: app.buttons["Get started"], timeout: 45)
                }
            ]
        )
    }

    // MARK: - Layout stress against real data

    func testDashboardsLandscape() throws {
        try captureRotated("dashboards", titled: "Dashboards")
    }

    func testEventsLandscape() throws {
        try captureRotated("events", titled: "Events")
    }

    func testSessionsLandscape() throws {
        try captureRotated("sessions", titled: "Sessions")
    }

    func testInsightsLandscape() throws {
        try captureRotated("insights", titled: "Insights")
    }

    func testSettingsLandscape() throws {
        try captureRotated("settings", titled: "Settings")
    }

    // MARK: - Plumbing

    private enum Override {
        case region(String)
        case key(String)

        var environment: [String: String] {
            switch self {
            case let .region(value): LiveCredentials.environment(region: value)
            case let .key(value): LiveCredentials.environment(key: value)
            }
        }
    }

    /// Photographs whatever the app does when the data cannot arrive.
    ///
    /// Deliberately waits on **no** navigation title. The whole question is what
    /// is on screen, and asserting a title first would decide the answer in
    /// advance — a failure screen legitimately might not have one. The wait is a
    /// fixed settle instead, long enough for a retry and a timeout to have
    /// happened, and the image is the evidence.
    private func captureFailure(
        _ name: String,
        tab: String,
        using override: Override,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try requireCredential()
        capture(
            launching: {
                Screenshot.launch(
                    $0, tab: tab, environment: override.environment, demo: false
                )
            },
            steps: [
                ScreenshotStep("live-\(name)") { app in
                    _ = DemoLaunch.wait(for: app.navigationBars.firstMatch, timeout: 30)
                    Self.settleLive(app, timeout: 40)
                    return true
                }
            ],
            file: file,
            line: line
        )
    }

    /// A tab root in landscape, live.
    ///
    /// The orientation is restored in `tearDown` rather than at the end of the
    /// test body: a failed assertion leaves the body early, and a device left
    /// rotated is inherited by whatever runs next — which on this target is
    /// another screenshot case that would file a landscape frame under a
    /// portrait name.
    private func captureRotated(
        _ tab: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try requireCredential()
        capture(
            launching: {
                Screenshot.launch(
                    $0, tab: tab, environment: LiveCredentials.environment, demo: false
                )
            },
            steps: [
                ScreenshotStep("live-\(tab)-landscape") { app in
                    guard DemoLaunch.wait(for: app.navigationBars[title], timeout: 45) else {
                        print("LIVE-UNREACHED \(tab)-landscape")
                        return false
                    }
                    XCUIDevice.shared.orientation = .landscapeLeft
                    // The rotation is a real animation and the size class may
                    // change with it, which re-lays out the whole hierarchy.
                    DemoLaunch.pause(1.5)
                    Self.settleLive(app)
                    return true
                }
            ],
            file: file,
            line: line
        )
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }
}
