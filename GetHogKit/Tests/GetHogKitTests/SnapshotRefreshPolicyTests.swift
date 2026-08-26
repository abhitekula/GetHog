import Foundation
import Testing

@testable import GetHogKit

struct SnapshotRefreshPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("manual widget refresh is never rejected because the snapshot is fresh")
    func manualRefreshAlwaysRuns() {
        let capturedAt = now.addingTimeInterval(-1)

        #expect(SnapshotRefreshPolicy.shouldRefresh(
            trigger: .manualWidget,
            capturedAt: capturedAt,
            now: now
        ))
    }

    @Test("automatic widget refresh keeps a snapshot younger than thirty minutes")
    func automaticRefreshKeepsFreshSnapshot() {
        let capturedAt = now.addingTimeInterval(-(30 * 60 - 1))

        #expect(SnapshotRefreshPolicy.shouldRefresh(
            trigger: .automaticWidget,
            capturedAt: capturedAt,
            now: now
        ) == false)
    }

    @Test("automatic widget refresh runs at the thirty-minute boundary")
    func automaticRefreshRunsAtStaleBoundary() {
        let capturedAt = now.addingTimeInterval(-30 * 60)

        #expect(SnapshotRefreshPolicy.shouldRefresh(
            trigger: .automaticWidget,
            capturedAt: capturedAt,
            now: now
        ))
    }

    @Test("automatic widget refresh runs before the first snapshot exists")
    func automaticRefreshRunsWithoutSnapshot() {
        #expect(SnapshotRefreshPolicy.shouldRefresh(
            trigger: .automaticWidget,
            capturedAt: nil,
            now: now
        ))
    }

    @Test("foreground publication is not age gated")
    func foregroundRefreshAlwaysRuns() {
        #expect(SnapshotRefreshPolicy.shouldRefresh(
            trigger: .foreground,
            capturedAt: now,
            now: now
        ))
    }

    @Test("Mac background refresh retains the two-hour cadence and early tolerance")
    func macBackgroundRefreshUsesRetainedCadence() {
        let tooEarly = now.addingTimeInterval(-(2 * 60 * 60 - 5 * 60 - 1))
        let due = now.addingTimeInterval(-(2 * 60 * 60 - 5 * 60))

        #expect(SnapshotRefreshPolicy.shouldRefresh(
            trigger: .macBackground,
            capturedAt: tooEarly,
            now: now
        ) == false)
        #expect(SnapshotRefreshPolicy.shouldRefresh(
            trigger: .macBackground,
            capturedAt: due,
            now: now
        ))
    }
}
