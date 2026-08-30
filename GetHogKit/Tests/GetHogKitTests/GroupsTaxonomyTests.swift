import Foundation
import Testing

@testable import GetHogKit

// Group analytics and the data taxonomy. Both use fictional project 1001 data
// shaped to exercise the documented response contracts.

@Suite("Group types")
struct GroupTypeTests {

    @Test("decodes the bare array the group types endpoint returns")
    func decodesBareArray() throws {
        // Not a `{results: []}` page: the viewset sets `pagination_class = None`,
        // so decoding this as `Page` would throw on every project.
        let types = try JSONDecoder().decode([GroupType].self, from: Fixture.data("groups_types.json"))

        #expect(types.count == 3)
        let workspace = try #require(types.first { $0.index == 0 })
        #expect(workspace.groupType == "workspace")
        #expect(workspace.pluralName == "Workspaces")
        #expect(workspace.singularName == "Workspace")
        #expect(workspace.createdAt != nil)
        #expect(workspace.defaultColumns == ["group_name", "key", "created_at"])
    }

    @Test("falls back to the raw group type when no display names are set")
    func fallsBackToRawType() throws {
        let types = try JSONDecoder().decode([GroupType].self, from: Fixture.data("groups_types.json"))
        let untitled = try #require(types.first { $0.index == 1 })

        // `name_singular` / `name_plural` are null until someone renames the type
        // in PostHog, which is the normal state for a type created by the SDK.
        #expect(untitled.singularName == "example-team")
        #expect(untitled.pluralName == "example-team")
        #expect(untitled.defaultColumns.isEmpty)
    }

    @Test("sorts by index so the list order matches PostHog's own")
    func sortsByIndex() throws {
        let types = try JSONDecoder().decode([GroupType].self, from: Fixture.data("groups_types.json"))
        #expect(types.sorted().map(\.index) == [0, 1, 2])
    }
}

@Suite("Groups query")
struct GroupsQueryTests {

    @Test("reads the display name out of the group_name dictionary")
    func decodesGroupNameDictionary() throws {
        // The trap this suite exists for: `group_name` is a two-field object,
        // not a string. Decoding it as a String silently yields a blank column.
        let response = try QueryResponse.decode(from: Fixture.data("groups_query.json"))
        let groups = response.rows.compactMap(GroupRow.init(row:))

        #expect(groups.count == 4)
        #expect(groups[0].displayName == "Cobalt Research Lab")
        #expect(groups[0].key == "group-example-cobalt")
        #expect(groups[0].createdAt != nil)
    }

    @Test("falls back to the key when a group has no name property")
    func fallsBackToKey() throws {
        let response = try QueryResponse.decode(from: Fixture.data("groups_query.json"))
        let groups = response.rows.compactMap(GroupRow.init(row:))
        let unnamed = try #require(groups.last)

        #expect(unnamed.displayName == unnamed.key)
        #expect(unnamed.hasDisplayName == false)
    }

    @Test("parses group properties whether they arrive as a JSON string or an object")
    func parsesPropertiesEitherWay() throws {
        // ClickHouse hands `properties` back as a raw JSON string, but the query
        // API has returned it pre-parsed before. Handling only one shape loses the
        // whole property tree on the other.
        let response = try QueryResponse.decode(from: Fixture.data("groups_query.json"))
        let fromString = try #require(response.rows.compactMap(GroupRow.init(row:)).first)
        #expect(fromString.properties?["subdomain"]?.stringValue == "cobalt-lab.example.com")
        #expect(fromString.propertyCount == 2)

        let objectForm = """
        {"columns": ["group_name", "key", "created_at", "properties"],
         "results": [[{"display_name": "Cobalt Labs", "key": "k1"}, "k1", "2025-12-16T00:00:00.000Z",
                     {"name": "Cobalt Labs", "subdomain": "cobalt-labs"}]]}
        """
        let parsed = try QueryResponse.decode(from: Data(objectForm.utf8))
        let fromObject = try #require(parsed.rows.compactMap(GroupRow.init(row:)).first)
        #expect(fromObject.properties?["subdomain"]?.stringValue == "cobalt-labs")
        #expect(fromObject.propertyCount == 2)
    }

