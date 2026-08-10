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

    @Test("the shell-embedded split candidates are every regular split except Dashboards")
    func shellEmbeddedSplitCandidatesAreExplicit() {
        let expected: Set<AppTab> = [
            .events, .sessions, .flags, .people, .errorTracking, .insights,
        ]

        #expect(VisionRootView.shellEmbeddedSplitTabs == expected)
        #expect(!VisionRootView.shellEmbeddedSplitTabs.contains(.dashboards))
    }

    @Test("restored scenes win; genuinely new scenes use the durable selection")
    func restorationSourceIsUnambiguous() {
        #expect(
            VisionRootView.restoredTab(
                sceneTab: .surveys,
                sceneInitialized: true,
                durableRawValue: AppTab.flags.rawValue
            ) == .surveys
        )
        #expect(
            VisionRootView.restoredTab(
                sceneTab: .dashboards,
                sceneInitialized: false,
                durableRawValue: AppTab.flags.rawValue
            ) == .flags
        )
        #expect(
            VisionRootView.restoredTab(
                sceneTab: .dashboards,
                sceneInitialized: false,
                durableRawValue: "not-a-tab"
            ) == .dashboards
        )
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

        #expect(VisionRootView.shouldResetOpenDetails(from: scope, to: nil))
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
            VisionRootView.shouldResetOpenDetails(
                from: original,
                to: FlagWriteScope(
                    projectID: 1_001,
                    projectRegion: .usCloud,
                    authSessionID: replacementEpoch
                )
            )
        )
        #expect(
            VisionRootView.shouldResetOpenDetails(
                from: original,
                to: FlagWriteScope(
                    projectID: 1_001,
                    projectRegion: .euCloud,
                    authSessionID: firstEpoch
                )
            )
        )
        #expect(!VisionRootView.shouldResetOpenDetails(from: original, to: original))
    }

    @Test("each product screen selects the section that contains it")
    func productScreensSelectTheirSection() {
        for section in VisionRootView.sections {
            for tab in section.tabs {
                #expect(
                    VisionRootView.destinationID(for: tab) == "section.\(section.title)",
                    "\(tab) did not map to its containing section."
                )
            }
        }
        #expect(VisionRootView.destinationID(for: .search) == AppTab.search.rawValue)
        #expect(VisionRootView.destinationID(for: .settings) == AppTab.settings.rawValue)
    }

    @Test("entering a section keeps its current screen or chooses its first row")
    func enteringSectionResolvesAVisibleScreen() {
        #expect(
            VisionRootView.resolvedTab(
                forDestinationID: AppTab.search.rawValue,
                current: .dashboards
            ) == .search
        )
        #expect(
            VisionRootView.resolvedTab(
                forDestinationID: AppTab.settings.rawValue,
                current: .dashboards
            ) == .settings
        )

        for section in VisionRootView.sections {
            let destinationID = "section.\(section.title)"
            let outside = AppTab.allCases.first { !section.tabs.contains($0) } ?? .search

            #expect(
                VisionRootView.resolvedTab(
                    forDestinationID: destinationID,
                    current: outside
                ) == section.tabs.first
            )
            for tab in section.tabs {
                #expect(
                    VisionRootView.resolvedTab(
                        forDestinationID: destinationID,
                        current: tab
                    ) == tab
                )
            }
        }
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
