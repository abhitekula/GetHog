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

    /// The authored phone bar ordinary demo assertions measure.
    ///
    /// `NavPreferences` correctly persists a reader's edited bar in standard
    /// defaults, which also means a simulator can carry that edit into a later
    /// test run. Pinning the default through the existing DEBUG launch seam
    /// keeps unrelated tests independent; customization tests replace this
    /// value through `environment` below.
    private static let defaultTabBar = "dashboards,events,sessions,flags"

    /// The authored session the demo player actually plays.
    ///
    /// `DemoTransport` answers any session id with the first row of
    /// `session_recordings.json`, and this is that row — it is also the only
    /// session with a Replay Vision summary, so the whole detail screen is populated.
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
        environment: [String: String] = [:],
        extraArguments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        precondition(tab == nil || openURL == nil, "GETHOG_TAB overrules GETHOG_OPEN_URL.")

        // Before anything is terminated or launched — see `ExclusiveRun`.
        guard ExclusiveRun.claim(file: file, line: line) else { return XCUIApplication() }

        let app = XCUIApplication()
        app.launchArguments = ["-GetHogDemo"] + extraArguments
        // watchOS 26.5 can launch the requested page from launchEnvironment
        // while dropping the sibling process argument before the watch app
        // starts. Send both public demo signals: every platform accepts the
        // argument, and WatchDemoMode deliberately accepts this environment
        // spelling for XCUITest and simctl launches.
        if let tab { app.launchEnvironment["GETHOG_TAB"] = tab }
        if let openURL { app.launchEnvironment["GETHOG_OPEN_URL"] = openURL }
        app.launchEnvironment["GETHOG_TAB_BAR"] = defaultTabBar
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launchEnvironment["GETHOG_DEMO"] = "1"
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

    /// Starts the same configured demo application from a clean process state.
    /// The existing arguments and launch environment stay attached to the
    /// `XCUIApplication`, while any split-view selection from a context-menu
    /// interaction is discarded.
    @MainActor
    static func relaunch(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.terminate()
        app.launch()
        XCTAssertTrue(
            waitForScreen(app),
            "App never reached a rendered screen after a clean demo relaunch.",
            file: file,
            line: line
        )
    }

    /// Whether a real screen came up.
    ///
    /// `AppModel.phase` is `.loading` until `bootstrap()` has resolved the user
    /// and the project, and that phase draws a bare `ProgressView` with no
    /// navigation container at all — so the first navigation bar is the signal
    /// that the app is past it and a screen is rendered.
    ///
    /// The Mac shell has no navigation bars — `TabView(.sidebarAdaptable)`
    /// renders a sidebar instead — so there the signal is the first primary
    /// destination that sidebar offers, which nothing before the shell draws.
    ///
    /// Scoped to the app's *windows*, because the menu bar carries the same
    /// word: Go ▸ Dashboards is in the accessibility tree before the shell
    /// mounts, disabled menu items are in it too, and an app-wide match would
    /// therefore return this gate on the menu rather than on a rendered screen.
    /// On macOS the menu bar is `app.menuBars`, a sibling of `app.windows`
    /// under the application element, so scoping to windows excludes it.
    ///
    /// Windows rather than `app.outlines`, which is what `MacNavigationTests`
    /// scopes its *clicks* to. That helper can afford the narrower query
    /// because it keeps an app-wide fallback behind it; a gate has nowhere to
    /// fall back to, and if the sidebar ever stopped surfacing as an outline
    /// this would time out twice and fail pointing at the app rather than at
    /// the query. Excluding the menu bar is the whole requirement here, and
    /// windows is the weakest scope that does it.
    private static func waitForScreen(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        #if os(macOS)
        wait(for: app.windows.descendants(matching: .any)
            .matching(macTextPredicate("Dashboards"))
            .firstMatch,
            timeout: timeout
        )
        #elseif os(tvOS)
        // A tvOS shell draws no navigation bar at all — `TVRootView` is a
        // `.sidebarAdaptable` sidebar over `TVDestination`, and the roots below it
        // build their compact, one-column shape. The gate is therefore the first
        // sidebar destination, which is also the default selection and which nothing
        // before the shell draws: `TVKeyEntryView` says "Connect this Apple TV to
        // PostHog" and the loading phase draws a bare `ProgressView`.
        wait(for: app.staticTexts["Dashboards"].firstMatch, timeout: timeout)
        #else
        wait(for: app.navigationBars.firstMatch, timeout: timeout)
        #endif
    }

    #if os(macOS)
    /// Matches a Mac element carrying the text as **either** its label or its
    /// value.
    ///
    /// The distinction is not cosmetic and it is not a choice this suite makes.
    /// A SwiftUI sidebar row on macOS lands in the accessibility tree as a
    /// `StaticText` whose text is its **`value`** and whose `label` is empty,
    /// while the section headers above it — `Analyze`, `Monitor` — carry theirs
    /// as `label`. Measured from the real tree:
    ///
    ///     OutlineRow → Cell → StaticText, value: Dashboards
    ///     OutlineRow → Cell → Group → StaticText, label: 'Analyze'
    ///
    /// So a `label ==` predicate matches the headings and never the
    /// destinations. Every Mac query in these targets was written that way,
    /// which is why the launch gate timed out on a window that had rendered
    /// perfectly — the sidebar was there, and the query could not see it.
    ///
    /// macOS-only on purpose: on iOS a `value` is often a control's state
    /// ("1 of 5", "on"), so widening the predicate there would match things a
    /// label-based query deliberately does not.
    static func macTextPredicate(_ text: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR value == %@", text, text)
    }
    #endif

    /// The element types a Mac screen puts demo content on, cheapest first.
    ///
    /// `.any` is deliberately not among them, and that is a measurement rather
    /// than a preference: a compound `CONTAINS` predicate over
    /// `descendants(matching: .any)` on a table-heavy screen — Events — makes
    /// XCUITest give up with "Failed to get matching snapshots: Timed out while
    /// evaluating UI query" after nearly two minutes, before it ever reaches the
    /// row. These three cover what the screens actually produce:
    ///
    ///   - `.button` — a row that combined its children, carrying them as one
    ///     **`label`** ("Alex Example, duration 0:10, 1 clicks");
    ///   - `.cell` — the outline row either of the others may sit in;
    ///   - `.staticText` — a plain `Text`, carrying its words as **`value`**.
    ///
    /// Containers come before leaves, and the order is load-bearing rather than
    /// arbitrary. A caller that finds a row usually wants to *click* it, and a
    /// right-click on the `StaticText` inside a row does not open the row's
    /// context menu — measured: the dashboard row's menu never appeared while
    /// the title text was what matched, and appeared as soon as the row did.
    /// Screens whose anchor is prose and not a row still match on the leaf,
    /// because neither container carries the words.
    #if os(macOS)
    static let macContentTypes: [XCUIElement.ElementType] = [.button, .cell, .staticText]

    /// Polls every content type for an element whose label *or* value contains
    /// the text, and returns the first that appears.
    ///
    /// One deadline covers all three queries rather than each getting its own,
    /// so a screen that never renders costs the caller one timeout, not three.
    static func waitForContent(
        containing text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 30
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for type in macContentTypes {
                // Built inside the loop rather than hoisted: `NSPredicate` is
                // not `Sendable`, and hoisting it across the query call is what
                // Swift 6 flags as a data race.
                let match = app.windows.descendants(matching: type)
                    .matching(NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@", text, text
                    ))
                    .firstMatch
                if match.exists { return match }
            }
        }
        return nil
    }
    #endif

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

    /// Polls a condition instead of sleeping through it.
    ///
    /// The sibling of `wait(for:)` for the cases where what is being waited on
    /// is not an element appearing — a window resizing, a label changing, a
    /// count settling. Same polling shape and the same reason for it: a failing
    /// XCTest wait captures a full element debug description on every retry, and
    /// enough of those end the run rather than failing a test.
    ///
    /// Returns whether the condition held before the deadline, so a caller can
    /// fail with its own message rather than on a generic timeout.
    @discardableResult
    static func wait(
        timeout: TimeInterval = 15,
        until condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.25)
        }
        return condition()
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
            // AppKit spells a busy `ProgressView` as a progress indicator, not
            // an activity indicator, so each platform polls its own name.
            #if os(macOS)
            if !app.progressIndicators.firstMatch.exists { break }
            #else
            if !app.activityIndicators.firstMatch.exists { break }
            #endif
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
        #if os(macOS)
        // See `macTextPredicate`: on the Mac the text of a plain `Text` is its
        // value, not its label, so a label-only query here misses exactly the
        // elements these assertions are about.
        return app.descendants(matching: .any).matching(macTextPredicate(label))
        #else
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
        #endif
    }

    /// The first rendered element whose authored accessibility identifier has
    /// the supplied prefix. Quick Preview rows and cards append their stable
    /// synthetic object id, so tests select the product contract without
    /// copying fixture identifiers into their query mechanics.
    @MainActor
    static func element(
        in app: XCUIApplication,
        identifierStartingWith prefix: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// The first real row button whose combined semantic label contains text.
    /// Some list rows predate authored row identifiers; their visible fixture
    /// identity is still exposed by the NavigationLink button itself.
    @MainActor
    static func element(
        in app: XCUIApplication,
        labelContaining text: String
    ) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// The semantic content of a custom context-menu preview.
    ///
    /// SwiftUI authors a stable identifier on each preview card. iOS 26.5's
    /// context-menu host preserves that identifier when it can, but can also
    /// replace the hosted subtree with a system `Preview` container whose only
    /// exposed child is the card's combined accessibility label. Prefer the
    /// authored contract and fall back to that measured system representation.
    @MainActor
    static func quickPreview(
        in app: XCUIApplication,
        identifierStartingWith prefix: String,
        containing _: String
    ) -> XCUIElement {
        let authored = element(in: app, identifierStartingWith: prefix)
        if authored.exists { return authored }

        return previewHost(in: app)
    }

    /// iOS 26.5's generic host when it does not preserve the authored preview
    /// subtree in UI automation.
    @MainActor
    static func previewHost(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Preview"))
            .firstMatch
    }

    /// The system-owned collection that contains one authored context-menu
    /// action. Scoping negative assertions here excludes controls on the
    /// dimmed detail view behind an iPad popover.
    @MainActor
    static func contextMenu(
        in app: XCUIApplication,
        containingAction action: String
    ) -> XCUIElement {
        app.collectionViews
            .containing(.button, identifier: action)
            .firstMatch
    }
}

