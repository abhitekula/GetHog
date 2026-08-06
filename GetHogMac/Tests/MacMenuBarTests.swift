import AppKit
import Foundation
import GetHogKit
import Testing

@testable import GetHog

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

    private func snapshot(metrics: [SharedSnapshot.Metric]) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1,
            projectName: "P",
            metrics: metrics,
            flags: [],
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
        let controller = MacMenuBarController(store: store.store, defaults: defaults())
        #expect(controller.snapshot?.projectID == 1)
        #expect(controller.headline?.id == "42")
    }

    @Test("a chosen metric survives the process it was chosen in")
    func chosenMetricIsPersisted() throws {
        let store = try snapshotStore(holding: snapshot(metrics: [metric("1"), metric("2")]))
        // One defaults suite, two controllers: the second one is the relaunch.
        let defaults = defaults()
        let chooser = MacMenuBarController(store: store.store, defaults: defaults)
        chooser.headlineMetricID = "2"

        let relaunched = MacMenuBarController(store: store.store, defaults: defaults)
        #expect(relaunched.headline?.id == "2")
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
        #expect(MenuBarFreshness.caption(forAge: 0) == "Updated just now")
        #expect(MenuBarFreshness.caption(forAge: 59) == "Updated just now")
        #expect(MenuBarFreshness.caption(forAge: 20 * 60) == "Updated 20m ago")
        #expect(MenuBarFreshness.caption(forAge: 3 * 3_600) == "Updated 3h ago")
        #expect(MenuBarFreshness.caption(forAge: 2 * 86_400) == "Updated 2d ago")
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

/// The popover's write path. The gate is injected rather than run, so every
/// outcome `BiometricGate` can produce is exercised without a device-owner
/// prompt — and the point of the suite is that all three outcomes are handled
/// the way `FlagToggleController.setActive` handles them. The menu bar must not
/// be the one surface where a security setting is decoration.
@MainActor
@Suite("Menu bar flag toggling")
struct MenuBarFlagTogglerTests {

    private func flag(allowed: Bool = true, active: Bool = true) -> SharedSnapshot.Flag {
        .init(id: 7, key: "new-onboarding", active: active, quickToggleAllowed: allowed)
    }

    /// The write the popover would have made, captured instead of made.
    @MainActor
    private final class Recorder {
        var writes: [(id: Int, active: Bool)] = []
    }

    @Test("a flag without the quick-toggle opt-in never reaches the dialog")
    func optInIsRequired() {
        let toggler = MacMenuBarFlagToggler()
        toggler.request(flag(allowed: false))
        #expect(toggler.pending == nil)
    }

    @Test("a request proposes the opposite of the current state")
    func requestProposesOpposite() {
        let toggler = MacMenuBarFlagToggler()
        toggler.request(flag(active: true))
        #expect(toggler.pending?.desiredActive == false)
        #expect(toggler.pending?.flag.key == "new-onboarding")
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
        toggler.request(flag(active: true))
        let request = try #require(toggler.pending)

        toggler.cancel()
        #expect(toggler.pending == nil)

        await toggler.confirm(request, isGateEnabled: false) { id, active in
            recorder.writes.append((id, active))
        }
        #expect(recorder.writes.count == 1)
        #expect(recorder.writes.first?.active == false)
    }

    @Test("cancel takes the dialog down, and on its own writes nothing")
    func cancelClears() {
        // The Cancel button's whole job: `pending` going nil is what dismisses
        // the dialog, and no `confirm` follows it.
        let toggler = MacMenuBarFlagToggler()
        toggler.request(flag())
        #expect(toggler.pending != nil)
        toggler.cancel()
        #expect(toggler.pending == nil)
    }

    @Test("with the gate off, confirm writes the requested state")
    func confirmWritesWithoutGate() async {
        let toggler = MacMenuBarFlagToggler()
        let recorder = Recorder()
        await toggler.confirm(request(flag(active: true)), isGateEnabled: false) { id, active in
            recorder.writes.append((id, active))
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
            request(flag(active: false)), isGateEnabled: true, gate: { .passed }
        ) { id, active in
            recorder.writes.append((id, active))
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
            isGateEnabled: true,
            gate: { .denied("Authentication wasn't confirmed.") }
        ) { id, active in
            recorder.writes.append((id, active))
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
            isGateEnabled: true,
            gate: { .unavailable("no enrolled biometry") }
        ) { id, active in
            recorder.writes.append((id, active))
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
        await toggler.confirm(pending, isGateEnabled: false) { id, active in
            recorder.writes.append((id, active))
            await toggler.confirm(pending, isGateEnabled: false) { id, active in
                recorder.writes.append((id, active))
            }
        }
        #expect(recorder.writes.count == 1)
    }

    @Test("a new request clears the notice the last one left behind")
    func requestClearsNotice() async {
        let toggler = MacMenuBarFlagToggler()
        await toggler.confirm(
            request(flag()), isGateEnabled: true, gate: { .denied("nope") }
        ) { _, _ in }
        #expect(toggler.notice != nil)
        toggler.request(flag())
        #expect(toggler.notice == nil)
    }

    /// What the dialog's button closure holds: the request as it stood when the
    /// dialog was built, which is the only thing `confirm` is allowed to need.
    private func request(_ flag: SharedSnapshot.Flag) -> MacMenuBarFlagToggler.Request {
        .init(flag: flag)
    }
}
