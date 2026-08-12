import AppKit
import Foundation
import GetHogKit
import GetHogUI
import Testing

@testable import GetHog

/// Uses the app's complete synthetic demo responder for reads, but refuses the
/// one PATCH under test. Nothing here reaches a live PostHog project.
private actor FailingMenuBarFlagTransport: HTTPTransport {
    private let backing = DemoTransport()
    private(set) var patchCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: false) ?? ""
        if request.httpMethod == "PATCH", path.contains("/feature_flags/") {
            patchCount += 1
            return (
                Data(#"{"detail":"Synthetic flag refusal."}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        return try await backing.send(request)
    }
}

/// The menu bar extra's decisions, taken apart from the status item that shows
/// them. Everything here is either pure — which metric leads, how it reads, what
/// closing the last window means — or reads a store handed in by the test, so
/// nothing in this file mounts a `MenuBarExtra`, authenticates anybody, or
/// touches the app's real App Group container. The sighted half (the item
/// renders, the popover opens, the deep link lands) belongs to the Mac UI pass.

/// `@MainActor` for the two controller tests at the bottom: `UserDefaults` is
/// not `Sendable`, so a suite off the actor cannot hand one to a main-actor
/// initialiser. The pure tests above them neither need nor mind it.
@MainActor
@Suite("Menu bar headline")
struct MenuBarHeadlineTests {

    private static let authSessionID = UUID()

    private func snapshot(metrics: [SharedSnapshot.Metric]) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1,
            projectName: "P",
            metrics: metrics,
            flags: [],
            authSessionID: Self.authSessionID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func metric(
        _ id: String,
        value: Double = 10,
        unit: String? = nil,
        previous: Double? = nil
    ) -> SharedSnapshot.Metric {
        .init(
            id: id,
            title: "Metric \(id)",
            value: value,
            unit: unit,
            previous: previous,
            sparkline: [],
            dashboardID: nil
        )
    }

    @Test("an explicit choice outranks every watch")
    func chosenMetricWins() {
        let snapshot = snapshot(metrics: [metric("1"), metric("2")])
        let watches = [MetricWatch(id: "w", metricID: "1", title: "", condition: .above(1))]
        #expect(MenuBarHeadline.metric(in: snapshot, watches: watches, chosenID: "2")?.id == "2")
    }

    @Test("a choice the snapshot no longer carries falls back to the first watched metric")
    func staleChoiceFallsBackToWatch() {
        let snapshot = snapshot(metrics: [metric("1"), metric("2")])
        let watches = [MetricWatch(id: "w", metricID: "2", title: "", condition: .above(1))]
        #expect(MenuBarHeadline.metric(in: snapshot, watches: watches, chosenID: "gone")?.id == "2")
    }

    @Test("a disabled watch elects nothing")
    func disabledWatchIsSkipped() {
        let snapshot = snapshot(metrics: [metric("1"), metric("2")])
        let watches = [
            MetricWatch(id: "w", metricID: "2", title: "", condition: .above(1), isEnabled: false)
        ]
        #expect(MenuBarHeadline.metric(in: snapshot, watches: watches, chosenID: nil)?.id == "1")
    }

    @Test("a watch whose metric left the snapshot is skipped, not honoured blind")
    func orphanWatchIsSkipped() {
        let snapshot = snapshot(metrics: [metric("1")])
        let watches = [
            MetricWatch(id: "a", metricID: "gone", title: "", condition: .above(1)),
            MetricWatch(id: "b", metricID: "1", title: "", condition: .above(1)),
        ]
        #expect(MenuBarHeadline.metric(in: snapshot, watches: watches, chosenID: nil)?.id == "1")
    }

    @Test("no snapshot, or no metrics, means no headline")
    func emptyElection() {
        #expect(MenuBarHeadline.metric(in: nil, watches: [], chosenID: "1") == nil)
        #expect(
            MenuBarHeadline.metric(in: snapshot(metrics: []), watches: [], chosenID: nil) == nil
        )
    }

    @Test("values compact the way the widgets spell them")
    func compactSpelling() {
        #expect(MenuBarHeadline.compact(12_480) == "12.5K")
        #expect(MenuBarHeadline.compact(318) == "318")
        #expect(MenuBarHeadline.compact(41.2, unit: "%") == "41.2%")
        #expect(MenuBarHeadline.compact(8_640, unit: "$") == "$8.6K")
    }

    @Test("the label pairs the value with a trend glyph, and unknown gets none")
    func labelGlyphs() {
        #expect(MenuBarHeadline.label(for: metric("1", value: 1_234, previous: 1_000)) == "1.2K ↑")
        #expect(MenuBarHeadline.label(for: metric("1", value: 900, previous: 1_000)) == "900 ↓")
        #expect(MenuBarHeadline.label(for: metric("1", value: 1_000, previous: 1_000)) == "1K →")
        #expect(MenuBarHeadline.label(for: metric("1", value: 1_000, previous: nil)) == "1K")
    }

    @Test("the spoken form names the metric, because the strip is a bare number")
    func spokenLabel() {
        let spoken = MenuBarHeadline.accessibilityLabel(for: metric("1", value: 1_234))
        #expect(spoken == "GetHog: Metric 1, 1.2K")
        #expect(MenuBarHeadline.accessibilityLabel(for: nil) == "GetHog")
    }

    @Test("the controller reads the store it was handed and elects from it")
    func controllerReadsItsStore() throws {
        let store = try snapshotStore(holding: snapshot(metrics: [metric("42", value: 5)]))
        let controller = MacMenuBarController(
            store: store.store,
            defaults: defaults(),
            authSessionID: Self.authSessionID
        )
        #expect(controller.snapshot?.projectID == 1)
        #expect(controller.headline?.id == "42")
    }

    @Test("an adopted controller follows only later writes to its own snapshot file")
    func controllerObservesOwnedWrites() async throws {
        let owned = try snapshotStore(holding: snapshot(metrics: [metric("old")]))
        let other = try snapshotStore(holding: snapshot(metrics: [metric("other")]))
        let controller = MacMenuBarController(
            store: owned.store,
            defaults: defaults(),
            authSessionID: Self.authSessionID
        )
        #expect(controller.headline?.id == "old")

        // Stage a newer owned file without posting the store notification.
        // A notification for another injected store must not make the
        // controller discover it.
        let staged = snapshot(metrics: [metric("staged")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(staged).write(to: owned.store.fileURL, options: .atomic)
        controller.reload(afterSnapshotChangeAt: other.store.fileURL)
        #expect(controller.headline?.id == "old")

        // The real write path posts synchronously, while the controller hops
        // publication back to the main actor. Bound the wait well below the
        // 60-second fallback tick so deleting the subscription fails here.
        let replacement = snapshot(metrics: [metric("replacement")])
        try owned.store.write(replacement)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while controller.headline?.id != "replacement", clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.snapshot == replacement)
        #expect(controller.headline?.id == "replacement")
    }

    @Test("a chosen metric survives the process it was chosen in")
    func chosenMetricIsPersisted() throws {
        let store = try snapshotStore(holding: snapshot(metrics: [metric("1"), metric("2")]))
        // One defaults suite, two controllers: the second one is the relaunch.
        let defaults = defaults()
        let chooser = MacMenuBarController(
            store: store.store,
            defaults: defaults,
            authSessionID: Self.authSessionID
        )
        chooser.headlineMetricID = "2"

        let relaunched = MacMenuBarController(
            store: store.store,
            defaults: defaults,
            authSessionID: Self.authSessionID
        )
        #expect(relaunched.headline?.id == "2")
    }

    @Test("sign-out clears the in-memory snapshot and a new epoch cannot revive it")
    func authenticationEpochOwnsTheSnapshot() throws {
        let store = try snapshotStore(holding: snapshot(metrics: [metric("42")]))
        let controller = MacMenuBarController(
            store: store.store,
            defaults: defaults(),
            authSessionID: Self.authSessionID
        )
        #expect(controller.snapshot != nil)

        controller.adoptAuthSession(nil)
        #expect(controller.snapshot == nil)

        controller.adoptAuthSession(UUID())
        #expect(controller.snapshot == nil)
    }

    // MARK: Fixtures

    /// A suite of its own per test, for the reason `NavPreferencesTests` gives:
    /// these run in the same process as everything else in the target, and a
    /// test that wrote the real key would change the next reader's menu bar.
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "MenuBarHeadlineTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A real store over a throwaway directory — never the app's own container,
    /// which on a signed machine is shared with the running app.
    private func snapshotStore(holding snapshot: SharedSnapshot) throws -> TemporaryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("menubar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SharedSnapshotStore(directory: directory)
        try store.write(snapshot)
        return TemporaryStore(store: store)
    }

    /// Deletes its directory when the test's last reference to it goes.
    private final class TemporaryStore: Sendable {
        let store: SharedSnapshotStore

        init(store: SharedSnapshotStore) { self.store = store }

        deinit { try? FileManager.default.removeItem(at: store.directory) }
    }
}

@MainActor
@Suite("Menu bar refresh")
struct MacMenuBarRefreshTests {

    @Test("a failed refresh preserves the stale snapshot, reports failure, and re-enables Retry")
    func failurePreservesStaleSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMenuBarRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedSnapshotStore(directory: directory)
        let snapshot = SharedSnapshot(
            projectID: 1_001,
            projectName: "Example retained snapshot workspace",
            metrics: [],
            flags: [],
            projectRegion: .usCloud,
            authSessionID: Self.authSessionID,
            capturedAt: Date(timeIntervalSince1970: 1_754_000_000)
        )
        try store.write(snapshot)
        let snapshotController = MacMenuBarController(
            store: store,
            defaults: isolatedDefaults(),
            authSessionID: Self.authSessionID
        )
        let refresh = MacMenuBarRefreshController()

        await refresh.refresh(
            publish: { false },
            reload: { snapshotController.reload() }
        )

        #expect(snapshotController.snapshot == snapshot)
        #expect(refresh.state == .failed)
        #expect(!refresh.isRefreshing)
    }

    @Test("rapid refresh calls coalesce into one publication")
    func rapidRefreshCoalesces() async {
        let refresh = MacMenuBarRefreshController()
        let publication = HeldPublication()

        let leader = Task { @MainActor in
            await refresh.refresh(
                publish: { await publication.publish() },
                reload: {}
            )
        }
        await publication.waitUntilStarted()

        let follower = Task { @MainActor in
            await refresh.refresh(
                publish: { await publication.publish() },
                reload: {}
            )
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(publication.callCount == 1)
        publication.finish(returning: true)
        await leader.value
        await follower.value
        #expect(publication.callCount == 1)
    }

    @Test("success clears the prior failure")
    func successClearsFailure() async {
        let refresh = MacMenuBarRefreshController()

        await refresh.refresh(publish: { false }, reload: {})
        #expect(refresh.state == .failed)

        await refresh.refresh(publish: { true }, reload: {})
        #expect(refresh.state == .idle)
    }

    @Test("ready without a snapshot is unsynced, while onboarding still asks to connect")
    func emptyCopyDistinguishesSessionState() {
        let ready = MacMenuBarEmptyPresentation.resolve(
            phase: AppModel.Phase.ready,
            isRuntimeDemo: false,
            refreshState: .idle
        )
        #expect(ready.title == "No menu bar data yet")
        #expect(
            ready.message
                == "GetHog is connected, but no menu bar data has synced yet. Try Refresh."
        )
        #expect(ready.isRefreshEnabled)

        let onboarding = MacMenuBarEmptyPresentation.resolve(
            phase: AppModel.Phase.onboarding,
            isRuntimeDemo: false,
            refreshState: .idle
        )
        #expect(onboarding.title == "Connect GetHog")
        #expect(onboarding.message.contains("connect to PostHog"))
        #expect(!onboarding.isRefreshEnabled)

        let runtimeDemo = MacMenuBarEmptyPresentation.resolve(
            phase: AppModel.Phase.ready,
            isRuntimeDemo: true,
            refreshState: .idle
        )
        #expect(runtimeDemo.title == "Menu bar data stays live-only")
        #expect(runtimeDemo.message.lowercased().contains("demo data is not published"))
        #expect(!runtimeDemo.isRefreshEnabled)
    }

    private static let authSessionID = UUID(
        uuidString: "018f9000-0000-7000-8000-000000000601"
    )!

    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "MacMenuBarRefreshTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private final class HeldPublication {
        private(set) var callCount = 0
        private var result: Bool?
        private var continuations: [CheckedContinuation<Bool, Never>] = []

        func publish() async -> Bool {
            callCount += 1
            if let result { return result }
            return await withCheckedContinuation { continuations.append($0) }
        }

        func waitUntilStarted() async {
            while callCount == 0 { await Task.yield() }
        }

        func finish(returning result: Bool) {
            self.result = result
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume(returning: result) }
        }
    }
}