    @Test("survives a group with no properties at all")
    func toleratesMissingProperties() throws {
        let json = """
        {"columns": ["group_name", "key", "created_at"],
         "results": [[{"display_name": "Solo", "key": "k9"}, "k9", "2025-12-16T00:00:00.000Z"]]}
        """
        let response = try QueryResponse.decode(from: Data(json.utf8))
        let group = try #require(response.rows.compactMap(GroupRow.init(row:)).first)

        #expect(group.displayName == "Solo")
        #expect(group.properties == nil)
        #expect(group.propertyCount == 0)
    }

    @Test("drops a row that carries no key, since nothing can be shown for it")
    func dropsKeylessRow() throws {
        let json = #"{"columns": ["group_name", "key"], "results": [[null, null]]}"#
        let response = try QueryResponse.decode(from: Data(json.utf8))
        #expect(response.rows.compactMap(GroupRow.init(row:)).isEmpty)
    }
}

@Suite("Team taxonomy")
struct TeamTaxonomyTests {

    @Test("decodes the event volume list")
    func decodesVolumes() throws {
        // TeamTaxonomyQuery answers with objects, not the positional arrays that
        // GroupsQuery uses, so `Page` is the right envelope here.
        let page = try Page<TaxonomyEventVolume>.decode(from: Fixture.data("team_taxonomy.json"))

        #expect(page.results.count == 10)
        #expect(page.results.first?.event == "feature_used")
        #expect(page.results.first?.count == 12)
    }

    @Test("keeps zero-count rows distinguishable from events with volume")
    func separatesZeroCountRows() throws {
        // PostHog pads the response with its well-known event names at count 0
        // when the page is the last one. Those are events this project has never
        // sent — counting them as "events we have" would be wrong.
        let page = try Page<TaxonomyEventVolume>.decode(from: Fixture.data("team_taxonomy.json"))

        #expect(page.results.filter(\.wasSeen).count == 7)
        #expect(page.results.filter { !$0.wasSeen }.map(\.event)
            == ["account_created", "$survey_sent", "$survey_response"])
    }
}

@Suite("Event taxonomy")
struct EventTaxonomyTests {

    @Test("decodes properties with their sample values")
    func decodesProperties() throws {
        let page = try Page<TaxonomyPropertySample>.decode(from: Fixture.data("event_taxonomy.json"))

        #expect(page.results.count == 6)
        let channel = try #require(page.results.first)
        #expect(channel.property == "$fixture_channel")
        #expect(channel.sampleValues.count == 4)
        // `sample_count` is bounded by the recent sample and is never a total
        // occurrence count.
        #expect(channel.sampleCount == 41)
        #expect(channel.sampleSummary == "41 distinct values in sample")
    }

    @Test("keeps a singular summary readable")
    func singularSummary() throws {
        let page = try Page<TaxonomyPropertySample>.decode(from: Fixture.data("event_taxonomy.json"))
        let single = TaxonomyPropertySample(property: "x", sampleCount: 1, sampleValues: ["only"])

        #expect(single.sampleSummary == "1 distinct value in sample")
        #expect(page.results.contains { $0.property == "harbor_region" })
    }
}

@Suite("Taxonomy definitions")
struct TaxonomyDefinitionTests {

    @Test("decodes event definitions with their curation state")
    func decodesEventDefinitions() throws {
        let page = try Page<EventDefinitionSummary>.decode(from: Fixture.data("event_definitions.json"))

        #expect(page.count == 5)
        #expect(page.results.count == 5)
        #expect(page.results[0].name == "cache_warmed")
        #expect(page.results[0].isVerified)
        #expect(page.results[0].isHidden == false)
        #expect(page.results[0].lastSeenAt != nil)
        #expect(page.results[2].isHidden)
        #expect(page.results[3].tags == ["legacy", "retired-fixture"])
    }

