import Foundation
import GetHogUI
import Testing

@Suite("Widget primitives")
struct WidgetPrimitivesTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("compact widget numbers retain the unit punctuation that fits in a tile")
    func compactNumbersKeepUnitsLegible() {
        #expect(WidgetNumber.compact(12_480) == "12.5K")
        #expect(WidgetNumber.compact(41.2, unit: "%") == "41.2%")
        #expect(WidgetNumber.compact(8_640, unit: "$") == "$8.6K")
        #expect(WidgetNumber.compact(27, unit: "errors") == "27 errors")
    }

    @Test("freshness distinguishes a missing sync from a recent one")
    func missingAndRecentSnapshotsHaveDifferentLabels() {
        let missing = WidgetFreshness(capturedAt: nil, now: now)
        let recent = WidgetFreshness(capturedAt: now.addingTimeInterval(-30), now: now)

        #expect(missing.shortLabel == "never")
        #expect(missing.spokenLabel == "not synced yet")
        #expect(missing.isStale)
        #expect(recent.shortLabel == "now")
        #expect(recent.spokenLabel == "updated just now")
        #expect(!recent.isStale)
    }

    @Test("freshness uses the shared age buckets and never reads a future snapshot as negative")
    func freshnessBucketsAndFutureClamp() {
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(-20 * 60), now: now).shortLabel == "20m")
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(-3 * 3_600), now: now).shortLabel == "3h")
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(-2 * 86_400), now: now).shortLabel == "2d")
        #expect(WidgetFreshness(capturedAt: now.addingTimeInterval(5 * 60), now: now).age == 0)
    }
}
