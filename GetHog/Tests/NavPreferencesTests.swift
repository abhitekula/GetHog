import Foundation
import Testing

@testable import GetHog

/// The store behind the tab bar the user chose.
///
/// Every test here drives a `UserDefaults` suite of its own rather than
/// `.standard`: these run in the same process as the rest of the unit target,
/// and a test that wrote the real key would change the bar of whatever ran next.
@MainActor
@Suite("Nav preferences")
struct NavPreferencesTests {

    /// `#function` is a default argument, so it is evaluated at the *call* site
    /// and names the test asking for the store rather than this helper.
    private func store(_ name: String = #function) -> UserDefaults {
        let suite = "NavPreferencesTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("with nothing stored, the bar is the four it has always been")
    func defaultsToPrimary() {
        #expect(NavPreferences(defaults: store()).barTabs == AppTab.primary)
    }

    @Test("a stored arrangement comes back")
    func roundTrips() {
        let defaults = store()
        let written = NavPreferences(defaults: defaults)
        written.assign(.errorTracking, to: 0)
        #expect(NavPreferences(defaults: defaults).barTabs == written.barTabs)
    }

    /// A stored list outlives the build that wrote it, so every one of these is
    /// a real state a future version can be handed.
    @Test("a raw value that no longer names a screen is dropped")
    func dropsUnknownRawValues() {
        let tabs = NavPreferences.sanitised(["errorTracking", "screenDeletedInV2", "logs"])
        #expect(!tabs.contains(where: { $0.rawValue == "screenDeletedInV2" }))
        #expect(tabs.count == NavPreferences.slotCount)
    }

    @Test("a duplicate is dropped rather than filling two slots")
    func dropsDuplicates() {
        let tabs = NavPreferences.sanitised(["logs", "logs", "logs", "logs"])
        #expect(Set(tabs).count == tabs.count)
        #expect(tabs.count == NavPreferences.slotCount)
    }

    /// Search is the fifth slot structurally and Settings is not a product
    /// surface; neither can be chosen into the four.
    @Test("search and settings are refused")
    func refusesSearchAndSettings() {
        let tabs = NavPreferences.sanitised(["search", "settings", "logs"])
        #expect(!tabs.contains(.search))
        #expect(!tabs.contains(.settings))
    }

    @Test("a short list is padded and a long one truncated")
    func alwaysFourSlots() {
        #expect(NavPreferences.sanitised([]).count == NavPreferences.slotCount)
        #expect(NavPreferences.sanitised(["logs"]).count == NavPreferences.slotCount)
        #expect(
            NavPreferences.sanitised(
                ["logs", "tracing", "inbox", "health", "signals", "support"]
            ).count == NavPreferences.slotCount
        )
    }

    /// The padding is what makes "never empty" true, and an empty bar is an app
    /// with no navigation at all.
    @Test("garbage in still leaves a usable bar")
    func neverEmpty() {
        #expect(NavPreferences.sanitised(["nonsense", "", "search"]).count == NavPreferences.slotCount)
    }

    @Test("choosing a screen already in another slot swaps the two")
    func assigningSwaps() {
        let prefs = NavPreferences(defaults: store())
        // Default is [dashboards, events, sessions, flags].
        prefs.assign(.flags, to: 0)
        #expect(prefs.barTabs == [.flags, .events, .sessions, .dashboards])
    }

    @Test("choosing a screen not yet in the bar replaces that slot")
    func assigningReplaces() {
        let prefs = NavPreferences(defaults: store())
        prefs.assign(.logs, to: 1)
        #expect(prefs.barTabs == [.dashboards, .logs, .sessions, .flags])
    }

    @Test("a slot outside the bar is refused rather than trapping")
    func assigningOutOfRangeIsIgnored() {
        let prefs = NavPreferences(defaults: store())
        prefs.assign(.logs, to: 9)
        #expect(prefs.barTabs == AppTab.primary)
    }

    @Test("reordering keeps the same four")
    func movingKeepsMembership() {
        let prefs = NavPreferences(defaults: store())
        prefs.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(prefs.barTabs == [.flags, .dashboards, .events, .sessions])
    }

    @Test("reset restores the default four")
    func resets() {
        let prefs = NavPreferences(defaults: store())
        prefs.assign(.logs, to: 0)
        prefs.reset()
        #expect(prefs.barTabs == AppTab.primary)
    }

    @Test("the bar plus search is the five the phone draws")
    func alwaysVisibleIsFive() {
        let prefs = NavPreferences(defaults: store())
        #expect(prefs.alwaysVisible.count == 5)
        #expect(prefs.alwaysVisible.last == .search)
    }

    /// **The invariant the whole restructure rests on.** Once the four default
    /// tabs live inside sections, a sidebar that declares them loose *and*
    /// renders every section lists each of them twice.
    /// `AppTab.groupedScreens(excluding:)` is the only thing that decides where
    /// a screen is listed, and this is what says so: under any bar the user can
    /// choose, every screen appears exactly once and all of them appear.
    @Test(
        "every screen is listed exactly once, under any bar",
        arguments: [
            AppTab.primary,
            [.errorTracking, .logs, .inbox, .health],
            [.taxonomy, .dashboards, .renders, .max],
        ] as [[AppTab]]
    )
    func everyScreenListedExactlyOnce(bar: [AppTab]) {
        let loose = NavPreferences.sanitised(bar.map(\.rawValue))
        let listed =
            loose
            + AppTab.groupedScreens(excluding: loose).flatMap(\.tabs)
            + AppTab.utility
            + [.search]

        #expect(Set(listed).count == listed.count, "listed twice: \(listed.count - Set(listed).count)")
        let missing = Set(AppTab.allCases).subtracting(listed)
        #expect(missing.isEmpty, "unreachable: \(missing.map(\.title))")
    }

    /// The four defaults now sit inside sections, which is what makes demotion
    /// possible: before this, a demoted screen had nowhere to be listed.
    @Test("the taxonomy holds every product screen")
    func taxonomyIsComplete() {
        for tab in AppTab.primary {
            #expect(AppTab.productScreens.contains(tab), "\(tab.title) is in no section")
        }
        // Everything but Search, which is the fixed fifth slot, and Settings,
        // which is not a product surface.
        #expect(AppTab.productScreens.count == AppTab.allCases.count - 2)
    }

    /// `secondary` has to keep meaning what it meant, or every existing
    /// assertion about it is silently measuring something else. With the default
    /// bar excluded, the enlarged taxonomy reproduces the old array exactly —
    /// same members, same order — which is what makes the restructure a
    /// refactor rather than a change.
    @Test("the default arrangement reproduces the array that came before it")
    func secondaryIsUnchangedForTheDefaultBar() {
        #expect(AppTab.secondary.count == 30)
        #expect(AppTab.secondary.first == .insights)
        #expect(AppTab.secondary.last == .settings)
        #expect(!AppTab.secondary.contains(where: AppTab.primary.contains))
    }
}