    @Test("decodes property definitions with their type and curation state")
    func decodesPropertyDefinitions() throws {
        let page = try Page<PropertyDefinitionSummary>.decode(from: Fixture.data("property_definitions.json"))

        #expect(page.count == 779)
        #expect(page.results[0].name == "account_tier")
        #expect(page.results[0].propertyType == "String")
        #expect(page.results[0].isVerified)
        #expect(page.results[1].isNumerical)
        // `property_type` is genuinely null for properties PostHog has not typed,
        // and "Unknown" would be a claim the API never made.
        #expect(page.results[2].propertyType == nil)
        #expect(page.results[2].isHidden)
    }
}

@Suite("Taxonomy merge")
struct TaxonomyMergeTests {

    private static func volumes() throws -> [TaxonomyEventVolume] {
        try Page<TaxonomyEventVolume>.decode(from: Fixture.data("team_taxonomy.json")).results
    }

    private static func definitions() throws -> [EventDefinitionSummary] {
        try Page<EventDefinitionSummary>.decode(from: Fixture.data("event_definitions.json")).results
    }

    @Test("ranks events with volume first and highest first")
    func ranksByVolume() throws {
        let merged = TaxonomyEvent.merge(volumes: try Self.volumes(), definitions: try Self.definitions())
        let active = merged.filter { $0.status == .active }

        #expect(active.map(\.name).prefix(3) == ["export_started", "checkout_submitted", "feature_used"])
        #expect(active.count == 7)
    }

    @Test("joins the definition's curation state onto the event by name")
    func joinsDefinitions() throws {
        let merged = TaxonomyEvent.merge(volumes: try Self.volumes(), definitions: try Self.definitions())
        let hint = try #require(merged.first { $0.name == "setup_hint_viewed" })

        #expect(hint.isVerified)
        #expect(hint.recentCount == 3)
        #expect(hint.description == "A fictional navigation event used by fixture tests.")

        let feature = try #require(merged.first { $0.name == "feature_used" })
        #expect(feature.isHidden)
    }

    @Test("keeps a defined event that has gone quiet, and says so")
    func surfacesQuietEvents() throws {
        // `$survey_response` is in the definitions but absent from the
        // 30-day taxonomy: it was sent once and then stopped. Dropping it would
        // hide exactly the thing someone auditing a taxonomy is looking for.
        let merged = TaxonomyEvent.merge(volumes: try Self.volumes(), definitions: try Self.definitions())
        let quiet = try #require(merged.first { $0.name == "$survey_response" })

        #expect(quiet.status == .quiet)
        #expect(quiet.recentCount == 0)
        #expect(quiet.lastSeenAt != nil)
    }

    @Test("marks a padded well-known event as never sent, not as quiet")
    func marksNeverSentEvents() throws {
        let merged = TaxonomyEvent.merge(volumes: try Self.volumes(), definitions: try Self.definitions())
        let padded = merged.filter { $0.status == .neverSent }

        #expect(padded.map(\.name) == ["$survey_sent", "account_created"])
        #expect(padded.allSatisfy { $0.recentCount == 0 })
    }

    @Test("treats every zero-count row as quiet when definitions failed to load")
    func degradesWithoutDefinitions() throws {
        // Without the definitions list there is no evidence that an event was
        // never sent, so nothing may be labelled that way.
        let merged = TaxonomyEvent.merge(volumes: try Self.volumes(), definitions: [])

        #expect(merged.contains { $0.name == "account_created" && $0.status == .quiet })
        #expect(merged.allSatisfy { $0.status != .neverSent })
    }
}

@Suite("Group and taxonomy endpoints")
struct GroupsTaxonomyEndpointTests {

    @Test("builds the group types endpoint")
    func groupTypes() {
        let endpoint = PostHogAPI.groupTypes(projectID: 1_001)
        #expect(endpoint.path == "/api/projects/1001/groups_types/")
        #expect(endpoint.method == "GET")
        #expect(endpoint.category == .crud)
    }

    @Test("asks GroupsQuery for properties, never group_properties")
    func groupsQueryColumns() throws {
        let endpoint = PostHogAPI.groups(projectID: 1_001, groupTypeIndex: 0, limit: 50)
        let body = try #require(endpoint.body).decodedString

        #expect(endpoint.path == "/api/projects/1001/query/")
        #expect(endpoint.method == "POST")
        #expect(endpoint.category == .query)
        #expect(body.contains("GroupsQuery"))
        #expect(body.contains("group_name"))
        // `group_properties` is rejected with HTTP 400: "Unable to resolve field".
        #expect(!body.contains("group_properties"))
        #expect(body.contains("\"properties\""))
        #expect(body.contains("\"group_type_index\":0"))
    }

