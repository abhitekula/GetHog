import Foundation
import Testing
@testable import GetHog

/// Pins the sidebar's vocabulary.
///
/// `TVDestination.rawValue` is a stored contract, not an implementation
/// detail: `TVRootView` keeps the selection in `@SceneStorage`, which persists
/// a string across a scene teardown, so a renamed case restores an Apple TV
/// onto a different screen than the one it was left on. Round-tripping every
/// case is what makes that a test failure rather than a bug report.
@Suite("TV destinations")
struct TVDestinationTests {

    @Test("every destination survives the round trip scene restoration makes")
    func rawValueRoundTrip() {
        for destination in TVDestination.allCases {
            #expect(TVDestination(rawValue: destination.rawValue) == destination)
        }
    }

    @Test("an unknown stored value is not mistaken for a destination")
    func unknownRawValue() {
        // `TVRootView` falls back to `.dashboards` when this returns nil. That
        // fallback is only reachable if the initialiser actually refuses —
        // an enum that accepted anything would restore onto a blank tab.
        #expect(TVDestination(rawValue: "web") == nil)
        #expect(TVDestination(rawValue: "") == nil)
    }

    @Test("ambient is the one destination with no shared tab behind it")
    func ambientHasNoTab() {
        #expect(TVDestination.ambient.tab == nil)
        for destination in TVDestination.allCases where destination != .ambient {
            #expect(destination.tab != nil)
        }
    }

    @Test("each product destination names the tab whose root the shell mounts")
    func productDestinationsMapToTheirTabs() {
        #expect(TVDestination.dashboards.tab == .dashboards)
        #expect(TVDestination.insights.tab == .insights)
        #expect(TVDestination.events.tab == .events)
        #expect(TVDestination.sessions.tab == .sessions)
        #expect(TVDestination.flags.tab == .flags)
        #expect(TVDestination.settings.tab == .settings)
    }

    @Test("no two destinations claim the same tab")
    func tabsAreNotDuplicated() {
        // Two rows resolving to one root would put the same screen in the
        // sidebar twice, and `@SceneStorage` would restore onto whichever the
        // switch happened to reach first.
        let tabs = TVDestination.allCases.compactMap(\.tab)
        #expect(Set(tabs).count == tabs.count)
    }

    @Test("the ambient row carries its own title rather than an empty one")
    func ambientIsLabelled() {
        // `title` and `systemImage` fall back through `tab`, which is nil here.
        // An empty label is a sidebar row nobody can read or focus by name.
        #expect(TVDestination.ambient.title == "Ambient")
        #expect(!TVDestination.ambient.systemImage.isEmpty)
    }
}