@Suite("Menu bar contract")
struct MenuBarContractTests {

    /// These strings are persisted (defaults keys) or read by another scene
    /// (window id, notification name); a rename is silent data loss or a dead
    /// deep link, so the exact spellings are pinned.
    @Test("the persisted and cross-scene names are stable")
    func storedNamesAreStable() {
        #expect(MacMenuBar.keepOnCloseKey == "menuBarKeepOnClose")
        #expect(MacMenuBar.headlineMetricKey == "menuBarHeadlineMetricID")
        #expect(MacMenuBar.mainWindowID == "main")
        #expect(MacMenuBar.pendingOpenNotification.rawValue == "app.gethog.mac.pendingOpen")
    }

    /// Spec §4 calls the popover a mini-dashboard, not a flags screen. The
    /// ceiling is what stops a project with forty opted-in flags from turning a
    /// glance into a scroll.
    @MainActor
    @Test("the quick-toggle list has a ceiling")
    func quickToggleCeiling() {
        #expect(MacMenuBarPopover.maximumQuickToggles == 5)
    }

    /// How old the popover admits its numbers are. Pinned even though the view
    /// around it cannot be mounted here, because a bucket that reads "Updated 0m
    /// ago" or rounds an hour down to nothing is the kind of wrong that looks
    /// like working software.
    @Test("the freshness caption buckets: now, minutes, hours, days")
    func freshnessBuckets() {
        #expect(WidgetFreshness.caption(forAge: 0) == "Updated just now")
        #expect(WidgetFreshness.caption(forAge: 59) == "Updated just now")
        #expect(WidgetFreshness.caption(forAge: 20 * 60) == "Updated 20m ago")
        #expect(WidgetFreshness.caption(forAge: 3 * 3_600) == "Updated 3h ago")
        #expect(WidgetFreshness.caption(forAge: 2 * 86_400) == "Updated 2d ago")
    }
}