    @Test("builds the taxonomy query endpoints")
    func taxonomyQueries() throws {
        let team = PostHogAPI.teamTaxonomy(projectID: 1_001)
        #expect(team.category == .query)
        #expect(try #require(team.body).decodedString.contains("TeamTaxonomyQuery"))

        let event = PostHogAPI.eventTaxonomy(projectID: 1_001, event: "$pageview", maxPropertyValues: 3)
        let body = try #require(event.body).decodedString
        #expect(body.contains("EventTaxonomyQuery"))
        #expect(body.contains("$pageview"))
        #expect(body.contains("\"maxPropertyValues\":3"))
    }

    @Test("scopes property definitions to one event so the join stays small")
    func propertyDefinitionsScoping() throws {
        let endpoint = PostHogAPI.propertyDefinitions(projectID: 1_001, eventNames: ["$pageview"], limit: 200)

        #expect(endpoint.path == "/api/projects/1001/property_definitions/")
        #expect(endpoint.category == .crud)
        // `event_names` is JSON-encoded, not repeated query items — the viewset
        // runs `json.loads` on it.
        #expect(endpoint.query.contains { $0.name == "event_names" && $0.value == "[\"$pageview\"]" })
        #expect(endpoint.query.contains { $0.name == "filter_by_event_names" && $0.value == "true" })
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "200" })
    }

    @Test("omits the event scoping when no event is named")
    func propertyDefinitionsUnscoped() {
        let endpoint = PostHogAPI.propertyDefinitions(projectID: 1_001)
        #expect(!endpoint.query.contains { $0.name == "event_names" })
        #expect(!endpoint.query.contains { $0.name == "filter_by_event_names" })
    }

    @Test("builds the event definitions endpoint")
    func eventDefinitions() {
        let endpoint = PostHogAPI.eventDefinitions(projectID: 1_001, limit: 300)
        #expect(endpoint.path == "/api/projects/1001/event_definitions/")
        #expect(endpoint.category == .crud)
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "300" })
    }

    @Test("never asks either definitions endpoint to exclude hidden entries")
    func neverExcludesHidden() {
        // Both endpoints declare `exclude_hidden` with a default of `false`, so
        // hidden definitions arrive and each row states its own state. Sending
        // `true` would make a hidden definition vanish from the list, which
        // reads as "this project has no such event" — the wrong claim, where the
        // pill is the right one.
        let events = PostHogAPI.eventDefinitions(projectID: 1_001)
        let properties = PostHogAPI.propertyDefinitions(projectID: 1_001)
        #expect(!events.query.contains { $0.name == "exclude_hidden" })
        #expect(!properties.query.contains { $0.name == "exclude_hidden" })
    }

    @Test("scopes property definitions to one table when asked")
    func propertyDefinitionScopes() {
        // `type` defaults to `event` server-side — measured, and declared
        // `"default": "event"` in the instance's own OpenAPI document — so the
        // unscoped call and the `.event` call are the same question.
        #expect(!PostHogAPI.propertyDefinitions(projectID: 1_001).query.contains { $0.name == "type" })

        let person = PostHogAPI.propertyDefinitions(projectID: 1_001, scope: .person)
        #expect(person.query.contains { $0.name == "type" && $0.value == "person" })
        #expect(!person.query.contains { $0.name == "group_type_index" })

        // The index is a second parameter rather than part of `type`, and it
        // travels only for a group scope.
        let group = PostHogAPI.propertyDefinitions(projectID: 1_001, scope: .group(index: 2))
        #expect(group.query.contains { $0.name == "type" && $0.value == "group" })
        #expect(group.query.contains { $0.name == "group_type_index" && $0.value == "2" })
    }

    @Test("names properties on the taxonomy query, which changes what it measures")
    func namedPropertyTaxonomy() throws {
        let endpoint = PostHogAPI.eventTaxonomy(
            projectID: 1_001,
            event: "$pageview",
            properties: ["$browser", "$os"],
            maxPropertyValues: 10
        )
        let body = try #require(endpoint.body).decodedString

        #expect(body.contains("EventTaxonomyQuery"))
        #expect(body.contains("$browser"))
        #expect(body.contains("\"maxPropertyValues\":10"))
        // The event is not optional here. Omitting it is HTTP 500, not an empty
        // result across every event, so there is no builder that can produce it.
        #expect(body.contains("\"event\":\"$pageview\""))
    }

    @Test("spells the actor taxonomy's group index in camel case")
    func actorTaxonomyGroupIndex() throws {
        // The one that would be written wrong by pattern-matching `GroupsQuery`
        // in the same file: this node takes `groupTypeIndex`, and the snake-cased
        // spelling is a pydantic 400 — `Extra inputs are not permitted`.
        let group = PostHogAPI.actorsPropertyTaxonomy(projectID: 1_001, properties: ["name"], groupTypeIndex: 0)
        let body = try #require(group.body).decodedString
        #expect(body.contains("\"groupTypeIndex\":0"))
        #expect(!body.contains("group_type_index"))

        // Omitted entirely for persons, which is a different table rather than
        // an error, so a nil index must not become a zero.
        let person = PostHogAPI.actorsPropertyTaxonomy(projectID: 1_001, properties: ["email"])
        #expect(!(try #require(person.body).decodedString.contains("groupTypeIndex")))
    }
}

