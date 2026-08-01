import XCTest

/// Launches GetHog against `DemoTransport`'s authored fixtures.
///
/// Every test in this target drives the demo build (`-GetHogDemo`), which
/// serves deterministic schema-shaped responses out of the app bundle instead of the
/// network. Two properties the assertions here depend on: a run is identical
/// every time, so an element count or a frame can be pinned exactly; and no
/// request leaves the simulator, so a full sweep spends nothing from the
/// rate-limit budget that belongs to the whole organisation.
///
/// Screens are reached by launch environment rather than by tapping, because a
/// test that navigates is a test that also fails when navigation changes. Both
/// variables are `DebugLaunch`'s and are inert in a build that does not set them.
enum DemoLaunch {

    /// The authored session the demo player actually plays.
    ///
    /// `DemoTransport` answers any session id with the first row of
    /// `session_recordings.json`, and this is that row — it is also the only
    /// session with a stored AI summary, so the whole detail screen is populated.
    static let replaySessionID = "018f1000-0000-7000-8000-000000000001"

    /// `dashboard_detail_raw.json` — the synthetic example dashboard.
    static let dashboardID = 725_101

    /// The first tile in that fixture, by `order`.
    static let firstTileTitle = "Example weekly engagement pulse"

    /// Launches, and waits until a real screen is on screen.
    ///
    /// - Parameters:
    ///   - tab: an `AppTab` raw value for `GETHOG_TAB`.
    ///   - openURL: a `gethog://` URL for `GETHOG_OPEN_URL`.
    ///
    /// Never both: `RootView` applies `GETHOG_TAB` *after* it drains the link
    /// inbox, deliberately, so a tab would overrule the URL.
    static func launch(
        tab: String? = nil,
        openURL: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        precondition(tab == nil || openURL == nil, "GETHOG_TAB overrules GETHOG_OPEN_URL.")

        // Before anything is terminated or launched — see `ExclusiveRun`.
        guard ExclusiveRun.claim(file: file, line: line) else { return XCUIApplication() }

        let app = XCUIApplication()
        app.launchArguments = ["-GetHogDemo"]
        if let tab { app.launchEnvironment["GETHOG_TAB"] = tab }
        if let openURL { app.launchEnvironment["GETHOG_OPEN_URL"] = openURL }
        app.launch()

        if !waitForScreen(app) {
            // One relaunch, because the failure this recovers is the simulator's
            // and not the app's. Measured: the SQL console rendered nothing at
            // all as the seventeenth launch of a run and passed on its own in 4.8
            // seconds immediately afterwards. Retrying weakens no assertion here
            // — everything this target measures is a property of the rendered
            // tree, and a screen that never rendered is measured either way.
            app.terminate()
            app.launch()
            XCTAssertTrue(
                waitForScreen(app),
                "App never reached a rendered screen in demo mode, twice.",
                file: file,
                line: line
            )
        }
        return app
    }

    /// Whether a real screen came up.
    ///
    /// `AppModel.phase` is `.loading` until `bootstrap()` has resolved the user
    /// and the project, and that phase draws a bare `ProgressView` with no
    /// navigation container at all — so the first navigation bar is the signal
    /// that the app is past it and a screen is rendered.
    private static func waitForScreen(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        wait(for: app.navigationBars.firstMatch, timeout: timeout)
    }

