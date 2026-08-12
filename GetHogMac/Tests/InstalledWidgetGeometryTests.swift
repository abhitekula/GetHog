import Foundation
import Testing

@Suite("Installed widget geometry")
struct InstalledWidgetGeometryTests {

    @Test("nested widget descendants collapse into their enclosing container")
    func nestedDescendantsUseTheLargestEnclosingWitness() {
        let clusters = InstalledWidgetGeometryResolver.clusters(for: [
            .init(id: 30, frame: CGRect(x: 24, y: 58, width: 150, height: 72)),
            .init(id: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 150)),
            .init(id: 20, frame: CGRect(x: 24, y: 20, width: 80, height: 24)),
        ])

        #expect(clusters == [
            .init(candidateIDs: [10, 20, 30], canonicalID: 10),
        ])
    }

    @Test("two disjoint widgets remain ambiguous even when their areas differ")
    func disjointWidgetsRemainSeparateClusters() {
        let candidates = [
            InstalledWidgetGeometryCandidate(
                id: 10,
                frame: CGRect(x: 0, y: 0, width: 200, height: 150)
            ),
            InstalledWidgetGeometryCandidate(
                id: 20,
                frame: CGRect(x: 20, y: 20, width: 100, height: 24)
            ),
            InstalledWidgetGeometryCandidate(
                id: 30,
                frame: CGRect(x: 300, y: 0, width: 120, height: 100)
            ),
            InstalledWidgetGeometryCandidate(
                id: 40,
                frame: CGRect(x: 316, y: 16, width: 88, height: 24)
            ),
        ]

        let clusters = InstalledWidgetGeometryResolver.clusters(for: candidates)

        #expect(clusters.count == 2)
        #expect(clusters.map(\.canonicalID) == [10, 30])
        #expect(InstalledWidgetGeometryResolver.singleCanonicalID(for: candidates) == nil)
    }

    @Test("overlapping sibling witnesses share their enclosing widget cluster")
    func overlappingSiblingsShareTheirEnclosingCluster() {
        let clusters = InstalledWidgetGeometryResolver.clusters(for: [
            .init(id: 10, frame: CGRect(x: 0, y: 0, width: 220, height: 140)),
            .init(id: 20, frame: CGRect(x: 20, y: 30, width: 120, height: 60)),
            .init(id: 30, frame: CGRect(x: 100, y: 30, width: 100, height: 60)),
        ])

        #expect(clusters == [
            .init(candidateIDs: [10, 20, 30], canonicalID: 10),
        ])
    }

    @Test("overlapping leaves cannot impersonate a widget container")
    func overlappingLeavesHaveNoCanonicalContainer() {
        let candidates = [
            InstalledWidgetGeometryCandidate(
                id: 20,
                frame: CGRect(x: 20, y: 30, width: 120, height: 60)
            ),
            InstalledWidgetGeometryCandidate(
                id: 30,
                frame: CGRect(x: 100, y: 30, width: 100, height: 60)
            ),
        ]

        #expect(InstalledWidgetGeometryResolver.clusters(for: candidates) == [
            .init(candidateIDs: [20, 30], canonicalID: nil),
        ])
        #expect(InstalledWidgetGeometryResolver.singleCanonicalID(for: candidates) == nil)
    }

    @Test("canonical choice is stable when witnessed descendants reorder")
    func canonicalChoiceDoesNotDependOnInputOrder() {
        let outer = InstalledWidgetGeometryCandidate(
            id: 10,
            frame: CGRect(x: 0, y: 0, width: 200, height: 150)
        )
        let title = InstalledWidgetGeometryCandidate(
            id: 20,
            frame: CGRect(x: 24, y: 20, width: 80, height: 24)
        )
        let content = InstalledWidgetGeometryCandidate(
            id: 30,
            frame: CGRect(x: 24, y: 58, width: 150, height: 72)
        )

        #expect(InstalledWidgetGeometryResolver.singleCanonicalID(
            for: [outer, title, content]
        ) == 10)
        #expect(InstalledWidgetGeometryResolver.singleCanonicalID(
            for: [content, title, outer]
        ) == 10)
    }
}
