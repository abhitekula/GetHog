import Foundation

/// A menu-witnessed accessibility descendant that may represent all or part
/// of one installed widget.
struct InstalledWidgetGeometryCandidate: Equatable {
    let id: Int
    let frame: CGRect
}

/// One connected installed-widget region. `canonicalID` is nil when no
/// witnessed descendant encloses the whole region, so callers cannot quietly
/// promote an overlapping title/content leaf to widget identity.
struct InstalledWidgetGeometryCluster: Equatable {
    let candidateIDs: [Int]
    let canonicalID: Int?
}

enum InstalledWidgetGeometryResolver {

    static func singleCanonicalID(
        for candidates: [InstalledWidgetGeometryCandidate]
    ) -> Int? {
        let resolved = clusters(for: candidates)
        guard resolved.count == 1 else { return nil }
        return resolved[0].canonicalID
    }

    static func clusters(
        for candidates: [InstalledWidgetGeometryCandidate]
    ) -> [InstalledWidgetGeometryCluster] {
        let valid = candidates.filter {
            !$0.frame.isNull
                && !$0.frame.isInfinite
                && $0.frame.width > 0
                && $0.frame.height > 0
        }
        var unvisited = Set(valid.indices)
        var resolved: [(bounds: CGRect, cluster: InstalledWidgetGeometryCluster)] = []

        while let start = unvisited.min() {
            unvisited.remove(start)
            var pending = [start]
            var component: [Int] = []

            while let current = pending.popLast() {
                component.append(current)
                let neighbors = unvisited.filter {
                    belongsToSameCluster(valid[current].frame, valid[$0].frame)
                }
                for neighbor in neighbors {
                    unvisited.remove(neighbor)
                    pending.append(neighbor)
                }
            }

            let witnesses = component.map { valid[$0] }
            let canonical = witnesses
                .filter { candidate in
                    witnesses.allSatisfy { candidate.frame.contains($0.frame) }
                }
                .sorted(by: canonicalOrder)
                .first
            let bounds = witnesses.dropFirst().reduce(witnesses[0].frame) {
                $0.union($1.frame)
            }
            resolved.append((
                bounds: bounds,
                cluster: InstalledWidgetGeometryCluster(
                    candidateIDs: witnesses.map(\.id).sorted(),
                    canonicalID: canonical?.id
                )
            ))
        }

        return resolved.sorted(by: clusterOrder).map { $0.cluster }
    }

    private static func belongsToSameCluster(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.contains(rhs) || rhs.contains(lhs) { return true }
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }

    private static func canonicalOrder(
        _ lhs: InstalledWidgetGeometryCandidate,
        _ rhs: InstalledWidgetGeometryCandidate
    ) -> Bool {
        let lhsArea = lhs.frame.width * lhs.frame.height
        let rhsArea = rhs.frame.width * rhs.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        return lhs.id < rhs.id
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
