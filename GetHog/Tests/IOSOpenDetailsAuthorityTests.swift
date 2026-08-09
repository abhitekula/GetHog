import Foundation
import GetHogKit
import Testing

@testable import GetHog

@MainActor
@Suite("iOS open-details authority")
struct IOSOpenDetailsAuthorityTests {
    private static let projectID = 1_001
    private static let dashboardID = 725_101
    private static let flagID = 170_101

    @Test("scope loss clears every retained detail")
    func scopeLossClearsEveryRetainedDetail() throws {
        let previous = try scope(region: .usCloud, epochSuffix: "504")
        let (openDetails, originalDashboardStore) = seededOpenDetails()

        IOSOpenDetailsAuthority.applyChange(
            from: previous,
            to: nil,
            openDetails: openDetails
        )

        #expect(openDetails[.flags] == nil)
        #expect(
            openDetails.dashboardStores.store(
                for: Self.dashboardID,
                projectID: Self.projectID
            ) !== originalDashboardStore
        )
    }

    @Test("a replacement credential epoch clears every retained detail")
    func sameProjectReplacementEpochClearsEveryRetainedDetail() throws {
        let previous = try scope(region: .usCloud, epochSuffix: "504")
        let current = try scope(region: .usCloud, epochSuffix: "505")
        let (openDetails, originalDashboardStore) = seededOpenDetails()

        IOSOpenDetailsAuthority.applyChange(
            from: previous,
            to: current,
            openDetails: openDetails
        )

        #expect(openDetails[.flags] == nil)
        #expect(
            openDetails.dashboardStores.store(
                for: Self.dashboardID,
                projectID: Self.projectID
            ) !== originalDashboardStore
        )
    }

    @Test("a replacement region clears every retained detail")
    func sameProjectReplacementRegionClearsEveryRetainedDetail() throws {
        let previous = try scope(region: .usCloud, epochSuffix: "504")
        let current = try scope(region: .euCloud, epochSuffix: "504")
        let (openDetails, originalDashboardStore) = seededOpenDetails()

        IOSOpenDetailsAuthority.applyChange(
            from: previous,
            to: current,
            openDetails: openDetails
        )

        #expect(openDetails[.flags] == nil)
        #expect(
            openDetails.dashboardStores.store(
                for: Self.dashboardID,
                projectID: Self.projectID
            ) !== originalDashboardStore
        )
    }

    @Test("an identical scope preserves retained details")
    func identicalScopePreservesRetainedDetails() throws {
        let scope = try scope(region: .usCloud, epochSuffix: "504")
        let (openDetails, originalDashboardStore) = seededOpenDetails()

        IOSOpenDetailsAuthority.applyChange(
            from: scope,
            to: scope,
            openDetails: openDetails
        )

        #expect(openDetails[.flags] == AnyHashable(Self.flagID))
        #expect(
            openDetails.dashboardStores.store(
                for: Self.dashboardID,
                projectID: Self.projectID
            ) === originalDashboardStore
        )
    }

    private func seededOpenDetails() -> (OpenDetails, DashboardDetailStore) {
        let openDetails = OpenDetails()
        openDetails[.flags] = AnyHashable(Self.flagID)
        let store = openDetails.dashboardStores.store(
            for: Self.dashboardID,
            projectID: Self.projectID
        )
        return (openDetails, store)
    }

    private func scope(
        region: PostHogRegion,
        epochSuffix: String
    ) throws -> FlagWriteScope {
        let epoch = try #require(
            UUID(uuidString: "018f9000-0000-7000-8000-000000000\(epochSuffix)")
        )
        return FlagWriteScope(
            projectID: Self.projectID,
            projectRegion: region,
            authSessionID: epoch
        )
    }
}
