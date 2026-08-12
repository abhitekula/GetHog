import Foundation
import Testing

@Suite("Installed widget query preflight")
struct InstalledWidgetPreflightTests {

    @Test("zero raw name matches is absent")
    func noRawMatchesIsAbsent() {
        #expect(InstalledWidgetPreflightClassifier.classify([]) == .absent)
    }

    @Test("excluded system surface matches do not impersonate authored widgets")
    func onlyExcludedMatchesIsAbsent() {
        let excluded = [
            InstalledWidgetPreflightMatch(
                id: 10,
                excludedType: true,
                exists: false,
                hittable: false,
                frameValidity: .invalid
            ),
            InstalledWidgetPreflightMatch(
                id: 20,
                excludedType: true,
                exists: true,
                hittable: true,
                frameValidity: .valid
            ),
        ]

        #expect(InstalledWidgetPreflightClassifier.classify(excluded) == .absent)
    }

    @Test("any eligible unprobeable or invalid raw match blocks preflight")
    func eligibleFailuresAreBlocked() {
        let ready = InstalledWidgetPreflightMatch(
            id: 10,
            excludedType: false,
            exists: true,
            hittable: true,
            frameValidity: .valid
        )
        let cases: [(InstalledWidgetPreflightMatch, InstalledWidgetPreflightBlock)] = [
            (
                .init(
                    id: 20,
                    excludedType: false,
                    exists: false,
                    hittable: false,
                    frameValidity: .invalid
                ),
                .missing(candidateID: 20)
            ),
            (
                .init(
                    id: 30,
                    excludedType: false,
                    exists: true,
                    hittable: false,
                    frameValidity: .valid
                ),
                .notHittable(candidateID: 30)
            ),
            (
                .init(
                    id: 40,
                    excludedType: false,
                    exists: true,
                    hittable: true,
                    frameValidity: .invalid
                ),
                .invalidFrame(candidateID: 40)
            ),
        ]

        for (failure, expected) in cases {
            #expect(InstalledWidgetPreflightClassifier.classify([
                ready,
                failure,
            ]) == .blocked(expected))
        }
    }

    @Test("all eligible probe-ready matches proceed in stable id order")
    func probeReadyMatchesProceed() {
        let resolution = InstalledWidgetPreflightClassifier.classify([
            .init(
                id: 30,
                excludedType: false,
                exists: true,
                hittable: true,
                frameValidity: .valid
            ),
            .init(
                id: 10,
                excludedType: true,
                exists: false,
                hittable: false,
                frameValidity: .invalid
            ),
            .init(
                id: 20,
                excludedType: false,
                exists: true,
                hittable: true,
                frameValidity: .valid
            ),
        ])

        #expect(resolution == .probeReady(candidateIDs: [20, 30]))
    }
}

@Suite("Installed widget geometry")
struct InstalledWidgetGeometryTests {

    @Test("nested widget descendants collapse into their enclosing container")
    func nestedDescendantsUseTheLargestEnclosingWitness() {
        let resolution = InstalledWidgetGeometryResolver.resolve([
            .init(id: 30, frame: CGRect(x: 24, y: 58, width: 150, height: 72)),
            .init(id: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 150)),
            .init(id: 20, frame: CGRect(x: 24, y: 20, width: 80, height: 24)),
        ])

        #expect(resolution == .resolved([
            .init(candidateIDs: [10, 20, 30], canonicalID: 10),
        ]))
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

        let resolution = InstalledWidgetGeometryResolver.resolve(candidates)

        #expect(resolution == .resolved([
            .init(candidateIDs: [10, 20], canonicalID: 10),
            .init(candidateIDs: [30, 40], canonicalID: 30),
        ]))
    }

    @Test("overlapping sibling witnesses share their enclosing widget cluster")
    func overlappingSiblingsShareTheirEnclosingCluster() {
        let resolution = InstalledWidgetGeometryResolver.resolve([
            .init(id: 10, frame: CGRect(x: 0, y: 0, width: 220, height: 140)),
            .init(id: 20, frame: CGRect(x: 20, y: 30, width: 120, height: 60)),
            .init(id: 30, frame: CGRect(x: 100, y: 30, width: 100, height: 60)),
        ])

        #expect(resolution == .resolved([
            .init(candidateIDs: [10, 20, 30], canonicalID: 10),
        ]))
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

        #expect(InstalledWidgetGeometryResolver.resolve(candidates) == .blocked(
            .missingCanonical(candidateIDs: [20, 30])
        ))
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

        let expected = InstalledWidgetGeometryResolution.resolved([
            .init(candidateIDs: [10, 20, 30], canonicalID: 10),
        ])
        #expect(InstalledWidgetGeometryResolver.resolve([outer, title, content]) == expected)
        #expect(InstalledWidgetGeometryResolver.resolve([content, title, outer]) == expected)
    }

    @Test("no witnessed descendants is explicitly absent")
    func emptyInputIsAbsent() {
        #expect(InstalledWidgetGeometryResolver.resolve([]) == .absent)
    }

    @Test("non-finite and zero-area frames block geometry resolution")
    func invalidFramesAreBlocked() {
        // CGRect standardizes negative extents before this boundary, erasing their original sign.
        let invalidFrames: [(Int, CGRect)] = [
            (1, CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)),
            (2, CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100)),
            (3, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)),
            (4, CGRect(x: 0, y: 0, width: 100, height: CGFloat.infinity)),
            (5, CGRect(x: 0, y: 0, width: 0, height: 100)),
            (6, CGRect(x: 0, y: 0, width: 100, height: 0)),
            (7, .null),
            (8, .infinite),
        ]

        for (id, frame) in invalidFrames {
            #expect(InstalledWidgetGeometryResolver.resolve([
                .init(id: id, frame: frame),
            ]) == .blocked(.invalidFrame(candidateID: id)))
        }
    }

    @Test("duplicate equal-frame enclosing witnesses are ambiguous")
    func equalFrameContainersDoNotTieBreakByID() {
        let resolution = InstalledWidgetGeometryResolver.resolve([
            .init(id: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 150)),
            .init(id: 11, frame: CGRect(x: 0, y: 0, width: 200, height: 150)),
            .init(id: 20, frame: CGRect(x: 24, y: 20, width: 80, height: 24)),
        ])

        #expect(resolution == .blocked(.ambiguousCanonical(candidateIDs: [10, 11])))
    }

    @Test("one strictly largest valid enclosing witness is canonical")
    func uniqueLargestValidContainerWins() {
        let resolution = InstalledWidgetGeometryResolver.resolve([
            .init(id: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 150)),
            .init(id: 11, frame: CGRect(x: 10, y: 10, width: 180, height: 130)),
            .init(id: 20, frame: CGRect(x: 24, y: 20, width: 80, height: 24)),
        ])

        #expect(resolution == .resolved([
            .init(candidateIDs: [10, 11, 20], canonicalID: 10),
        ]))
    }
}
