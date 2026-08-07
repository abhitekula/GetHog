import Foundation
import GetHogKit
import Testing
import TVServices
@testable import GetHog

@Suite("TV Top Shelf content")
struct TVTopShelfContentTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("a missing snapshot returns no sections or shelf content")
    func missingSnapshotIsEmpty() {
        let content = TopShelfContent.make(snapshot: nil, now: now)

        #expect(content.sections.isEmpty)
        #expect(content.sectioned() == nil)
    }

    @Test("a synced project with no metrics returns no sections or shelf content")
    func emptySnapshotIsEmpty() {
        let content = TopShelfContent.make(snapshot: snapshot(metrics: []), now: now)

        #expect(content.sections.isEmpty)
        #expect(content.sectioned() == nil)
    }

    @Test("metric items preserve snapshot order")
    func metricItemsKeepSnapshotOrder() {
        let content = TopShelfContent.make(
            snapshot: snapshot(metrics: [metric("first"), metric("second"), metric("third")]),
            now: now
        )

        #expect(content.sections.count == 1)
        #expect(content.sections[0].items.map(\.name) == ["Metric first", "Metric second", "Metric third"])
    }

    @Test("a shelf keeps the first six metrics when a dashboard has more")
    func metricItemsAreCappedFromTheFront() {
        let metrics = (0..<8).map { metric("\($0)") }
        let content = TopShelfContent.make(snapshot: snapshot(metrics: metrics), now: now)

        #expect(content.sections[0].items.map(\.name) == [
            "Metric 0", "Metric 1", "Metric 2", "Metric 3", "Metric 4", "Metric 5",
        ])
    }

    @Test("a fresh section title names the project and its update age")
    func freshSectionTitle() {
        let content = TopShelfContent.make(snapshot: snapshot(metrics: [metric("one")], age: 4 * 60), now: now)

        #expect(content.sections[0].title == "Starling Metrics Lab · Updated 4m ago")
    }

    @Test("stale metrics remain visible and their section admits their age")
    func staleSnapshotRemainsVisible() {
        let content = TopShelfContent.make(
            snapshot: snapshot(metrics: [metric("one")], age: SharedSnapshot.defaultStaleTolerance + 1),
            now: now
        )

        #expect(content.sections[0].items.count == 1)
        #expect(content.sections[0].title.hasSuffix("— stale"))
    }

    @Test("freshness captions use the four product age buckets")
    func freshnessBuckets() {
        #expect(TopShelfFreshness.caption(forAge: 30) == "Updated just now")
        #expect(TopShelfFreshness.caption(forAge: 4 * 60) == "Updated 4m ago")
        #expect(TopShelfFreshness.caption(forAge: 3 * 3_600) == "Updated 3h ago")
        #expect(TopShelfFreshness.caption(forAge: 2 * 86_400) == "Updated 2d ago")
    }

    @Test("a future capture time reads as just now")
    func futureCaptureTimeClampsToNow() {
        let content = TopShelfContent.make(
            snapshot: snapshot(metrics: [metric("one")], capturedAt: now.addingTimeInterval(5 * 60)),
            now: now
        )

        #expect(content.sections[0].title == "Starling Metrics Lab · Updated just now")
    }

    @Test("a bar label never crowds the shelf caption")
    func barValueUnitIsNotInCaption() {
        let content = TopShelfContent.make(
            snapshot: snapshot(metrics: [metric("bar", unit: "example.com synthetic fixture 6")]),
            now: now
        )

        let caption = content.sections[0].items[0].caption
        #expect(!caption.contains("example.com"))
        #expect(!caption.contains("…"))
    }

    @Test("headlines use the shared compact number spelling")
    func headlineUsesCompactFormatting() {
        let content = TopShelfContent.make(snapshot: snapshot(metrics: [metric("count", value: 12_480)]), now: now)

        #expect(content.sections[0].items[0].caption.contains("12.5K"))
    }

    @Test("repeated metric identifiers become unique shelf identifiers")
    func shelfIdentifiersAreUnique() throws {
        let content = TopShelfContent.make(
            snapshot: snapshot(metrics: [metric("same"), metric("same")]),
            now: now
        )
        let shelf = try #require(content.sectioned())
        let items = try #require(shelf.sections.first?.items)

        #expect(Set(items.map(\.identifier)).count == items.count)
    }

    @Test("the TVServices adapter retains every section and caption in order")
    func sectionedContentRetainsModelValues() throws {
        let content = TopShelfContent.make(
            snapshot: snapshot(metrics: [metric("first"), metric("second")]),
            now: now
        )
        let shelf = try #require(content.sectioned())
        let section = try #require(shelf.sections.first)

        #expect(section.title == content.sections[0].title)
        #expect(section.items.compactMap(\.title) == content.sections[0].items.map(\.caption))
    }

    private func snapshot(
        metrics: [SharedSnapshot.Metric],
        age: TimeInterval = 0,
        capturedAt: Date? = nil
    ) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1001,
            projectName: "Starling Metrics Lab",
            metrics: metrics,
            flags: [],
            capturedAt: capturedAt ?? now.addingTimeInterval(-age)
        )
    }

    private func metric(_ id: String, value: Double = 1, unit: String? = nil) -> SharedSnapshot.Metric {
        SharedSnapshot.Metric(
            id: id,
            title: "Metric \(id)",
            value: value,
            unit: unit,
            previous: nil,
            sparkline: [],
            dashboardID: 1001
        )
    }
}

@Suite("TV Top Shelf refresh")
struct TVTopShelfRefreshTests {

    @Test("only a background scene transition asks the shelf to reload")
    func backgroundIsTheOnlyNotificationPhase() {
        #expect(TVTopShelfRefresh.shouldNotify(for: .background))
        #expect(!TVTopShelfRefresh.shouldNotify(for: .active))
        #expect(!TVTopShelfRefresh.shouldNotify(for: .inactive))
    }

    @Test("the shelf extension source cannot construct or send an API request")
    func extensionIsSnapshotOnly() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appending(path: "GetHogTVTopShelf/Sources")
        let files = try FileManager.default.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let forbidden = ["PostHogAPI", "PostHogClient", "client.send", "URLSession"]

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for symbol in forbidden {
                #expect(!source.contains(symbol), "\(file.lastPathComponent) contains \(symbol)")
            }
        }
    }
}
