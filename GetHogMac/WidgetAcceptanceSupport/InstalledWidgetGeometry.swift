import Foundation

enum InstalledWidgetFrameValidity: Equatable {
    case valid
    case invalid

    init(frame: CGRect) {
        let components = [frame.origin.x, frame.origin.y, frame.width, frame.height]
        self = components.allSatisfy(\.isFinite)
            && frame.width > 0
            && frame.height > 0
            && !frame.isNull
            && !frame.isInfinite
            ? .valid
            : .invalid
    }
}

/// One raw name-matched accessibility result before any menu probing.
struct InstalledWidgetPreflightMatch: Equatable {
    let id: Int
    let excludedType: Bool
    let exists: Bool
    let hittable: Bool
    let frameValidity: InstalledWidgetFrameValidity
}

enum InstalledWidgetPreflightBlock: Equatable, CustomStringConvertible {
    case missing(candidateID: Int)
    case notHittable(candidateID: Int)
    case invalidFrame(candidateID: Int)

    var description: String {
        switch self {
        case let .missing(candidateID):
            return "candidate \(candidateID) no longer exists"
        case let .notHittable(candidateID):
            return "candidate \(candidateID) is not hittable"
        case let .invalidFrame(candidateID):
            return "candidate \(candidateID) has invalid geometry"
        }
    }
}

enum InstalledWidgetPreflightResolution: Equatable {
    case absent
    case probeReady(candidateIDs: [Int])
    case blocked(InstalledWidgetPreflightBlock)
}

enum InstalledWidgetPreflightClassifier {
    static func classify(
        _ rawMatches: [InstalledWidgetPreflightMatch]
    ) -> InstalledWidgetPreflightResolution {
        let eligible = rawMatches
            .filter { !$0.excludedType }
            .sorted { $0.id < $1.id }
        guard !eligible.isEmpty else { return .absent }

        for candidate in eligible {
            guard candidate.exists else {
                return .blocked(.missing(candidateID: candidate.id))
            }
            guard candidate.frameValidity == .valid else {
                return .blocked(.invalidFrame(candidateID: candidate.id))
            }
            guard candidate.hittable else {
                return .blocked(.notHittable(candidateID: candidate.id))
            }
        }

        return .probeReady(candidateIDs: eligible.map(\.id))
    }
}

/// A menu-witnessed accessibility descendant that may represent all or part
/// of one installed widget.
struct InstalledWidgetGeometryCandidate: Equatable {
    let id: Int
    let frame: CGRect
}

/// One connected installed-widget region with its unique witnessed container.
struct InstalledWidgetGeometryCluster: Equatable {
    let candidateIDs: [Int]
    let canonicalID: Int
}

enum InstalledWidgetGeometryBlock: Equatable, CustomStringConvertible {
    case invalidFrame(candidateID: Int)
    case missingCanonical(candidateIDs: [Int])
    case ambiguousCanonical(candidateIDs: [Int])

    var description: String {
        switch self {
        case let .invalidFrame(candidateID):
            return "candidate \(candidateID) has invalid geometry"
        case let .missingCanonical(candidateIDs):
            return "cluster \(candidateIDs) has no witnessed enclosing container"
        case let .ambiguousCanonical(candidateIDs):
            return "equal-area enclosing candidates \(candidateIDs) are ambiguous"
        }
    }
}

enum InstalledWidgetGeometryResolution: Equatable {
    case absent
    case resolved([InstalledWidgetGeometryCluster])
    case blocked(InstalledWidgetGeometryBlock)
}

enum InstalledWidgetGeometryResolver {
    private static let containmentTolerance: CGFloat = 0.5
    private static let areaTolerance: CGFloat = 0.5

    static func resolve(
        _ candidates: [InstalledWidgetGeometryCandidate]
    ) -> InstalledWidgetGeometryResolution {
        guard !candidates.isEmpty else { return .absent }

        for candidate in candidates.sorted(by: { $0.id < $1.id }) {
            guard InstalledWidgetFrameValidity(frame: candidate.frame) == .valid else {
                return .blocked(.invalidFrame(candidateID: candidate.id))
            }
        }

        var unvisited = Set(candidates.indices)
        var resolved: [(bounds: CGRect, cluster: InstalledWidgetGeometryCluster)] = []

        while let start = unvisited.min() {
            unvisited.remove(start)
            var pending = [start]
            var component: [Int] = []

            while let current = pending.popLast() {
                component.append(current)
                let neighbors = unvisited.filter {
                    belongsToSameCluster(candidates[current].frame, candidates[$0].frame)
                }
                for neighbor in neighbors {
                    unvisited.remove(neighbor)
                    pending.append(neighbor)
                }
            }

            let witnesses = component.map { candidates[$0] }
            let candidateIDs = witnesses.map(\.id).sorted()
            let enclosing = witnesses.filter { candidate in
                witnesses.allSatisfy {
                    contains(candidate.frame, $0.frame, tolerance: containmentTolerance)
                }
            }
            guard let maximumArea = enclosing.map({ area(of: $0.frame) }).max() else {
                return .blocked(.missingCanonical(candidateIDs: candidateIDs))
            }
            let maximumEnclosing = enclosing.filter {
                abs(area(of: $0.frame) - maximumArea) <= areaTolerance
            }
            guard maximumEnclosing.count == 1, let canonical = maximumEnclosing.first else {
                return .blocked(.ambiguousCanonical(
                    candidateIDs: maximumEnclosing.map(\.id).sorted()
                ))
            }

            let bounds = witnesses.dropFirst().reduce(witnesses[0].frame) {
                $0.union($1.frame)
            }
            resolved.append((
                bounds: bounds,
                cluster: InstalledWidgetGeometryCluster(
                    candidateIDs: candidateIDs,
                    canonicalID: canonical.id
                )
            ))
        }

        return .resolved(resolved.sorted(by: clusterOrder).map { $0.cluster })
    }

    private static func contains(
        _ container: CGRect,
        _ descendant: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        container.minX <= descendant.minX + tolerance
            && container.minY <= descendant.minY + tolerance
            && container.maxX + tolerance >= descendant.maxX
            && container.maxY + tolerance >= descendant.maxY
    }

    private static func area(of frame: CGRect) -> CGFloat {
        frame.width * frame.height
    }

    private static func belongsToSameCluster(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if contains(lhs, rhs, tolerance: containmentTolerance)
            || contains(rhs, lhs, tolerance: containmentTolerance) {
            return true
        }
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }

    private static func clusterOrder(
        _ lhs: (bounds: CGRect, cluster: InstalledWidgetGeometryCluster),
        _ rhs: (bounds: CGRect, cluster: InstalledWidgetGeometryCluster)
    ) -> Bool {
        if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
        if lhs.bounds.minX != rhs.bounds.minX { return lhs.bounds.minX < rhs.bounds.minX }
        if lhs.bounds.width != rhs.bounds.width { return lhs.bounds.width > rhs.bounds.width }
        if lhs.bounds.height != rhs.bounds.height { return lhs.bounds.height > rhs.bounds.height }
        return (lhs.cluster.candidateIDs.first ?? Int.max)
            < (rhs.cluster.candidateIDs.first ?? Int.max)
    }
}
