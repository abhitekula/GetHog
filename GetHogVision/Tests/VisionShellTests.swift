import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// The Vision shell's shape, pinned the way `MacShellTests` pins the Mac's:
/// against the static members `VisionRootView` publishes, so the sidebar's
/// contract can be asserted without mounting a view.
@MainActor
@Suite("Vision shell structure")
struct VisionShellStructureTests {

    /// A sidebar row — or one of the two loose slots — is a screen's only route
    /// on Vision, Settings included, since there is no `Settings` scene to
    /// reach it any other way. So the sidebar has to cover every screen, and
    /// cover each of them once.
    @Test("the sidebar lists every screen, Settings included, exactly once")
    func sidebarCoversEveryScreen() {
        let listed = VisionRootView.looseTabs
            + VisionRootView.sections.flatMap(\.tabs)
            + VisionRootView.utilityTabs
        #expect(Set(listed) == Set(AppTab.allCases))
        #expect(listed.count == Set(listed).count)
    }

    /// The one place this shell parts company with the Mac's.
    @Test("settings sits below the sections, not inside one — the iPad rule")
    func settingsIsUtility() {
        #expect(VisionRootView.utilityTabs == [.settings])
        #expect(!VisionRootView.sections.flatMap(\.tabs).contains(.settings))
    }

    @Test("search sits loose at the top, never inside a section")
    func searchIsLoose() {
        #expect(VisionRootView.looseTabs == [.search])
        #expect(!VisionRootView.sections.flatMap(\.tabs).contains(.search))
    }

    /// Fourth consumer of one source of truth, not a fourth copy of it.
    @Test("the sidebar's sections are AppTab's, not a copy")
    func sectionsAreTheSharedOnes() {
        #expect(VisionRootView.sections.map(\.id) == AppTab.sections.map(\.id))
    }
}

/// The cadence, asserted against `BackgroundRefreshPolicy`'s own functions
/// rather than against re-derived constants — the policy is the source of
/// truth, and a test that restates its numbers would pass while they drifted.
@Suite("Vision refresh schedule")
struct VisionRefreshScheduleTests {

    @Test("no credential stands the schedule down")
    func noCredentialStandsDown() {
        #expect(
            VisionRefreshSchedule.action(hasCredential: false, lastRefreshedAt: nil, now: .now)
                == .standDown
        )
    }

    @Test("with a credential the wake is asked for at the policy's own date")
    func scheduleFollowsThePolicy() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let last = now.addingTimeInterval(-60)
        #expect(
            VisionRefreshSchedule.action(hasCredential: true, lastRefreshedAt: last, now: now)
                == .schedule(
                    earliestBeginDate: BackgroundRefreshPolicy.earliestBeginDate(
                        lastRefreshedAt: last,
                        now: now
                    )
                )
        )
    }

    /// A never-refreshed install is the first launch after sign-in, which is
    /// exactly when the ambient surfaces have nothing to draw yet.
    @Test("a never-refreshed install still schedules")
    func firstScheduleHappens() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            VisionRefreshSchedule.action(hasCredential: true, lastRefreshedAt: nil, now: now)
                == .schedule(
                    earliestBeginDate: BackgroundRefreshPolicy.earliestBeginDate(
                        lastRefreshedAt: nil,
                        now: now
                    )
                )
        )
    }

    /// The Info.plist declares this string, `BGTaskScheduler` rejects anything
    /// else, and iOS and the Mac already use it — so a rename here is a silent
    /// registration failure and a feature that reads as two in the logs.
    @Test("the task identifier is the one iOS and the Mac already use")
    @MainActor
    func identifierIsShared() {
        #expect(VisionRefresh.taskIdentifier == "app.gethog.refresh.snapshot")
    }
}
