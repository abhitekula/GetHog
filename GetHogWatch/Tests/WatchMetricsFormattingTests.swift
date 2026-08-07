import Foundation
import GetHogKit
@testable import GetHogWatch
import Testing

@Suite("Watch metrics formatting")
struct WatchMetricsFormattingTests {

    private func metric(value: Double, previous: Double?) -> SharedSnapshot.Metric {
        SharedSnapshot.Metric(
            id: "example-metric", title: "Example signups", value: value,
            unit: nil, previous: previous, sparkline: [], dashboardID: nil
        )
    }

    // MARK: - Age

    @Test("the age stamp reads in the unit the age deserves")
    func ageStampUnits() {
        let now = WatchFixtures.now
        #expect(WatchAge.stamp(capturedAt: now, now: now) == "Updated just now")
        #expect(
            WatchAge.stamp(capturedAt: now.addingTimeInterval(-59), now: now)
                == "Updated just now"
        )
        #expect(
            WatchAge.stamp(capturedAt: now.addingTimeInterval(-600), now: now)
                == "Updated 10 min ago"
        )
        #expect(
            WatchAge.stamp(capturedAt: now.addingTimeInterval(-7200), now: now)
                == "Updated 2 h ago"
        )
        #expect(
            WatchAge.stamp(capturedAt: now.addingTimeInterval(-3 * 86_400), now: now)
                == "Updated 3 d ago"
        )
    }

    @Test("a snapshot from the future is clamped, not read backwards")
    func ageStampClampsTheFuture() {
        let now = WatchFixtures.now
        #expect(
            WatchAge.stamp(capturedAt: now.addingTimeInterval(300), now: now)
                == "Updated just now"
        )
    }

    // MARK: - Delta

    @Test("a rise against a real baseline is stated as a percentage")
    func upPercentage() {
        #expect(
            WatchDeltaText.line(for: metric(value: 55, previous: 45))
                == "Up 22.22% vs previous"
        )
    }

    @Test("a fall is stated with the same magnitude and the opposite word")
    func downPercentage() {
        #expect(
            WatchDeltaText.line(for: metric(value: 45, previous: 90))
                == "Down 50% vs previous"
        )
    }

    @Test("a zero baseline states the absolute move rather than an infinite percentage")
    func zeroBaselineFallsBackToAbsolute() {
        #expect(
            WatchDeltaText.line(for: metric(value: 12, previous: 0))
                == "Up 12 vs previous"
        )
    }

    @Test("no baseline is 'no comparison', which is not the same as flat")
    func unknownDirectionIsStated() {
        #expect(WatchDeltaText.line(for: metric(value: 12, previous: nil)) == "No comparison")
        #expect(
            WatchDeltaText.line(for: metric(value: 12, previous: 12))
                == "No change vs previous"
        )
    }

    @Test("each direction carries its own symbol")
    func symbolPerDirection() {
        #expect(WatchDeltaText.symbol(for: metric(value: 2, previous: 1)) == "arrow.up.right")
        #expect(WatchDeltaText.symbol(for: metric(value: 1, previous: 2)) == "arrow.down.right")
        #expect(WatchDeltaText.symbol(for: metric(value: 1, previous: 1)) == "arrow.right")
        #expect(WatchDeltaText.symbol(for: metric(value: 1, previous: nil)) == "minus")
    }
}