/// What closing the last window means, as a truth table. `MacAppDelegate` is a
/// few lines around these two functions, and neither of the things it does can
/// be exercised here — one ends the process the test runs in and the other
/// mutates that process's Dock presence. Both were measured instead, against an
/// instrumented Debug build; see the delegate's own note.
@Suite("Menu bar window policy")
struct MenuBarWindowPolicyTests {

    @Test("quitting on the last close follows the keep toggle, inverted")
    func quitFollowsToggle() {
        #expect(MenuBarWindowPolicy.shouldTerminateAfterLastWindowClosed(keepInMenuBar: false))
        #expect(
            MenuBarWindowPolicy.shouldTerminateAfterLastWindowClosed(keepInMenuBar: true) == false
        )
    }

    @Test("accessory mode needs both the toggle and an empty screen")
    func accessoryNeedsBoth() {
        #expect(
            MenuBarWindowPolicy.activationPolicy(keepInMenuBar: true, visibleMainCapableWindows: 0)
                == .accessory
        )
        // A tear-off window left open is still a window; dropping the Dock icon
        // out from under it would strand it.
        #expect(
            MenuBarWindowPolicy.activationPolicy(keepInMenuBar: true, visibleMainCapableWindows: 1)
                == nil
        )
        #expect(
            MenuBarWindowPolicy.activationPolicy(keepInMenuBar: false, visibleMainCapableWindows: 0)
                == nil
        )
    }
}

