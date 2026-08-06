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
}
