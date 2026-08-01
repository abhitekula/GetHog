import GetHogKit

@MainActor
struct FlagOverviewFacts {
    let flagCount: Int
    let enabledCount: Int
    let multivariateCount: Int
    let statusCounts: [FlagStatusGroup: Int]
    let partialRollouts: [FeatureFlag]

    init(store: FlagsStore) {
        flagCount = store.flags.count
        enabledCount = store.flags.filter { store.group(for: $0) == .enabled }.count
        multivariateCount = store.flags.filter { $0.isMultivariate && !$0.archived }.count
        statusCounts = Dictionary(uniqueKeysWithValues: FlagStatusGroup.allCases.map { group in
            (group, store.flags.filter { store.group(for: $0) == group }.count)
        })
        partialRollouts = Array(
            store.flags
                .filter { store.group(for: $0) == .enabled }
                .filter { ($0.rolloutPercentage ?? 100) < 100 }
                .sorted { ($0.rolloutPercentage ?? 0) < ($1.rolloutPercentage ?? 0) }
                .prefix(6)
        )
    }
}

enum FlagBrandAppearance {
    static func glyph(isMultivariate: Bool, isArchived: Bool) -> BrandObjectGlyph {
        if isArchived { return .archivedFlag }
        return isMultivariate ? .multivariateFlag : .flag
    }
}
