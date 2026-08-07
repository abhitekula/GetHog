import Foundation
import GetHogKit
import SwiftUI
import Testing
@testable import GetHog

/// Pins the wallboard's cycling.
///
/// Written against the cycler rather than the view for a reason the interval
/// itself gives: a test that drove the real screen would have to wait twelve
/// seconds per advance to observe anything. Everything that decides *which*
/// metric is on screen lives here, so all of it can be checked in a
/// millisecond.
@Suite("TV ambient cycler")
@MainActor
struct TVAmbientCyclerTests {

    private static func metric(_ id: String) -> SharedSnapshot.Metric {
        SharedSnapshot.Metric(
            id: id,
            title: "Metric \(id)",
            value: 1,
            unit: nil,
            previous: nil,
            sparkline: [],
            dashboardID: 7
        )
    }

    private static func cycler(count: Int) -> TVAmbientCycler {
        TVAmbientCycler(metrics: (0..<count).map { metric(String($0)) })
    }

    @Test("advancing past the last metric returns to the first")
    func advanceWraps() {
        let cycler = Self.cycler(count: 3)
        cycler.advance()
        #expect(cycler.index == 1)
        cycler.advance()
        #expect(cycler.index == 2)
        // The wrap is the whole point: a wallboard that stopped on the last
        // tile would show one number until somebody walked over to it.
        cycler.advance()
        #expect(cycler.index == 0)
    }

    @Test("skipping back from the first metric lands on the last")
    func skipLeftWrapsBackwards() {
        let cycler = Self.cycler(count: 4)
        cycler.skip(.left)
        // Not clamped at zero, and not a negative index: a ring has no end to
        // stop at, and `(0 - 1) % 4` in Swift is -1, which would crash the
        // subscript below it.
        #expect(cycler.index == 3)
        #expect(cycler.current?.id == "3")
    }

    @Test("skipping forward is the same step advancing takes")
    func skipRightMatchesAdvance() {
        let skipped = Self.cycler(count: 3)
        let advanced = Self.cycler(count: 3)
        skipped.skip(.right)
        advanced.advance()
        #expect(skipped.index == advanced.index)
    }

    @Test("up and down are not cycle commands")
    func verticalMovesAreIgnored() {
        // The remote's vertical axis belongs to whatever focus does with it.
        // Treating it as a skip would make the wallboard jump under a thumb
        // that was only resting on the pad.
        let cycler = Self.cycler(count: 3)
        cycler.skip(.up)
        cycler.skip(.down)
        #expect(cycler.index == 0)
    }

    @Test("an empty snapshot vends no metric and cannot be advanced past zero")
    func emptyMetricsAreInert() {
        let cycler = TVAmbientCycler(metrics: [])
        #expect(cycler.isEmpty)
        #expect(cycler.current == nil)
        // Both of these would divide by zero or index an empty array if they
        // did not guard; the screen renders its "nothing pinned" state instead.
        cycler.advance()
        cycler.skip(.left)
        #expect(cycler.index == 0)
        #expect(cycler.current == nil)
    }

    @Test("a snapshot that dropped the metric being shown falls back to the start")
    func replaceFallsBackWhenTheReadMetricIsGone() {
        let cycler = Self.cycler(count: 5)
        cycler.advance()
        cycler.advance()
        cycler.advance()
        #expect(cycler.index == 3)
        // A dashboard that lost tiles between snapshots would otherwise leave
        // the index pointing past the end until the next tick.
        cycler.replace(metrics: [Self.metric("only")])
        #expect(cycler.index == 0)
        #expect(cycler.current?.id == "only")
    }

    @Test("an unchanged snapshot is not adopted, so the cycle keeps its place")
    func replaceIsANoOpWhenNothingChanged() {
        // **This is what makes re-reading on every tick safe.** The wallboard
        // re-reads the snapshot each cycle so it cannot sit on day-old numbers,
        // and if that read reset the index the screen would show metric one
        // forever, twelve seconds at a time.
        let cycler = Self.cycler(count: 4)
        cycler.advance()
        cycler.advance()
        #expect(cycler.index == 2)

        let same = (0..<4).map { Self.metric(String($0)) }
        #expect(cycler.replace(metrics: same) == false)
        #expect(cycler.index == 2)
        #expect(cycler.current?.id == "2")
    }

    @Test("a metric whose value moved is adopted even though its title did not")
    func replaceAdoptsChangedValues() {
        // Equality is the whole list, values included. Comparing ids or titles
        // alone would make the wallboard blind to the only thing it exists to
        // show: the number changing.
        let cycler = TVAmbientCycler(metrics: [Self.metric("a")])
        let moved = SharedSnapshot.Metric(
            id: "a", title: "Metric a", value: 99, unit: nil,
            previous: nil, sparkline: [], dashboardID: 7
        )
        #expect(cycler.replace(metrics: [moved]))
        #expect(cycler.current?.value == 99)
    }