    /// Polls for an element instead of calling `waitForExistence`.
    ///
    /// Same reason `settle` polls: a failing XCTest wait captures a full element
    /// debug description on every retry, and enough of those in a row end the run
    /// rather than failing a test.
    static func wait(for element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            pause(0.5)
        }
        return false
    }

    /// Waits for the in-flight loads a screen starts on appear.
    ///
    /// `DemoTransport` sleeps 120ms per response on purpose, so every screen
    /// genuinely passes through its loading state; asserting against a skeleton
    /// would measure the placeholder rather than the screen.
    ///
    /// Polls `exists` rather than calling `waitForNonExistence`. XCTest captures
    /// a full element debug description on every failed check of a wait, and on a
    /// screen whose spinner never stops, thirty seconds of that took the test
    /// runner down with "unexpected exit, crash, or test timeout" rather than
    /// failing. A short bounded poll gives a loading screen time to arrive
    /// without punishing one that will never settle.
    ///
    /// The screen that motivated this was Events, whose paging footer spun
    /// whether or not a request was in flight; that is fixed and Events is in the
    /// audit sweep now. The poll stays, because it is the shape that survives the
    /// next one rather than a workaround for that one.
    static func settle(_ app: XCUIApplication, timeout: TimeInterval = 6) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.activityIndicators.firstMatch.exists { break }
            pause(0.25)
        }
        // Layout lands a frame or two after the data does, and every frame
        // assertion in this target reads a rendered geometry.
        pause(0.5)
    }

    /// Waits without blocking the runner's run loop.
    ///
    /// `Thread.sleep` looks like the obvious thing here and is the wrong one: a
    /// UI test body runs on the runner's main thread, and sleeping it stops the
    /// automation session answering. An expectation that is never fulfilled
    /// spends the same wall time while the loop keeps turning.
    static func pause(_ seconds: TimeInterval) {
        // Every polling loop in both targets funnels through here, which makes
        // it the one place a long-running run reliably reports that it is still
        // alive. `ExclusiveRun.heartbeat` throttles itself; this is not a write
        // twice a second.
        ExclusiveRun.heartbeat()
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    /// Every element carrying an exact accessibility label, of any type.
    ///
    /// Typed queries are the wrong tool for these assertions: the whole question
    /// in `ReplayStageAccessibilityTests` is *what type* the replay stage ends up
    /// as, and pinning it to `.image` or `.other` would make the test pass or
    /// fail on a SwiftUI implementation detail rather than on the defect.
    static func elements(labelled label: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
    }
}

/// One simulator, one run at a time.
///
/// **The failure this exists for, and why it was so hard to read.** Three agents
/// were once pointed at the *same* `iPhone 17 Pro` simulator at once. Every test
/// in both UI targets begins by terminating `app.gethog.GetHog` and
/// launching it again with its own arguments, so each run was killing the other
/// two mid-screen. What came back was `** TEST FAILED **` with **no assertion
/// output at all** — the runners were being torn down between tests rather than
/// failing one, so there was nothing for XCTest to attribute. Nothing in the
/// output named the simulator, and nothing suggested that a second run existed.
///
/// **What is guarded, and what is not.** The contended resource is the
/// *simulator*, not the repository or the working tree: two runs on two
/// destinations interleave perfectly well, and that is the recommended way to
/// split a sweep. So the lock is keyed on `SIMULATOR_UDID`, which CoreSimulator
/// injects into every process it starts including the test runner — the same
/// channel `SIMULATOR_DEVICE_NAME` arrives through, which `Screenshot.deviceName`
/// has depended on since the harness was written. Two runs on one device
/// collide; an iPhone run and an iPad run do not.
///
/// **Why a file on the host and not a simulator-local one.** The lock has to be
/// visible to a *different* runner process inside a *different* boot of the same
/// device, and the host filesystem is the only thing those two share. The runner
/// can write to it — that is the measurement the whole screenshot harness is
/// built on.
///
/// **Staleness is a heartbeat, not a timeout.** A run that crashes cannot delete
/// its own lock, and a lock nobody can clear is worse than no lock: the next
/// person's first honest run fails and the fix is "delete this file", which is
/// exactly the tribal knowledge this is supposed to remove. So a live run
/// re-stamps its lock through `DemoLaunch.pause`, and a lock that has not been
/// stamped for `staleAfter` is taken over. The window is generous relative to the
/// longest gap between stamps in either target: the poll loops stamp every half
/// second, and the longest stretch with no polling at all is a `launch()` call,
/// measured at 1–4 seconds.
///
/// **Both runs are told, not just the loser.** The claim is written with the
/// claimant's own identity in it and re-read on every heartbeat. Two runs that
/// start within the same second both see an empty slot and both write; the second
/// write wins, and the first discovers on its next heartbeat that the lock is no
/// longer its own. Without that read-back the earlier run would keep driving a
/// device it no longer owns, which is precisely the silent case.
enum ExclusiveRun {