/// Pure geometry around AppKit's state restoration. These expectations are
/// literal on purpose: each catches one missing edge clamp, while the style
/// cases keep the observer out of native window-management modes.
@Suite("Display-safe window placement")
struct MacWindowPlacementTests {

    private let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)

    @Test("a restored frame overflowing the right edge moves fully on-screen")
    func rightOverflow() {
        #expect(
            MacWindowPlacement.clampedFrame(
                CGRect(x: 800, y: 100, width: 300, height: 200),
                to: visibleFrame
            ) == CGRect(x: 700, y: 100, width: 300, height: 200)
        )
    }

    @Test("a restored frame overflowing the left edge moves fully on-screen")
    func leftOverflow() {
        #expect(
            MacWindowPlacement.clampedFrame(
                CGRect(x: -80, y: 100, width: 300, height: 200),
                to: visibleFrame
            ) == CGRect(x: 0, y: 100, width: 300, height: 200)
        )
    }

    @Test("a restored frame overflowing the top edge moves fully on-screen")
    func topOverflow() {
        #expect(
            MacWindowPlacement.clampedFrame(
                CGRect(x: 100, y: 600, width: 300, height: 200),
                to: visibleFrame
            ) == CGRect(x: 100, y: 500, width: 300, height: 200)
        )
    }

    @Test("a restored frame overflowing the bottom edge moves fully on-screen")
    func bottomOverflow() {
        #expect(
            MacWindowPlacement.clampedFrame(
                CGRect(x: 100, y: -50, width: 300, height: 200),
                to: visibleFrame
            ) == CGRect(x: 100, y: 0, width: 300, height: 200)
        )
    }

    @Test("a window larger than the display is reduced to its visible frame")
    func oversizedWindow() {
        #expect(
            MacWindowPlacement.clampedFrame(
                CGRect(x: -300, y: -200, width: 1_400, height: 900),
                to: visibleFrame
            ) == visibleFrame
        )
    }

    @Test("an already valid restored frame is unchanged")
    func validFrameIdentity() {
        let frame = CGRect(x: 120, y: 140, width: 640, height: 420)
        #expect(MacWindowPlacement.clampedFrame(frame, to: visibleFrame) == frame)
    }

    @Test("ordinary titled windows clamp without excluding native resize affordances")
    func ordinaryWindowStyle() {
        let ordinary: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        #expect(MacWindowPlacement.shouldClamp(styleMask: ordinary))
        #expect(MacWindowPlacement.shouldClamp(styleMask: ordinary.union(.fullSizeContentView)))
    }

    @Test("native full-screen and panel-style windows are excluded")
    func nativeWindowStyleExclusions() {
        let ordinary: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        #expect(MacWindowPlacement.shouldClamp(styleMask: ordinary.union(.fullScreen)) == false)
        #expect(MacWindowPlacement.shouldClamp(styleMask: ordinary.union(.utilityWindow)) == false)
        #expect(MacWindowPlacement.shouldClamp(styleMask: ordinary.union(.nonactivatingPanel)) == false)
        #expect(MacWindowPlacement.shouldClamp(styleMask: ordinary.union(.hudWindow)) == false)
        #expect(MacWindowPlacement.shouldClamp(styleMask: ordinary.union(.docModalWindow)) == false)
        #expect(MacWindowPlacement.shouldClamp(styleMask: .borderless) == false)
    }
}

