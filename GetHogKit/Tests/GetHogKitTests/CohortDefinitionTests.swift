import Foundation
import Testing

@testable import GetHogKit

/// What a cohort means, and the four different ways it can decline to say.
///
/// Every payload in this file is deterministic and synthetic. The first suite
/// reads `Fixtures/cohorts.json`; the remaining suites build focused shapes
/// inline for behavioural conditions, nested references, static cohorts,
/// calculation states, legacy `groups`, and analytical `query` definitions.
///
/// Those inline payloads are written to the OpenAPI document the same host serves
/// at `/api/schema/` — `CohortFilters`, `CohortFilterGroup`, `BehavioralFilter`,
/// `CohortFilter`, `PersonFilter`, and `PersonMetadataFilter`. They remain inline
/// because each isolates one contract edge more clearly than a combined fixture.
@Suite("Cohort definition — contract fixture")
struct CohortDefinitionCaptureTests {

    private func cohorts() throws -> [Cohort] {
        try Page<Cohort>.decode(from: Fixture.data("cohorts.json")).results
    }

    @Test("reads the filter tree off the list response, so opening one costs no request")
    func definitionArrivesOnTheList() throws {
        let cohort = try #require(try cohorts().first)
        let definition = try #require(cohort.definition)

        // The fixture shape: an outer OR of four groups, each holding one
        // person-property condition. PostHog wraps even a single condition in a
        // group, which is why the tree is three levels deep for what a reader
        // would call four rules.
        #expect(definition.root.combinator == .or)
        #expect(definition.root.conditions.count == 4)
        // Four leaves, eight nodes: `conditionCount` counts the rules a reader
        // would count, not the groups PostHog wraps each one in.
        #expect(definition.conditionCount == 4)
        #expect(definition.root.allConditions.count == 8)
        #expect(definition.unrenderableTypes.isEmpty)
        #expect(definition.filtersTestAccounts == nil)
    }

    @Test("phrases a scalar boolean condition without JSON syntax")
    func phrasesArrayWrappedBoolean() throws {
        let definition = try #require(try cohorts().first?.definition)
        guard case .group(let first) = definition.root.conditions[0],
              case .property(let condition) = first.conditions[0]
        else { Issue.record("expected a group holding one property condition"); return }

        #expect(first.combinator == .and)
        #expect(condition.key == "$example_review_user")
        #expect(condition.scope == .property)
        #expect(condition.comparison == "is")
        // This recording uses the scalar spelling. A renderer must still avoid
        // exposing JSON syntax or a Swift value description.
        #expect(condition.valueText == "false")
        #expect(condition.summary == "Person property $example_review_user is false")
    }

    @Test("phrases icontains as 'contains' rather than as its token")
    func phrasesContains() throws {
        let definition = try #require(try cohorts().first?.definition)
        guard case .group(let second) = definition.root.conditions[1],
              case .property(let condition) = second.conditions[0]
        else { Issue.record("expected a group holding one property condition"); return }

        #expect(condition.key == "contact_email")
        #expect(condition.comparison == "contains")
        #expect(condition.valueText == "@example.com")
    }

    @Test("a synthetic cohort with filters is in the renderable state")
    func stateIsFilters() throws {
        let cohort = try #require(try cohorts().first)
        guard case .filters(let definition) = cohort.definitionState else {
            Issue.record("expected .filters, got \(cohort.definitionState)")
            return
        }
        #expect(definition.conditionCount == 4)
        #expect(cohort.isStatic == false)
        #expect(cohort.isRecalculating == false)
        #expect(cohort.count == 27)
        #expect(cohort.lastCalculation != nil)
        #expect(cohort.errorsCalculating == 2)
        // `groups: []` on every cohort in the project — the legacy field is
        // echoed back empty rather than omitted, so an emptiness test is the one
        // that works and a presence test is not.
        #expect(cohort.hasLegacyGroups == false)
        #expect(cohort.isQueryDefined == false)
    }
}