@Suite("Group scoping")
struct GroupScopingTests {

    @Test("scopes on the events table's own group column")
    func groupColumn() {
        #expect(PostHogAPI.groupColumn(index: 0) == "$group_0")
        #expect(PostHogAPI.groupColumn(index: 4) == "$group_4")
    }

    @Test("escapes a group key into the scoping clause")
    func escapesGroupKey() {
        // Group keys are opaque strings chosen by whoever called `group()` in an
        // SDK, so a quote in one is a real possibility rather than an attack.
        let clause = PostHogAPI.groupClause(index: 1, key: "o'brien-co")
        #expect(clause == #"$group_1 = 'o\'brien-co'"#)
    }

    @Test("bounds the group activity query and carries its own totals")
    func groupBreakdownSQL() throws {
        let endpoint = PostHogAPI.groupEventBreakdown(
            projectID: 1_001,
            groupTypeIndex: 0,
            groupKey: "acme",
            since: Date(timeIntervalSince1970: 1_700_000_000),
            limit: 12
        )
        let body = try #require(endpoint.body).decodedString

        #expect(endpoint.category == .query)
        #expect(body.contains("$group_0 = 'acme'"))
        // The time bound is not optional. An unbounded scan of a shared `events`
        // table denies partition pruning and has been measured failing outright.
        #expect(body.contains("timestamp > toDateTime64("))
        #expect(body.contains("LIMIT 12"))
        // A HogQL query that writes its own LIMIT gets no `hasMore` back, so the
        // window totals are the only truncation evidence there is.
        #expect(body.contains("sum(count()) OVER ()"))
        #expect(body.contains("uniqExact(event) OVER ()"))
    }