@MainActor
@Suite("Mac window observer lifecycle")
struct MacWindowObserverLifecycleTests {

    @MainActor
    private final class Recorder {
        var scanCount = 0
        var scheduled: [@MainActor () -> Void] = []

        func scan() {
            scanCount += 1
        }

        func schedule(_ action: @escaping @MainActor () -> Void) {
            scheduled.append(action)
        }

        func runNext() {
            scheduled.removeFirst()()
        }
    }

    @Test("restoration finishing before launch completion still schedules one later scan")
    func restorationBeforeDidFinishIsObserved() {
        let center = NotificationCenter()
        let recorder = Recorder()
        let delegate = MacAppDelegate(
            notificationCenter: center,
            scheduleOnNextMainTurn: recorder.schedule,
            scanVisibleWindows: recorder.scan
        )
        let willFinish = Notification(name: NSApplication.willFinishLaunchingNotification)
        let didFinish = Notification(name: NSApplication.didFinishLaunchingNotification)

        delegate.applicationWillFinishLaunching(willFinish)
        delegate.applicationWillFinishLaunching(willFinish)

        #expect(delegate.registeredObserverCount == 4)
        #expect(recorder.scanCount == 0)

        center.post(name: NSApplication.didFinishRestoringWindowsNotification, object: nil)

        #expect(recorder.scanCount == 0)
        #expect(recorder.scheduled.count == 1)
        delegate.applicationDidFinishLaunching(didFinish)
        delegate.applicationDidFinishLaunching(didFinish)
        #expect(recorder.scanCount == 1)

        recorder.runNext()
        #expect(recorder.scanCount == 2)
        #expect(recorder.scheduled.isEmpty)
        #expect(delegate.registeredObserverCount == 4)
    }

    @Test("restoration finishing after launch completion schedules one later scan")
    func restorationAfterDidFinishIsObserved() {
        let center = NotificationCenter()
        let recorder = Recorder()
        let delegate = MacAppDelegate(
            notificationCenter: center,
            scheduleOnNextMainTurn: recorder.schedule,
            scanVisibleWindows: recorder.scan
        )
        let willFinish = Notification(name: NSApplication.willFinishLaunchingNotification)
        let didFinish = Notification(name: NSApplication.didFinishLaunchingNotification)

        delegate.applicationWillFinishLaunching(willFinish)
        delegate.applicationWillFinishLaunching(willFinish)
        delegate.applicationDidFinishLaunching(didFinish)
        delegate.applicationDidFinishLaunching(didFinish)

        #expect(delegate.registeredObserverCount == 4)
        #expect(recorder.scanCount == 1)

        center.post(name: NSApplication.didFinishRestoringWindowsNotification, object: nil)

        #expect(recorder.scanCount == 1)
        #expect(recorder.scheduled.count == 1)
        recorder.runNext()
        #expect(recorder.scanCount == 2)
        #expect(recorder.scheduled.isEmpty)
        #expect(delegate.registeredObserverCount == 4)
    }

    @Test("termination removes restoration with every other owned observer")
    func terminationRemovesObservers() {
        let center = NotificationCenter()
        let recorder = Recorder()
        let delegate = MacAppDelegate(
            notificationCenter: center,
            scheduleOnNextMainTurn: recorder.schedule,
            scanVisibleWindows: recorder.scan
        )
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        #expect(delegate.registeredObserverCount == 0)

        center.post(name: NSApplication.didFinishRestoringWindowsNotification, object: nil)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.post(name: NSWindow.willCloseNotification, object: nil)
        center.post(name: NSWindow.didBecomeMainNotification, object: nil)
        #expect(recorder.scheduled.isEmpty)
        #expect(recorder.scanCount == 1)
    }
}

/// The popover's write path. The gate is injected rather than run, so every
/// outcome `BiometricGate` can produce is exercised without a device-owner
/// prompt — and the point of the suite is that all three outcomes are handled
/// the way `FlagToggleController.setActive` handles them. The menu bar must not
/// be the one surface where a security setting is decoration.
@MainActor
@Suite("Menu bar flag toggling")
struct MenuBarFlagTogglerTests {