    @Test("a refreshed snapshot holds the reader on the metric they were reading")
    func replaceHoldsPositionByIdentity() {
        // Held by identity, not by index: a snapshot that gained a tile at the
        // front would otherwise jump the screen to a different metric in the
        // middle of somebody reading it.
        let cycler = Self.cycler(count: 3)
        cycler.advance()
        #expect(cycler.current?.id == "1")

        let grown = [Self.metric("new")] + (0..<3).map { Self.metric(String($0)) }
        #expect(cycler.replace(metrics: grown))
        #expect(cycler.current?.id == "1")
        #expect(cycler.index == 2)
    }

    @Test("the cycle interval is the documented cadence")
    func intervalIsTwelveSeconds() {
        // Not a restatement of the constant against itself: this asserts the
        // *duration it amounts to*, which is what the screen's tick sleeps for
        // and what the ambient screenshot's 15-second wait is sized against.
        #expect(TVAmbientCycler.interval == .seconds(12))
        #expect(TVAmbientCycler.interval < .seconds(30))
    }

    // MARK: - Keeping the screen awake

    /// The never-sleeping-TV failure mode, as transitions rather than as three
    /// callbacks nobody can drive.
    @Suite("TV screen awake hold")
    struct TVScreenAwakeTests {

        @Test("nothing is held before the wallboard is entered")
        func startsReleased() {
            #expect(!TVScreenAwake().isHeld)
        }

        @Test("entering the wallboard holds the screen")
        func presentHolds() {
            var awake = TVScreenAwake()
            awake.present()
            #expect(awake.isHeld)
        }

        @Test("leaving releases, and a tab kept alive behind the sidebar cannot re-take it")
        func leaveReleases() {
            // This is the bug. The release used to hang entirely on
            // `onDisappear`, and a `TabView` may keep a tab's content alive
            // across a sidebar switch — in which case the tick loop went on
            // re-asserting from a tab nobody was watching, forever.
            var awake = TVScreenAwake()
            awake.present()
            awake.leave()
            #expect(!awake.isHeld)
        }

        @Test("a backgrounded scene releases the hold")
        func inactiveSceneReleases() {
            var awake = TVScreenAwake()
            awake.present()
            awake.sceneBecame(active: false)
            #expect(!awake.isHeld)
        }

        @Test("coming back to an app the viewer never left resumes the hold")
        func returningResumesWhilePresented() {
            var awake = TVScreenAwake()
            awake.present()
            awake.sceneBecame(active: false)
            awake.sceneBecame(active: true)
            #expect(awake.isHeld)
        }

        @Test("coming back does NOT resume a hold the viewer had already left")
        func returningDoesNotResurrectALeftScreen() {
            // Leaving is sticky for exactly this: a wallboard exited to the
            // sidebar, then the app backgrounded and foregrounded, must not
            // silently start holding the screen awake again from a tab nobody
            // is looking at. A single `isSceneActive` boolean would.
            var awake = TVScreenAwake()
            awake.present()
            awake.leave()
            awake.sceneBecame(active: false)
            awake.sceneBecame(active: true)
            #expect(!awake.isHeld)
        }

        @Test("re-entering after leaving holds again")
        func reentryHolds() {
            var awake = TVScreenAwake()
            awake.present()
            awake.leave()
            awake.present()
            #expect(awake.isHeld)
        }
    }

    // MARK: - Wording

    @Test("a metric with no comparison period claims no movement")
    func absentPreviousMeansNoDelta() {
        // `previous` documents nil as "not known", which is not "no change" —
        // the wallboard must not draw an arrow for a number it never compared.
        #expect(TVAmbientView.deltaPhrase(Self.metric("a")) == nil)
    }

    @Test("a fall is spoken as a fall, with the magnitude it actually was")
    func downwardDeltaReads() {
        let metric = SharedSnapshot.Metric(
            id: "a", title: "Signups", value: 750, unit: nil,
            previous: 1_000, sparkline: [], dashboardID: 1
        )
        #expect(TVAmbientView.deltaPhrase(metric) == "Down 25%")
        #expect(TVAmbientView.spoken(metric).contains("Signups"))
        #expect(TVAmbientView.spoken(metric).contains("Down 25%"))
    }

    @Test("a unit rides with the headline rather than being dropped")
    func unitJoinsTheHeadline() {
        let metric = SharedSnapshot.Metric(
            id: "a", title: "Top page", value: 4_200, unit: "/pricing",
            previous: nil, sparkline: [], dashboardID: 1
        )
        // A bar-value tile's unit is the label of the bar it came from. A
        // headline of "4.2K" with the label thrown away is a number about
        // nothing.
        #expect(TVAmbientView.headline(metric).contains("/pricing"))
    }
}