    @Test("writes the group feed through the events feed's own SQL")
    func groupEventsSQL() throws {
        let endpoint = PostHogAPI.groupEvents(
            projectID: 1_001,
            groupTypeIndex: 0,
            groupKey: "acme",
            eventName: "$rageclick",
            since: Date(timeIntervalSince1970: 1_700_000_000),
            limit: 50
        )
        let body = try #require(endpoint.body).decodedString

        #expect(body.contains("$group_0 = 'acme'"))
        #expect(body.contains("event = '$rageclick'"))
        // Written through `eventsSQL`, so the tie-safe ordering the main feed
        // learned the hard way cannot be missing here: timestamps are not
        // unique and a page boundary through a tie drops the remainder.
        #expect(body.contains("ORDER BY timestamp DESC, uuid DESC"))
        #expect(body.contains("SELECT uuid, event, timestamp, distinct_id"))

        // No name is the whole feed for the group, not a filter on empty string.
        let unfiltered = PostHogAPI.groupEvents(
            projectID: 1_001,
            groupTypeIndex: 0,
            groupKey: "acme",
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(!(try #require(unfiltered.body).decodedString.contains("event = '")))
    }

    @Test("reads the group's people through the person-on-events join")
    func groupPeopleSQL() throws {
        let endpoint = PostHogAPI.groupPeople(
            projectID: 1_001,
            groupTypeIndex: 1,
            groupKey: "acme",
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = try #require(endpoint.body).decodedString

        #expect(body.contains("$group_1 = 'acme'"))
        #expect(body.contains("person.properties.email"))
        #expect(body.contains("uniqExact(person_id) OVER ()"))
        #expect(body.contains("timestamp > toDateTime64("))
    }

    @Test("filters recordings on the group column as an event property")
    func groupRecordingFilter() throws {
        let filter = PostHogAPI.groupRecordingFilter(groupTypeIndex: 0, groupKey: "acme")
        let items = filter.queryItems
        let properties = try #require(items.first { $0.name == "properties" }?.value)

        // The measured shape. `{"type": "group", "group_type_index": 0}` filters
        // the group's own properties instead and matched nothing at any key.
        #expect(properties.contains("\"key\":\"$group_0\""))
        #expect(properties.contains("\"type\":\"event\""))
        #expect(properties.contains("\"acme\""))
        // Without a window the list falls back to about three days and reports
        // an empty result for a group that simply has none this week.
        #expect(items.contains { $0.name == "date_from" && $0.value == "-30d" })
    }

    @Test("an all-time group recording request keeps the all-retention lower bound")
    func allTimeWindowStaysAllTime() {
        let filter = PostHogAPI.groupRecordingFilter(
            groupTypeIndex: 0,
            groupKey: "acme",
            window: .allTime
        )
        #expect(filter.dateWindow == .allTime)
        #expect(filter.queryItems.contains {
            $0.name == "date_from" && $0.value == "1970-01-01T00:00:00Z"
        })
    }

    @Test("bills the group recordings list against the analytics budget")
    func groupRecordingsCategory() {
        let endpoint = PostHogAPI.groupRecordings(projectID: 1_001, groupTypeIndex: 0, groupKey: "acme")
        #expect(endpoint.path == "/api/projects/1001/session_recordings/")
        #expect(endpoint.category == .analytics)
    }

    @Test("reads a breakdown row and its shares")
    func decodesBreakdownRow() throws {
        let json = """
        {"columns": ["event", "occurrences", "people", "last_seen", "total_occurrences", "distinct_events"],
         "results": [["$autocapture", 1067, 5, "2026-01-08T19:59:25.000Z", 2222, 17],
                     ["$pageview", 233, 5, "2026-01-08T19:59:04.000Z", 2222, 17]]}
        """
        let rows = try QueryResponse.decode(from: Data(json.utf8)).rows
            .compactMap(GroupEventBreakdownRow.init(row:))

        #expect(rows.count == 2)
        #expect(rows[0].event == "$autocapture")
        #expect(rows[0].people == 5)
        #expect(rows[0].lastSeen != nil)
        // The share is of the group's own total, taken from the window function
        // rather than from the sum of the rows on screen.
        let share = try #require(rows[0].share)
        #expect(abs(share - 1067.0 / 2222.0) < 0.0001)
        // 17 names exist, 2 arrived.
        #expect(GroupEventBreakdownRow.hiddenEventCount(rows) == 15)
    }

    @Test("declines to divide by a total it does not have")
    func breakdownWithoutTotal() throws {
        let json = #"{"columns": ["event", "occurrences"], "results": [["$pageview", 0]]}"#
        let row = try #require(
            QueryResponse.decode(from: Data(json.utf8)).rows
                .compactMap(GroupEventBreakdownRow.init(row:)).first
        )
        // `total_occurrences` falls back to the row's own count, and a zero count
        // leaves nothing to divide by — `nil`, so a caller draws no bar rather
        // than a 0% one.
        #expect(row.share == nil)
        #expect(GroupEventBreakdownRow.hiddenEventCount([row]) == 0)
    }

    @Test("names a person by what the row actually knows")
    func decodesPersonRow() throws {
        let json = """
        {"columns": ["person_id", "distinct_id", "email", "name", "occurrences", "last_seen", "distinct_people"],
         "results": [["p-1", "d-1", "example.operator@example.org", "Sam Ash", 1015, "2026-01-08T20:00:17.000Z", 6],
                     ["p-2", "d-2", "", "", 12, "2025-12-16T00:00:00.000Z", 6]]}
        """
        let rows = try QueryResponse.decode(from: Data(json.utf8)).rows
            .compactMap(GroupPersonRow.init(row:))

        #expect(rows[0].displayName == "Sam Ash")
        #expect(rows[0].hasHumanName)
        // PostHog returns `''` rather than null for an unset person property read
        // through the join, and an empty string rendered as a name is a blank row.
        #expect(rows[1].email == nil)
        #expect(rows[1].displayName == "d-2")
        #expect(rows[1].hasHumanName == false)
        #expect(GroupPersonRow.hiddenPersonCount(rows) == 4)
    }

    @Test("falls all the way back to the person uuid rather than inventing a name")
    func personWithNothingButAnID() throws {
        let json = #"{"columns": ["person_id"], "results": [["p-9"]]}"#
        let row = try #require(
            QueryResponse.decode(from: Data(json.utf8)).rows
                .compactMap(GroupPersonRow.init(row:)).first
        )
        #expect(row.displayName == "p-9")
        #expect(row.hasHumanName == false)
    }
}