    private static let authSessionID = UUID()
    private static let currentScope = FlagWriteScope(
        projectID: 1_001,
        projectRegion: .usCloud,
        authSessionID: authSessionID
    )

    private func flag(allowed: Bool = true, active: Bool = true) -> SharedSnapshot.Flag {
        .init(id: 7, key: "new-onboarding", active: active, quickToggleAllowed: allowed)
    }

    /// The write the popover would have made, captured instead of made.
    @MainActor
    private final class Recorder {
        var writes: [(id: Int, active: Bool)] = []
        var currentScope: FlagWriteScope? = MenuBarFlagTogglerTests.currentScope
        var gateCalls = 0
    }

    @MainActor
    private final class HeldGate {
        private(set) var started = false
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

    @Test("a flag without the quick-toggle opt-in never reaches the dialog")
    func optInIsRequired() {
        let toggler = MacMenuBarFlagToggler()
        toggler.request(
            flag(allowed: false), scope: Self.currentScope, currentScope: Self.currentScope
        )
        #expect(toggler.pending == nil)
    }

    @Test("a request proposes the opposite of the current state")
    func requestProposesOpposite() {
        let toggler = MacMenuBarFlagToggler()
        toggler.request(flag(active: true), scope: Self.currentScope, currentScope: Self.currentScope)
        #expect(toggler.pending?.desiredActive == false)
        #expect(toggler.pending?.flag.key == "new-onboarding")
        #expect(toggler.pending?.scope == Self.currentScope)
    }

    @Test("a same-ID flag from another region cannot reach confirmation")
    func sameIDCrossRegionRequestIsDismissed() {
        let toggler = MacMenuBarFlagToggler()
        let staleScope = FlagWriteScope(
            projectID: 1_001,
            projectRegion: .euCloud,
            authSessionID: Self.authSessionID
        )

        toggler.request(flag(), scope: staleScope, currentScope: Self.currentScope)

        #expect(toggler.pending == nil)
    }

    @Test("a same-project snapshot from a previous authentication cannot reach confirmation")
    func sameProjectPreviousSessionIsDismissed() {
        let toggler = MacMenuBarFlagToggler()
        let staleScope = FlagWriteScope(
            projectID: Self.currentScope.projectID,
            projectRegion: Self.currentScope.projectRegion,
            authSessionID: UUID()
        )

        toggler.request(flag(), scope: staleScope, currentScope: Self.currentScope)

        #expect(toggler.pending == nil)
    }

    @Test("a stale request is rejected before authentication or PATCH")
    func staleRequestIsRejectedBeforeAuthentication() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        let current = FlagWriteScope(
            projectID: 1_001,
            projectRegion: .euCloud,
            authSessionID: Self.authSessionID
        )

        await toggler.confirm(
            request(flag()),
            currentScope: { current },
            isGateEnabled: true,
            gate: {
                recorder.gateCalls += 1
                return .passed
            }
        ) { id, active, _ in
            recorder.writes.append((id, active))
            return .changed
        }

        #expect(recorder.gateCalls == 0)
        #expect(recorder.writes.isEmpty)
        #expect(toggler.notice?.text.contains("project changed") == true)
    }

    @Test("a pending confirmation is dismissed when its project scope changes")
    func pendingRequestIsDismissedOnScopeChange() {
        let toggler = MacMenuBarFlagToggler()
        toggler.request(flag(), scope: Self.currentScope, currentScope: Self.currentScope)
        #expect(toggler.pending != nil)

        toggler.dismissStaleRequest(
            snapshotScope: Self.currentScope,
            currentScope: FlagWriteScope(
                projectID: 1_001,
                projectRegion: .euCloud,
                authSessionID: Self.authSessionID
            )
        )

        #expect(toggler.pending == nil)
    }

    @Test("the dialog dismissing before the write lands cannot swallow it")
    func dismissalCannotSwallowTheWrite() async throws {
        // The exact race this API shape exists to prevent. SwiftUI writes
        // `false` through the dialog's `isPresented` binding as part of the
        // same dispatch that runs the confirm button's action, and that setter
        // calls `cancel()`. So by the time the button's awaited body runs,
        // `pending` is already nil — and a `confirm` that read it there did
        // nothing at all, silently. Confirming with the request in hand is
        // immune, which is what this pins.
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        toggler.request(flag(active: true), scope: Self.currentScope, currentScope: Self.currentScope)
        let request = try #require(toggler.pending)

        toggler.cancel()
        #expect(toggler.pending == nil)

        await toggler.confirm(
            request, currentScope: { Self.currentScope }, isGateEnabled: false
        ) { id, active, scope in
            recorder.writes.append((id, active))
            #expect(scope == Self.currentScope)
            return .changed
        }
        #expect(recorder.writes.count == 1)
        #expect(recorder.writes.first?.active == false)
    }