    /// How long a lock survives without being re-stamped.
    private static let staleAfter: TimeInterval = 90

    /// How often a live run re-stamps. Well under `staleAfter`, and far above
    /// the rate `DemoLaunch.pause` is called at.
    private static let heartbeatEvery: TimeInterval = 10

    /// The repository root, found by walking up from this file until
    /// `project.yml` appears.
    ///
    /// Derived rather than configured: an environment variable would have to be
    /// remembered on every invocation, and a literal path would be wrong the
    /// first time the repo is cloned somewhere else. Walking up rather than
    /// counting components, so moving this file into another subdirectory does
    /// not silently point the output at the wrong place.
    ///
    /// `Screenshot.repositoryRoot` is this — one derivation, because two would
    /// drift and the images and the lock have to agree on where `build/` is.
    static let repositoryRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("project.yml").path
            ) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        // Unreachable in this repository; falling back keeps a capture run
        // producing *something* rather than trapping halfway through a sweep.
        return URL(fileURLWithPath: NSTemporaryDirectory())
    }()

    /// What CoreSimulator says this device is.
    ///
    /// The UDID is used only to keep two simulator locks distinct. It is never
    /// included in diagnostics or test artifacts.
    private static let deviceUDID = ProcessInfo.processInfo
        .environment["SIMULATOR_UDID"] ?? "unknown-device"

    /// This run's identity, written into the lock and compared back out of it.
    ///
    /// The bundle identifier distinguishes an audit run from a screenshot run,
    /// and the start instant distinguishes two runs of the same target. Together
    /// they are unique enough that a read-back mismatch means somebody else
    /// wrote, and readable enough that the failure message names what is holding
    /// the device.
    private static let identity: String = {
        let target = Bundle.main.bundleIdentifier ?? "unknown-runner"
        let started = ISO8601DateFormatter().string(from: Date())
        return "\(target) started \(started)"
    }()

    private static var lockFile: URL {
        repositoryRoot
            .appendingPathComponent("build")
            .appendingPathComponent("TestRuns")
            .appendingPathComponent("\(deviceUDID).lock")
    }

    /// Single-threaded by construction: a UI test body runs on the runner's main
    /// thread, and every caller here is one.
    nonisolated(unsafe) private static var holds = false
    nonisolated(unsafe) private static var lastStamp = Date.distantPast
    nonisolated(unsafe) private static var lost: String?

    /// Whether it is safe to drive this simulator, claiming it the first time.
    ///
    /// Called before the *first* thing either target does to the device, which is
    /// `app.terminate()`. A run that cannot claim never touches the simulator at
    /// all — it does not terminate the holder's app, and it does not launch its
    /// own — so the run that does hold the device is unaffected by the one that
    /// tried.
    @discardableResult
    static func claim(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if let lost {
            XCTFail(lost, file: file, line: line)
            return false
        }
        if holds {
            heartbeat()
            return lost == nil
        }

        let file0 = lockFile
        if let held = liveHolder(at: file0) {
            lost = message(held: held)
            print("EXCLUSIVE-RUN-BLOCKED by \(held)")
            XCTFail(lost ?? "", file: file, line: line)
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: file0.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try identity.write(to: file0, atomically: true, encoding: .utf8)
        } catch {
            // A lock that cannot be written must not stop a run that is
            // otherwise fine — the guard is worth having and is not worth
            // becoming a new way to fail. Printed so a run without one says so.
            print("EXCLUSIVE-RUN-UNGUARDED: simulator lock unavailable")
            holds = true
            return true
        }
        holds = true
        lastStamp = Date()
        // Released when the runner exits, so the *next* run does not have to
        // wait out a staleness window that only exists for crashes. Measured
        // before this was here: two consecutive, entirely correct sequential
        // runs of the same test, the second starting seconds after the first
        // finished, and the second was refused by the first's abandoned claim.
        // A guard that fails an honest run is worse than the collision it
        // prevents, because the first thing anyone does with it is delete it.
        //
        // `atexit` rather than `tearDown`: a run is many test methods and only
        // the process knows when the last one is done. The closure captures
        // nothing — every piece of state here is static — which is what lets it
        // be `@convention(c)`.
        atexit { ExclusiveRun.release() }
        print("EXCLUSIVE-RUN-CLAIMED by \(identity)")
        return true
    }

    /// Drops this run's claim, if it is still this run's.
    ///
    /// Guarded by the read-back for the same reason `heartbeat` is: deleting a
    /// lock somebody else now holds would hand the device to a third run while
    /// the second is mid-sweep.
    static func release() {
        guard holds else { return }
        let url = lockFile
        guard (try? String(contentsOf: url, encoding: .utf8)) == identity else { return }
        try? FileManager.default.removeItem(at: url)
        holds = false
    }

    /// Re-stamps this run's claim, and notices if somebody took it.
    static func heartbeat() {
        guard holds, lost == nil, Date().timeIntervalSince(lastStamp) >= heartbeatEvery
        else { return }
        lastStamp = Date()

        let file0 = lockFile
        let current = try? String(contentsOf: file0, encoding: .utf8)
        guard current == identity else {
            lost = message(held: current ?? "nothing — the lock file was removed")
            print("EXCLUSIVE-RUN-LOST: now held by \(current ?? "nobody")")
            return
        }
        try? identity.write(to: file0, atomically: true, encoding: .utf8)
    }

    /// The identity in a lock that is still being stamped, if there is one.
    private static func liveHolder(at url: URL) -> String? {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        guard Date().timeIntervalSince(modified) < staleAfter else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "an unreadable lock"
    }

    private static func message(held: String) -> String {
        """
        Another test run is already driving this simulator: \(held). This run \
        has stopped before terminating or launching anything, so that run is \
        unharmed.

        Two runs on one simulator kill each other's app in setUp and the result \
        is "TEST FAILED" with no assertion output, which is why this check \
        exists. Give this run a destination of its own — \
        -destination 'platform=iOS Simulator,name=iPhone 17' and \
        'name=iPhone 17 Pro' are separate devices and run in parallel happily — \
        or wait for the other one to finish.

        The simulator lock expires \(Int(staleAfter))s after the run holding it \
        last polled, so a crashed run clears itself.
        """
    }
}

extension XCUIElement {

    /// Asserts this control clears the 44×44pt floor Apple's `hitRegion` audit
    /// checks and a fingertip needs.
    ///
    /// The floor is compared with a hundredth of a point of slack, and that is
    /// not a softened threshold. `frame(minHeight: 44)` on Ingestion's category
    /// filter comes back over the accessibility bridge as **43.99999999999997** —
    /// a float round-trip, three parts in 10^15 short. A bare `>= 44` fails on
    /// a control that is exactly the right size, which is the kind of red test
    /// that gets the assertion deleted rather than the app fixed. Anything
    /// genuinely undersized here was 14–22pt, so nothing real hides in 0.01.
    func assertMeetsMinimumHitTarget(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let floor = 44 - 0.01
        let frame = self.frame
        XCTAssertGreaterThanOrEqual(
            frame.width, floor,
            "\(what) is \(frame.width)pt wide; the floor is 44.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.height, floor,
            "\(what) is \(frame.height)pt tall; the floor is 44.",
            file: file,
            line: line
        )
    }
}