@Suite("Property depth")
struct PropertyDepthTests {

    @Test("bounds the distribution query and can widen past one event")
    func distributionSQL() throws {
        let scoped = PostHogAPI.propertyValueDistribution(
            projectID: 1_001,
            property: "$browser",
            event: "$pageview",
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = try #require(scoped.body).decodedString

        // Bracket syntax, not a `properties.foo` path: a property key is
        // arbitrary text and only the bracket form takes one as a literal.
        #expect(body.contains("properties['$browser']"))
        #expect(body.contains("JSONHas(properties, '$browser')"))
        #expect(body.contains("event = '$pageview'"))
        #expect(body.contains("sum(count()) OVER ()"))
        // The null group has to be added back by hand: `uniqExact` drops SQL
        // nulls, and a JSON-null value survives `JSONHas`. Measured on
        // `utm_source`, four groups come back and a bare `uniqExact` says three,
        // which would lose one value from the "N more not shown" claim.
        #expect(body.contains("uniqExact(properties['$browser']) OVER ()"))
        #expect(body.contains("max(if(isNull(properties['$browser']), 1, 0)) OVER ()"))

        // Project-wide is a real question and the reason this is HogQL: the
        // taxonomy query's eventless form answers HTTP 500.
        let wide = PostHogAPI.propertyValueDistribution(
            projectID: 1_001,
            property: "$browser",
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(!(try #require(wide.body).decodedString.contains("event = ")))
    }

    @Test("escapes a property key with a quote in it")
    func escapesPropertyKey() throws {
        let endpoint = PostHogAPI.propertyValueDistribution(
            projectID: 1_001,
            property: "it's set",
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = try #require(endpoint.body).decodedString
        // JSON-encoded inside the request body, so the backslash is doubled here
        // and reaches HogQL as one.
        #expect(body.contains(#"properties['it\\'s set']"#))
    }

    @Test("asks which events carry a property, project-wide")
    func carrierSQL() throws {
        let endpoint = PostHogAPI.propertyCarrierEvents(
            projectID: 1_001,
            property: "$browser",
            since: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = try #require(endpoint.body).decodedString

        #expect(body.contains("GROUP BY event"))
        // The per-event distinct count is the point of the section: a definition
        // is project-wide and says nothing about how varied a key is on one
        // event. Unwindowed here — it is per `GROUP BY` row, not per query — and
        // carrying the same null correction the distribution needs.
        #expect(body.contains("uniqExact(properties['$browser'])"))
        #expect(body.contains("max(if(isNull(properties['$browser']), 1, 0)) AS distinct_values"))
        #expect(body.contains("uniqExact(event) OVER ()"))
        #expect(body.contains("timestamp > toDateTime64("))
    }

    @Test("reads a value distribution and its shares")
    func decodesDistribution() throws {
        let json = """
        {"columns": ["value", "occurrences", "total_occurrences", "distinct_values"],
         "results": [["Chrome", 25494, 28966, 8], ["Mobile Safari", 1952, 28966, 8]]}
        """
        let rows = try QueryResponse.decode(from: Data(json.utf8)).rows
            .compactMap(PropertyValueShare.init(row:))

        #expect(rows.count == 2)
        #expect(rows[0].value == "Chrome")
        let share = try #require(rows[0].share)
        #expect(abs(share - 25494.0 / 28966.0) < 0.0001)
        #expect(PropertyValueShare.hiddenValueCount(rows) == 6)
    }

    @Test("keeps a JSON null apart from the string null")
    func nullValueIsNotTheWordNull() throws {
        // A property present but holding JSON null, and a property holding the
        // four characters `null`, are different facts about the data and a
        // reader writing a filter needs to know which they have.
        let json = """
        {"columns": ["value", "occurrences", "total_occurrences", "distinct_values"],
         "results": [[null, 4, 10, 2], ["null", 6, 10, 2]]}
        """
        let rows = try QueryResponse.decode(from: Data(json.utf8)).rows
            .compactMap(PropertyValueShare.init(row:))

        #expect(rows[0].value == nil)
        #expect(rows[1].value == "null")
        #expect(rows[0].id != rows[1].id)
    }

    @Test("reads the events that carry a property")
    func decodesCarriers() throws {
        let json = """
        {"columns": ["event", "occurrences", "distinct_values", "total_occurrences", "distinct_events"],
         "results": [["$autocapture", 12508, 7, 29414, 40], ["$pageview", 3319, 8, 29414, 40]]}
        """
        let rows = try QueryResponse.decode(from: Data(json.utf8)).rows
            .compactMap(PropertyCarrierEvent.init(row:))

        #expect(rows[0].distinctValues == 7)
        #expect(rows[1].distinctValues == 8)
        #expect(PropertyCarrierEvent.hiddenEventCount(rows) == 38)
    }

    @Test("says which table can answer a distribution at all")
    func scopeDistribution() {
        #expect(PropertyScope.event.hasEventDistribution)
        #expect(!PropertyScope.person.hasEventDistribution)
        #expect(!PropertyScope.group(index: 0).hasEventDistribution)
        #expect(!PropertyScope.session.hasEventDistribution)
        #expect(PropertyScope.group(index: 3).parameterValue == "group")
    }

    @Test("pairs a positional taxonomy response back to the keys that were asked for")
    func zipsPositionalRows() {
        // Naming the properties makes the response drop the `property` key, so
        // the rows are parallel to the request array. A property with nothing
        // recorded holds its place rather than being dropped, which is what makes
        // the pairing safe.
        let rows = [
            TaxonomyPropertySample(property: "", sampleCount: 51, sampleValues: ["a", "b"]),
            TaxonomyPropertySample(property: "", sampleCount: 0, sampleValues: []),
        ]
        let zipped = TaxonomyPropertySample.zip(["name", "industry"], with: rows)

        #expect(zipped.map(\.property) == ["name", "industry"])
        #expect(zipped[0].sampleCount == 51)
        #expect(zipped[1].sampleValues.isEmpty)
    }

    @Test("drops surplus keys rather than pairing them with the wrong row")
    func zipRefusesToGuess() {
        // A response shorter than the request is a shape this code does not
        // understand. Pairing key 2 with row 1 would put one property's values
        // under another property's name, which is worse than showing neither.
        let zipped = TaxonomyPropertySample.zip(
            ["a", "b", "c"],
            with: [TaxonomyPropertySample(property: "", sampleCount: 3, sampleValues: ["x"])]
        )
        #expect(zipped.map(\.property) == ["a"])
    }
}

private extension Data {
    var decodedString: String { String(decoding: self, as: UTF8.self) }
}