/// The states a definition can be in when it is not a filter tree this build
/// draws. Payloads built to the served schema — see the note on the suite above.
@Suite("Cohort definition — the four states")
struct CohortDefinitionStateTests {

    private func cohort(_ json: String) throws -> Cohort {
        try JSONDecoder().decode(Cohort.self, from: Data(json.utf8))
    }

    @Test("a static cohort has no definition, and that is not a gap")
    func staticCohort() throws {
        let cohort = try cohort(
            #"{"id":1,"name":"Beta list","is_static":true,"count":42,"filters":null,"groups":[]}"#
        )
        #expect(cohort.definitionState == .staticMembership)
        #expect(cohort.definition == nil)
    }

    @Test("static wins over a query, because a snapshot is a snapshot however it was made")
    func staticWithQuery() throws {
        // What `create_static_cohort_for_flag` and the replay scanners produce:
        // a fixed list that still carries the query that selected it. Reading
        // that as "defined by SQL" would tell the reader the membership updates.
        let cohort = try cohort(
            #"{"id":2,"name":"Affected users","is_static":true,"query":{"kind":"ActorsQuery"}}"#
        )
        #expect(cohort.definitionState == .staticMembership)
        #expect(cohort.isQueryDefined == true)
    }

    @Test("an analytical cohort is unrenderable, not empty")
    func queryDefined() throws {
        let cohort = try cohort(
            #"{"id":3,"name":"Power users","is_static":false,"query":{"kind":"ActorsQuery"},"filters":{"properties":{"type":"AND","values":[]}}}"#
        )
        guard case .unrenderable(let reason) = cohort.definitionState else {
            Issue.record("expected .unrenderable, got \(cohort.definitionState)")
            return
        }
        #expect(reason.contains("SQL"))
        // The empty filter tree that rides along with an analytical cohort is
        // exactly the trap: rendered on its own it says "matches everyone".
        #expect(cohort.definition?.isEmpty == true)
    }

    @Test("a pre-migration cohort is unrenderable, not empty")
    func legacyGroups() throws {
        let cohort = try cohort(
            #"{"id":4,"name":"Old cohort","is_static":false,"groups":[{"days":30,"action_id":9}]}"#
        )
        guard case .unrenderable(let reason) = cohort.definitionState else {
            Issue.record("expected .unrenderable, got \(cohort.definitionState)")
            return
        }
        #expect(reason.contains("filter format"))
        #expect(cohort.hasLegacyGroups == true)
    }

    @Test("an empty filter tree on a dynamic cohort means everybody, and says so")
    func emptyTree() throws {
        let cohort = try cohort(
            #"{"id":5,"name":"All","is_static":false,"groups":[],"filters":{"properties":{"type":"AND","values":[]}}}"#
        )
        #expect(cohort.definitionState == .matchesEveryone)
    }