    @Test("cancel takes the dialog down, and on its own writes nothing")
    func cancelClears() {
        // The Cancel button's whole job: `pending` going nil is what dismisses
        // the dialog, and no `confirm` follows it.
        let toggler = MacMenuBarFlagToggler()
        toggler.request(flag(), scope: Self.currentScope, currentScope: Self.currentScope)
        #expect(toggler.pending != nil)
        toggler.cancel()
        #expect(toggler.pending == nil)
    }

    @Test("with the gate off, confirm writes the requested state")
    func confirmWritesWithoutGate() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        await toggler.confirm(
            request(flag(active: true)),
            currentScope: { Self.currentScope },
            isGateEnabled: false
        ) { id, active, _ in
            recorder.writes.append((id, active))
            return .changed
        }
        #expect(recorder.writes.count == 1)
        #expect(recorder.writes.first?.id == 7)
        #expect(recorder.writes.first?.active == false)
        #expect(toggler.notice == nil)
    }

    @Test("a passed gate writes, and says nothing it does not need to")
    func passedGateWrites() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        await toggler.confirm(
            request(flag(active: false)),
            currentScope: { Self.currentScope },
            isGateEnabled: true,
            gate: { .passed }
        ) { id, active, _ in
            recorder.writes.append((id, active))
            return .changed
        }
        #expect(recorder.writes.map(\.active) == [true])
        #expect(toggler.notice == nil)
    }

    @Test("a denied gate blocks the write and says so")
    func deniedGateBlocks() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        await toggler.confirm(
            request(flag()),
            currentScope: { Self.currentScope },
            isGateEnabled: true,
            gate: { .denied("Authentication wasn't confirmed.") }
        ) { id, active, _ in
            recorder.writes.append((id, active))
            return .changed
        }
        #expect(recorder.writes.isEmpty)
        #expect(toggler.notice?.kind == .failure)
        #expect(toggler.notice?.text.contains("left unchanged") == true)
        #expect(toggler.notice?.text.contains("new-onboarding") == true)
    }

    @Test("an unavailable gate writes, with an honest notice — never a silent pass")
    func unavailableGateWritesWithNotice() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        await toggler.confirm(
            request(flag()),
            currentScope: { Self.currentScope },
            isGateEnabled: true,
            gate: { .unavailable("no enrolled biometry") }
        ) { id, active, _ in
            recorder.writes.append((id, active))
            return .changed
        }
        #expect(recorder.writes.count == 1)
        // Not a failure — the write happened. Drawn in the failure ink it would
        // say the opposite of what it means.
        #expect(toggler.notice?.kind == .notice)
        #expect(toggler.notice?.text.contains("confirmed by dialog only") == true)
    }

    @Test("a write already in flight refuses a second one")
    func inFlightRefusesASecondWrite() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        let pending = request(flag())
        // Re-entered from inside the first write, which is what a double-click
        // on a dialog button amounts to.
        await toggler.confirm(
            pending, currentScope: { Self.currentScope }, isGateEnabled: false
        ) { id, active, _ in
            recorder.writes.append((id, active))
            await toggler.confirm(
                pending, currentScope: { Self.currentScope }, isGateEnabled: false
            ) { id, active, _ in
                recorder.writes.append((id, active))
                return .changed
            }
            return .changed
        }
        #expect(recorder.writes.count == 1)
    }

    @Test("a project change while authentication is open blocks the stale same-ID PATCH")
    func projectChangeDuringAuthenticationBlocksWrite() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        let gate = HeldGate()
        let staleRequest = request(flag())

        let confirmation = Task {
            await toggler.confirm(
                staleRequest,
                currentScope: { recorder.currentScope },
                isGateEnabled: true,
                gate: { await gate.evaluate() }
            ) { id, active, _ in
                recorder.writes.append((id, active))
                return .changed
            }
        }
        await gate.waitUntilStarted()
        recorder.currentScope = FlagWriteScope(
            projectID: 1_001,
            projectRegion: .euCloud,
            authSessionID: Self.authSessionID
        )
        gate.finish(.passed)
        await confirmation.value

        #expect(recorder.writes.isEmpty)
        #expect(toggler.pending == nil)
        #expect(toggler.inFlightFlagID == nil)
        #expect(toggler.notice?.kind == .failure)
        #expect(toggler.notice?.text.contains("project changed") == true)
    }

    @Test("a failed PATCH preserves the published flag and returns the refusal")
    func failedPatchReturnsOutcomeAndPreservesSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMenuBarFlagTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = SharedSnapshotStore(directory: directory)
        let transport = FailingMenuBarFlagTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshots
        )
        try await model.connect(key: "synthetic-menu-key", region: .usCloud)
        let project = try #require(model.selectedProject)
        let before = SharedSnapshot(
            projectID: project.id,
            projectName: "Synthetic Menu Workspace",
            metrics: [],
            flags: [flag(active: true)],
            projectRegion: .usCloud,
            capturedAt: Date(timeIntervalSince1970: 1_754_000_000)
        )
        try snapshots.write(before)

        let outcome = await model.setFlag(id: 7, active: false)

        #expect(await transport.patchCount == 1)
        #expect(snapshots.loadOrNil() == before)
        if case .failed(let detail) = outcome {
            #expect(detail.contains("Synthetic flag refusal"))
        } else {
            Issue.record("a refused PATCH must return a failure outcome")
        }
    }

    @Test("a stale same-ID cross-region snapshot cannot PATCH the current project")
    func staleSameIDCrossRegionSnapshotCannotPatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMenuBarScopeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = SharedSnapshotStore(directory: directory)
        let transport = FailingMenuBarFlagTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshots
        )
        try await model.connect(key: "synthetic-menu-key", region: .usCloud)
        let project = try #require(model.selectedProject)
        let before = SharedSnapshot(
            projectID: project.id,
            projectName: "Synthetic Menu Workspace",
            metrics: [],
            flags: [flag(active: true)],
            projectRegion: .usCloud,
            capturedAt: Date(timeIntervalSince1970: 1_754_000_000)
        )
        try snapshots.write(before)
        let staleScope = FlagWriteScope(
            projectID: project.id,
            projectRegion: .euCloud,
            authSessionID: try #require(model.authSessionID)
        )

        let outcome = await model.setFlag(id: 7, active: false, expectedScope: staleScope)

        #expect(await transport.patchCount == 0)
        #expect(snapshots.loadOrNil() == before)
        if case .failed(let detail) = outcome {
            #expect(detail.contains("project changed"))
        } else {
            Issue.record("a stale snapshot scope must be rejected before PATCH")
        }
    }

    @Test("a previous authentication epoch cannot PATCH the same host and project")
    func staleAuthenticationEpochCannotPatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMenuBarAuthScopeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = SharedSnapshotStore(directory: directory)
        let transport = FailingMenuBarFlagTransport()
        let model = AppModel(
            store: InMemoryTokenStore(),
            transport: transport,
            snapshotStore: snapshots
        )
        try await model.connect(key: "synthetic-menu-key", region: .usCloud)
        let current = try #require(model.flagWriteScope)
        let staleScope = FlagWriteScope(
            projectID: current.projectID,
            projectRegion: current.projectRegion,
            authSessionID: UUID()
        )

        let outcome = await model.setFlag(id: 7, active: false, expectedScope: staleScope)

        #expect(await transport.patchCount == 0)
        if case .failed(let detail) = outcome {
            #expect(detail.contains("project changed"))
        } else {
            Issue.record("a stale authentication epoch must be rejected before PATCH")
        }
    }

    @Test("a failed write states the failure and re-enables the menu toggle")
    func failedWriteShowsNoticeAndReenablesToggle() async {
        let toggler = MacMenuBarFlagToggler()
        let original = flag(active: true)

        await toggler.confirm(
            request(original), currentScope: { Self.currentScope }, isGateEnabled: false
        ) { _, _, _ in
            .failed("Synthetic flag refusal.")
        }

        #expect(toggler.inFlightFlagID == nil)
        #expect(toggler.notice?.kind == .failure)
        #expect(toggler.notice?.text.contains("new-onboarding") == true)
        #expect(toggler.notice?.text.contains("unchanged") == true)
        #expect(toggler.notice?.text.contains("Synthetic flag refusal") == true)

        toggler.request(original, scope: Self.currentScope, currentScope: Self.currentScope)
        #expect(toggler.pending?.flag == original)
    }

    @Test("a new request clears the notice the last one left behind")
    func requestClearsNotice() async {
        let toggler = MacMenuBarFlagToggler()
        await toggler.confirm(
            request(flag()),
            currentScope: { Self.currentScope },
            isGateEnabled: true,
            gate: { .denied("nope") }
        ) { _, _, _ in .changed }
        #expect(toggler.notice != nil)
        toggler.request(flag(), scope: Self.currentScope, currentScope: Self.currentScope)
        #expect(toggler.notice == nil)
    }

    /// What the dialog's button closure holds: the request as it stood when the
    /// dialog was built, which is the only thing `confirm` is allowed to need.
    private func request(_ flag: SharedSnapshot.Flag) -> MacMenuBarFlagToggler.Request {
        .init(flag: flag, scope: Self.currentScope)
    }
}