/// Data-free live-surface state shared by the iOS, Vision, TV, and Watch UI
/// targets. Product-authored identifiers and controls are the only witnesses:
/// no customer title, event, flag, or project value is read or logged.
@MainActor
enum LiveSurfaceState {
    static func waitForTerminalState(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasFailure(in: app) { return false }
            if !isLoading(in: app) {
                // Require a second quiet sample. A spinner can disappear one
                // frame before a failure or terminal body joins the AX tree.
                DemoLaunch.pause(0.25)
                if hasFailure(in: app) { return false }
                if !isLoading(in: app) { return true }
            }
            DemoLaunch.pause(0.25)
        }
        return false
    }

    private static func isLoading(in app: XCUIApplication) -> Bool {
        app.activityIndicators.firstMatch.exists
            || element("gethog.load-state.loading", in: app).exists
            || element("gethog.warehouse-loading", in: app).exists
    }

    private static func hasFailure(in app: XCUIApplication) -> Bool {
        element("gethog.load-state.failure", in: app).exists
            || app.buttons["Try again"].exists
            || app.buttons["Retry"].exists
    }

    private static func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
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

    /// Set when the lock file could not be written, so this run proceeds with
    /// no guard at all.
    ///
    /// It has to be remembered rather than inferred, because the two states are
    /// otherwise indistinguishable from inside `heartbeat`: "there is no lock
    /// file because this run never managed to write one" reads exactly like
    /// "there is no lock file because somebody took it and left", and the
    /// second is a failure while the first is the degradation `claim` chose
    /// deliberately. Without this, the graceful path defeated itself — every
    /// test after the first failed claiming the device had been stolen.
    ///
    /// The macOS UI runner is what exposed it: it is sandboxed and cannot write
    /// into the repository's `build/`, so it takes this path on every run.
    nonisolated(unsafe) private static var unguarded = false

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
            unguarded = true
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
        guard holds, !unguarded else { return }
        let url = lockFile
        guard (try? String(contentsOf: url, encoding: .utf8)) == identity else { return }
        try? FileManager.default.removeItem(at: url)
        holds = false
    }

    /// Re-stamps this run's claim, and notices if somebody took it.
    static func heartbeat() {
        // An unguarded run has no lock to re-stamp and no claim to lose; the
        // absence of the file is its normal state, not a theft.
        guard holds, !unguarded, lost == nil,
              Date().timeIntervalSince(lastStamp) >= heartbeatEvery
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
