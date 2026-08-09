import Foundation
import GetHogKit
import Testing
import UIKit
@testable import GetHog

/// Pins the sidebar's vocabulary.
///
/// `TVDestination.rawValue` is a stored contract, not an implementation
/// detail: `TVRootView` keeps the selection in `@SceneStorage`, which persists
/// a string across a scene teardown, so a renamed case restores an Apple TV
/// onto a different screen than the one it was left on. Round-tripping every
/// case is what makes that a test failure rather than a bug report.
@MainActor
@Suite("TV destinations")
struct TVDestinationTests {

    @Test("the running tvOS host resolves the phone's exact App Group identifier")
    func hostRuntimeUsesSharedSnapshotAppGroup() throws {
        // `GetHogTVTests` is a hosted bundle. Checking `Bundle.main` first
        // makes this an assertion about the running TV app process, rather than
        // another source-file or plist inspection from a macOS test runner.
        #expect(Bundle.main.bundleIdentifier == "app.gethog.GetHog")
        #expect(SharedSnapshotStore.bundleAppGroupIdentifier == "group.app.gethog")
        #expect(
            SharedSnapshotStore.bundleAppGroupIdentifier
                == SharedSnapshotStore.appGroupIdentifier
        )
        let expectedDirectory = try #require(
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.app.gethog"
            )
        )
        #expect(SharedSnapshotStore.shared.isSharedContainer)
        #expect(
            SharedSnapshotStore.shared.directory.standardizedFileURL
                == expectedDirectory.standardizedFileURL
        )
    }

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

    @Test("losing the authenticated scope invalidates open details")
    func scopeLossInvalidatesOpenDetails() throws {
        let epoch = try #require(
            UUID(uuidString: "018f9000-0000-7000-8000-000000000001")
        )
        let scope = FlagWriteScope(
            projectID: 1_001,
            projectRegion: .usCloud,
            authSessionID: epoch
        )

        #expect(TVRootView.shouldResetOpenDetails(from: scope, to: nil))
    }

    @Test("the full authority namespace invalidates open details")
    func fullAuthorityReplacementInvalidatesOpenDetails() throws {
        let firstEpoch = try #require(
            UUID(uuidString: "018f9000-0000-7000-8000-000000000001")
        )
        let replacementEpoch = try #require(
            UUID(uuidString: "018f9000-0000-7000-8000-000000000002")
        )
        let original = FlagWriteScope(
            projectID: 1_001,
            projectRegion: .usCloud,
            authSessionID: firstEpoch
        )

        #expect(
            TVRootView.shouldResetOpenDetails(
                from: original,
                to: FlagWriteScope(
                    projectID: 1_001,
                    projectRegion: .usCloud,
                    authSessionID: replacementEpoch
                )
            )
        )
        #expect(
            TVRootView.shouldResetOpenDetails(
                from: original,
                to: FlagWriteScope(
                    projectID: 1_001,
                    projectRegion: .euCloud,
                    authSessionID: firstEpoch
                )
            )
        )
        #expect(!TVRootView.shouldResetOpenDetails(from: original, to: original))
    }

    @Test("the ambient row carries its own title rather than an empty one")
    func ambientIsLabelled() {
        // `title` and `systemImage` fall back through `tab`, which is nil here.
        // An empty label is a sidebar row nobody can read or focus by name.
        #expect(TVDestination.ambient.title == "Ambient")
        #expect(!TVDestination.ambient.systemImage.isEmpty)
    }

    @Test("the running TV host contains the shared dashboard empty illustration")
    func hostBundlesDashboardEmptyIllustration() throws {
        #expect(Bundle.main.bundleIdentifier == "app.gethog.GetHog")
        let image = try #require(
            UIImage(
                named: "BrandEmptyDashboard",
                in: Bundle.main,
                compatibleWith: nil
            )
        )
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
