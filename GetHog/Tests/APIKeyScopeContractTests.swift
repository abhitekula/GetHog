import GetHogKit
import Testing

@testable import GetHog

/// Production writers must resolve their scope through the named catalog action.
/// A string that merely happens to equal the catalog today is not linkage: a
/// future scope correction would change Settings while leaving the write's 403
/// recovery behind.
@Suite("API key scope action contracts")
@MainActor
struct APIKeyScopeContractTests {

    private struct Contract {
        let consumer: String
        let action: APIKeyScopeGuidance.OptionalWriteAction
        let scope: String
    }

    @Test("every live writer and intent is linked to its named catalog descriptor")
    func everyLiveWriterUsesItsCatalogDescriptor() {
        let contracts = [
            Contract(
                consumer: "flag controller",
                action: .featureFlags,
                scope: FlagToggleController().requiredWriteScope
            ),
            Contract(
                consumer: "flag intent",
                action: .featureFlags,
                scope: SetScopedFeatureFlagIntent.requiredWriteScope
            ),
            Contract(
                consumer: "alerts",
                action: .alerts,
                scope: AlertWriteController().requiredWriteScope
            ),
            Contract(
                consumer: "annotations",
                action: .annotations,
                scope: AnnotationComposer().requiredWriteScope
            ),
            Contract(
                consumer: "error tracking",
                action: .errorTracking,
                scope: ErrorTriageController().requiredWriteScope
            ),
            Contract(
                consumer: "experiments",
                action: .experiments,
                scope: ExperimentLifecycleController().requiredWriteScope
            ),
            Contract(
                consumer: "surveys",
                action: .surveys,
                scope: SurveyLifecycleController().requiredWriteScope
            ),
        ]

        #expect(Set(contracts.map(\.action)) == Set(APIKeyScopeGuidance.OptionalWriteAction.allCases))
        #expect(Set(contracts.map(\.consumer)).count == contracts.count)

        for contract in contracts {
            #expect(
                contract.scope == APIKeyScopeGuidance.optionalWriteDescriptor(for: contract.action).scope,
                "\(contract.consumer) drifted from its named API-key scope descriptor"
            )
        }
    }
}