    @Test("calculating and pending-version are both 'this count is the old one'")
    func recalculating() throws {
        let live = try cohort(#"{"id":6,"name":"c","is_calculating":true,"version":3,"pending_version":3}"#)
        #expect(live.isRecalculating)

        // Saved but not evaluated: nothing is running, and the count is still
        // stale. `is_calculating` alone misses this.
        let queued = try cohort(#"{"id":7,"name":"c","is_calculating":false,"version":3,"pending_version":4}"#)
        #expect(queued.isRecalculating)

        let settled = try cohort(#"{"id":8,"name":"c","is_calculating":false,"version":4,"pending_version":4}"#)
        #expect(!settled.isRecalculating)

        // Absent versions must not read as pending — several PostHog responses
        // omit them.
        let unversioned = try cohort(#"{"id":9,"name":"c"}"#)
        #expect(!unversioned.isRecalculating)
    }
}

/// Conditions built as deterministic examples from the public schema.
@Suite("Cohort conditions")
struct CohortConditionTests {

    private func definition(_ propertiesJSON: String) throws -> CohortDefinition {
        let cohort = try JSONDecoder().decode(
            Cohort.self,
            from: Data(#"{"id":1,"name":"c","filters":{"properties":\#(propertiesJSON)}}"#.utf8)
        )
        return try #require(cohort.definition)
    }

    private func firstCondition(_ propertiesJSON: String) throws -> CohortCondition {
        let definition = try definition(propertiesJSON)
        return try #require(definition.root.conditions.first)
    }

    @Test("performed_event reads as a sentence, with its window")
    func performedEvent() throws {
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"behavioral","value":"performed_event",
            "key":"checkout_completed","event_type":"events","time_value":30,"time_interval":"day",
            "negation":false}]}
            """#
        )
        guard case .behavioural(let behaviour) = condition else {
            Issue.record("expected a behavioural condition, got \(condition)")
            return
        }
        #expect(behaviour.summary == "Has performed event checkout_completed in the last 30 days")
    }

    @Test("explicit_datetime supersedes the time_value pair rather than joining it")
    func explicitDatetimeWins() throws {
        // PostHog writes the newer spelling and leaves the old pair beside it;
        // rendering both produces "in the last 7 days in the last 30 days".
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"behavioral","value":"performed_event",
            "key":"$pageview","event_type":"events","time_value":30,"time_interval":"day",
            "explicit_datetime":"-7d"}]}
            """#
        )
        guard case .behavioural(let behaviour) = condition else {
            Issue.record("expected a behavioural condition"); return
        }
        #expect(behaviour.window == "in the last 7 days")
        #expect(behaviour.summary == "Has performed event $pageview in the last 7 days")
    }

    @Test("an explicit_datetime this build cannot parse is shown, not dropped")
    func unparsedExplicitDatetime() throws {
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"behavioral","value":"performed_event",
            "key":"$pageview","event_type":"events","explicit_datetime":"2025-06-18T00:00:00Z"}]}
            """#
        )
        guard case .behavioural(let behaviour) = condition else {
            Issue.record("expected a behavioural condition"); return
        }
        #expect(behaviour.window == "since 2025-06-18T00:00:00Z")
    }

    @Test("performed_event_multiple carries its count operator")
    func performedEventMultiple() throws {
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"behavioral","value":"performed_event_multiple",
            "key":"feature_used","event_type":"events","operator":"gte","operator_value":5,
            "time_value":1,"time_interval":"week"}]}
            """#
        )
        guard case .behavioural(let behaviour) = condition else {
            Issue.record("expected a behavioural condition"); return
        }
        // "at least 5 times", not "is at least 5 times" — the property
        // phrasing reads wrong inside a sentence, and did, on screen.
        #expect(behaviour.summary == "Has performed event feature_used at least 5 times in the last 1 week")
    }

    @Test("negation flips the subject rather than being dropped")
    func negatedBehaviour() throws {
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"behavioral","value":"performed_event",
            "key":"checkout","event_type":"events","time_value":90,"time_interval":"day",
            "negation":true}]}
            """#
        )
        guard case .behavioural(let behaviour) = condition else {
            Issue.record("expected a behavioural condition"); return
        }
        #expect(behaviour.summary.hasPrefix("Has not performed"))
    }

    @Test("an action names an action, because a key can be an integer id")
    func actionKind() throws {
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"behavioral","value":"performed_event",
            "key":91234,"event_type":"actions","time_value":30,"time_interval":"day"}]}
            """#
        )
        guard case .behavioural(let behaviour) = condition else {
            Issue.record("expected a behavioural condition"); return
        }
        #expect(behaviour.event == "91234")
        #expect(behaviour.summary == "Has performed action 91234 in the last 30 days")
    }

    @Test("a behavioural kind this build predates is named, never guessed at")
    func unknownBehaviouralKind() throws {
        // The failure mode this exists to prevent: falling through to
        // "performed", which describes a *different* test confidently.
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"behavioral","value":"performed_event_in_period",
            "key":"signed up","event_type":"events"}]}
            """#
        )
        guard case .behavioural(let behaviour) = condition else {
            Issue.record("expected a behavioural condition"); return
        }
        #expect(behaviour.summary.contains("performed_event_in_period"))
        #expect(!behaviour.summary.hasPrefix("Has performed event"))
    }

    @Test("a nested cohort reference resolves its name from cohorts already fetched")
    func cohortReference() throws {
        let definition = try definition(
            #"{"type":"AND","values":[{"type":"cohort","key":"id","value":4102,"negation":true}]}"#
        )
        guard case .cohortReference(let reference) = definition.root.conditions[0] else {
            Issue.record("expected a cohort reference"); return
        }
        #expect(reference.cohortID == 4102)
        #expect(reference.name == nil)
        #expect(reference.summary == "Is not in cohort #4102")

        let resolved = definition.resolvingCohortNames([4102: "Paying customers"])
        guard case .cohortReference(let named) = resolved.root.conditions[0] else {
            Issue.record("expected a cohort reference"); return
        }
        #expect(named.summary == "Is not in cohort Paying customers")
    }

    @Test("precalculated-cohort is the same idea as cohort, not an unknown type")
    func precalculatedCohort() throws {
        let condition = try firstCondition(
            #"{"type":"AND","values":[{"type":"precalculated-cohort","key":"id","value":77}]}"#
        )
        guard case .cohortReference(let reference) = condition else {
            Issue.record("expected a cohort reference, got \(condition)"); return
        }
        #expect(reference.cohortID == 77)
    }

    @Test("a person_metadata condition says it reads the record, not the properties")
    func personMetadata() throws {
        let condition = try firstCondition(
            #"""
            {"type":"AND","values":[{"type":"person_metadata","key":"created_at",
            "operator":"is_date_after","value":"2025-11-15"}]}
            """#
        )
        guard case .property(let property) = condition else {
            Issue.record("expected a property condition"); return
        }
        #expect(property.scope == .column)
        #expect(property.summary == "Person record created_at is after 2025-11-15")
    }

    @Test("is_set takes no right-hand side")
    func isSetTakesNoValue() throws {
        let condition = try firstCondition(
            #"{"type":"AND","values":[{"type":"person","key":"email","operator":"is_set","value":["is_set"]}]}"#
        )
        guard case .property(let property) = condition else {
            Issue.record("expected a property condition"); return
        }
        // PostHog echoes the operator name back as the value for these; printing
        // it produces "Email is set is_set".
        #expect(property.takesValue == false)
        #expect(property.valueText == nil)
        #expect(property.summary == "Person property email is set")
    }

    @Test("a list-valued exact condition reads as membership, not as equality")
    func multiValuedExact() throws {
        let condition = try firstCondition(
            #"{"type":"AND","values":[{"type":"person","key":"plan","operator":"exact","value":["pro","premium"]}]}"#
        )
        guard case .property(let property) = condition else {
            Issue.record("expected a property condition"); return
        }
        // "is pro, premium" is not a claim anybody can be true of. Photographed
        // exactly like that on `cohort-definition-rules` before this branch
        // existed.
        #expect(property.comparison == "is one of")
        #expect(property.summary == "Person property plan is one of pro, premium")

        // PostHog writes a single accepted value the same way. It is still "is".
        let single = try firstCondition(
            #"{"type":"AND","values":[{"type":"person","key":"plan","operator":"exact","value":["pro"]}]}"#
        )
        guard case .property(let one) = single else {
            Issue.record("expected a property condition"); return
        }
        #expect(one.comparison == "is")
    }

    @Test("an operator this build predates is shown, not rendered as 'is'")
    func unknownOperator() throws {
        let condition = try firstCondition(
            #"{"type":"AND","values":[{"type":"person","key":"app_version","operator":"semver_gte","value":"2.1.0"}]}"#
        )
        guard case .property(let property) = condition else {
            Issue.record("expected a property condition"); return
        }
        #expect(property.comparison == "semver gte")
        #expect(property.summary == "Person property app_version semver gte 2.1.0")
    }

    @Test("a condition type this build has no case for is named and counted")
    func unknownType() throws {
        let definition = try definition(
            #"""
            {"type":"AND","values":[
              {"type":"person","key":"email","operator":"icontains","value":"@example.com"},
              {"type":"data_warehouse","key":"stripe.customer","operator":"exact","value":"active"}
            ]}
            """#
        )
        // The renderable condition survives — one unknown sibling must not
        // discard the whole definition.
        #expect(definition.conditionCount == 2)
        #expect(definition.unrenderableTypes == ["data_warehouse"])
        guard case .unrenderable(let unknown) = definition.root.conditions[1] else {
            Issue.record("expected an unrenderable condition"); return
        }
        #expect(unknown.summary.contains("data_warehouse"))
    }

    @Test("filterTestAccounts is nil when absent, not false")
    func filterTestAccountsTriState() throws {
        let absent = try definition(#"{"type":"AND","values":[]}"#)
        #expect(absent.filtersTestAccounts == nil)

        let cohort = try JSONDecoder().decode(
            Cohort.self,
            from: Data(
                #"{"id":1,"name":"c","filters":{"filterTestAccounts":false,"properties":{"type":"AND","values":[]}}}"#
                    .utf8
            )
        )
        #expect(cohort.definition?.filtersTestAccounts == false)
    }

    @Test("deeply nested groups keep distinct identities for a ForEach")
    func nestedIdentity() throws {
        let definition = try definition(
            #"""
            {"type":"OR","values":[
              {"type":"AND","values":[{"type":"person","key":"a","operator":"exact","value":"1"}]},
              {"type":"AND","values":[{"type":"person","key":"a","operator":"exact","value":"1"}]}
            ]}
            """#
        )
        // Two structurally identical branches. Identity has to come from the
        // path, because the contents do not distinguish them and a duplicated id
        // in a `ForEach` drops a row.
        let ids = definition.root.allConditions.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("0.0.0"))
        #expect(ids.contains("0.1.0"))
    }
}

@Suite("Cohort members endpoint")
struct CohortMembersEndpointTests {

    @Test("members come from /persons/ with a cohort filter, not a path of their own")
    func membersEndpoint() {
        let endpoint = PostHogAPI.persons(projectID: 1_001, limit: 50, cohort: 730_101)
        #expect(endpoint.path == "/api/projects/1001/persons/")
        #expect(endpoint.query.contains { $0.name == "cohort" && $0.value == "730101" })
        #expect(endpoint.category == .analytics)
    }

    @Test("an unfiltered person list carries no cohort parameter")
    func noCohortParameter() {
        let endpoint = PostHogAPI.persons(projectID: 1_001, limit: 50)
        #expect(!endpoint.query.contains { $0.name == "cohort" })
    }

    @Test("the members response decodes without a count, because it has none")
    func membersPageHasNoCount() throws {
        // Cohort-member pages use the documented `{results, next, previous}`
        // shape without a total. Keeping `count` optional lets this public
        // response shape share the ordinary page decoder.
        let page = try Page<PersonSummary>.decode(
            from: Data(
                #"{"next":"https://app.example.com/api/projects/1001/persons/?cohort=2&limit=3&offset=3","previous":null,"results":[{"id":"018f9000-0000-7000-8000-000000000461","name":null,"distinct_ids":["abc"],"is_identified":false,"created_at":"2025-12-22T18:45:09.269000Z","properties":{}}]}"#
                    .utf8
            )
        )
        #expect(page.count == nil)
        #expect(page.results.count == 1)
        #expect(page.next != nil)
    }
}
