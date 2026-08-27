import Foundation
import GetHogKit
import Testing

@testable import GetHog

@Suite("Flag Quick Preview")
struct FlagQuickPreviewTests {
    @Test("an enabled multivariate flag keeps its headline facts distinct")
    func enabledMultivariateFlagKeepsHeadlineFactsDistinct() throws {
        let presentation = FlagQuickPreviewPresentation(flag: try Self.flag(
            """
            {
              "id": 6201,
              "key": "synthetic-onboarding-copy",
              "name": "Synthetic onboarding copy",
              "active": true,
              "filters": {
                "groups": [
                  {"rollout_percentage": 25},
                  {"rollout_percentage": 37.5}
                ],
                "multivariate": {
                  "variants": [
                    {"key": "control", "rollout_percentage": 50},
                    {"key": "treatment", "rollout_percentage": 50}
                  ]
                }
              }
            }
            """
        ))

        #expect(presentation.key == "synthetic-onboarding-copy")
        #expect(presentation.name == "Synthetic onboarding copy")
        #expect(presentation.status == "Enabled")
        #expect(presentation.rollout == "37.5% rollout")
        #expect(presentation.conditionCount == 2)
        #expect(presentation.variantCount == 2)
        #expect(presentation.isMultivariate == true)
    }

    @Test("a disabled flag with no filters states absent rollout and zero sets")
    func disabledFlagStatesAbsentRolloutAndZeroSets() throws {
        let presentation = FlagQuickPreviewPresentation(flag: try Self.flag(
            """
            {
              "id": 6202,
              "key": "synthetic-empty-flag",
              "active": false
            }
            """
        ))

        #expect(presentation.key == "synthetic-empty-flag")
        #expect(presentation.name == nil)
        #expect(presentation.status == "Disabled")
        #expect(presentation.rollout == "No rollout percentage")
        #expect(presentation.conditionCount == 0)
        #expect(presentation.variantCount == 0)
        #expect(presentation.isMultivariate == false)
    }

    @Test("archived status wins over an active source value")
    func archivedStatusWinsOverActiveSourceValue() throws {
        let presentation = FlagQuickPreviewPresentation(flag: try Self.flag(
            """
            {
              "id": 6203,
              "key": "synthetic-archived-flag",
              "active": true,
              "archived": true,
              "filters": {"groups": [{}]}
            }
            """
        ))

        #expect(presentation.status == "Archived")
        #expect(presentation.rollout == "No rollout percentage")
        #expect(presentation.conditionCount == 1)
        #expect(presentation.variantCount == 0)
        #expect(presentation.isMultivariate == false)
    }

    private static func flag(_ json: String) throws -> FeatureFlag {
        try JSONDecoder().decode(FeatureFlag.self, from: Data(json.utf8))
    }
}
