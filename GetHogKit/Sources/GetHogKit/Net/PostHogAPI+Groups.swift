import Foundation

/// Group analytics and the data taxonomy.
///
/// Two features, one file, because they land together and both mix a `/query/`
/// node with a plain CRUD listing. The listings bill against `.crud`; only the
/// query nodes actually compute anything, so only they bill against `.query`.
public extension PostHogAPI {

    // MARK: - Group analytics

    /// A project's defined group types.
    ///
    /// Answers with a **bare JSON array**, not a `{count, results}` page — the
    /// viewset sets `pagination_class = None`, so there is nothing to paginate
    /// and no `limit` to pass. Decode as `[GroupType]`.
    static func groupTypes(projectID: Int) -> Endpoint {
        Endpoint(path: "/api/projects/\(projectID)/groups_types/", category: .crud)
    }

    /// The groups of one type, newest first.
    ///
    /// `group_name` is a synthetic column the query runner builds and then
    /// rewrites into `{"display_name": ..., "key": ...}`; `properties` is the
    /// real column name — asking for `group_properties` is answered with
    /// HTTP 400 "Unable to resolve field: group_properties".
    static func groups(
        projectID: Int,
        groupTypeIndex: Int,
        limit: Int = 100,
        offset: Int = 0
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "GroupsQuery",
            "group_type_index": groupTypeIndex,
            "select": ["group_name", "key", "created_at", "properties"],
            "orderBy": ["created_at DESC"],
            "limit": limit,
            "offset": offset,
        ])
    }

    // MARK: - Data taxonomy

    /// Every event received in the **last 30 days**, with its volume.
    ///
    /// The window is fixed in PostHog's query runner and is not a parameter. On
    /// the last page the runner also appends its well-known event names at
    /// `count: 0`, including ones this project has never sent — so the row count
    /// is not the number of events the project has.
    static func teamTaxonomy(projectID: Int) -> Endpoint {
        queryEndpoint(projectID: projectID, query: ["kind": "TeamTaxonomyQuery"])
    }

    /// The properties seen on one event, with a few values for each.
    ///
    /// Sampled, not exhaustive: the runner reads the 100 most recent matching
    /// events from the last 30 days and reports what it finds in that slice. It
    /// also omits `$set`, `$ip`, `distinct_id` and `$feature/*` by design.
    ///
    /// That sampling applies **only** to this form. Naming the properties
    /// explicitly takes a different code path — see `eventTaxonomy(_:event:
    /// properties:)` below, whose `sample_count` is not a sample at all.
    static func eventTaxonomy(
        projectID: Int,
        event: String,
        maxPropertyValues: Int = 3
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "EventTaxonomyQuery",
            "event": event,
            "maxPropertyValues": maxPropertyValues,
        ])
    }

    /// The values of **named** properties on one event.
    ///
    /// The same query kind as the discovery form above, but naming properties
    /// returns positional `sample_count` and frequency-ordered `sample_values`
    /// for the event window. Counts per value are not included, which is why a
    /// value distribution uses HogQL instead. The response rows carry no
    /// `property` key: they are positional and
    ///   parallel to the `properties` array that was sent, and a property with
    ///   nothing recorded holds its place as `{"sample_count": 0,
    ///   "sample_values": []}` rather than being dropped — so the caller zips by
    ///   index. `TaxonomyPropertySample.zip(_:with:)` is that join.
    static func eventTaxonomy(
        projectID: Int,
        event: String,
        properties: [String],
        maxPropertyValues: Int = 10
    ) -> Endpoint {
        queryEndpoint(projectID: projectID, query: [
            "kind": "EventTaxonomyQuery",
            "event": event,
            "properties": properties,
            "maxPropertyValues": maxPropertyValues,
        ])
    }

    /// The values of a person or group property, sampled from the actor table.
    ///
    /// The actor-side counterpart to `eventTaxonomy`, and the only thing that
    /// answers for a property that lives on a person or a group rather than on
    /// an event. Results are positional and parallel to `properties`, exactly
    /// like the event form; an empty property holds its place with zero samples.
    ///
    /// **The group index is `groupTypeIndex`, camel-cased**, where `GroupsQuery`
    /// three functions up spells the same concept `group_type_index`. Sending
    /// the snake-cased name is a 400 from pydantic — `Extra inputs are not
    /// permitted` — so the two cannot be written the same way. Omitting it
    /// entirely reads persons, which is a different table and not an error.
    ///
    /// `sample_count` is a distinct-value count over the actor table. There is
    /// no frequency and no total here at all, so a screen showing this may rank
    /// values but must not draw them as shares of anything.
    static func actorsPropertyTaxonomy(
        projectID: Int,
        properties: [String],
        groupTypeIndex: Int? = nil,
        maxPropertyValues: Int = 10
    ) -> Endpoint {
        var query: [String: Any] = [
            "kind": "ActorsPropertyTaxonomyQuery",
            "properties": properties,
            "maxPropertyValues": maxPropertyValues,
        ]
        if let groupTypeIndex { query["groupTypeIndex"] = groupTypeIndex }
        return queryEndpoint(projectID: projectID, query: query)
    }

    /// The curated event taxonomy: every event name ever ingested, plus the
    /// `verified` / `hidden` / description state a human set on it.
    static func eventDefinitions(projectID: Int, limit: Int = 500) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/event_definitions/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }

    /// Property definitions, optionally narrowed to the properties seen on some
    /// events.
    ///
    /// A property definition is project-wide, not per-event, so scoping is done
    /// with `event_names` + `filter_by_event_names` rather than by name — that
    /// keeps one event's join to a single short request instead of paging the
    /// project's several hundred properties.
    /// - Parameter scope: which table's properties to list. `.event` is the API
    ///   default; person and group scopes use their respective tables. Session
    ///   properties may be queryable even when this endpoint does not enumerate
    ///   them.
    static func propertyDefinitions(
        projectID: Int,
        eventNames: [String] = [],
        scope: PropertyScope? = nil,
        limit: Int = 200
    ) -> Endpoint {
        var query = [URLQueryItem(name: "limit", value: String(limit))]

        // The viewset runs `json.loads` on this parameter, so it is one
        // JSON-encoded array rather than repeated query items.
        if !eventNames.isEmpty,
           let encoded = try? JSONSerialization.data(withJSONObject: eventNames),
           let json = String(data: encoded, encoding: .utf8) {
            query.append(URLQueryItem(name: "event_names", value: json))
            query.append(URLQueryItem(name: "filter_by_event_names", value: "true"))
        }

        if let scope {
            query.append(URLQueryItem(name: "type", value: scope.parameterValue))
            if case .group(let index) = scope {
                query.append(URLQueryItem(name: "group_type_index", value: String(index)))
            }
        }

        return Endpoint(
            path: "/api/projects/\(projectID)/property_definitions/",
            query: query,
            category: .crud
        )
    }
}

// MARK: - Group scoping

public extension PostHogAPI {

    /// Every event carries a key per group type in `$group_0` … `$group_4`, and
    /// that column — not a join — is how anything gets scoped to one group.
    ///
    /// `$group_0` through `$group_4` are string columns on `events` holding each
    /// group key and empty when an event has no group of that type. Five indices
    /// exist because PostHog caps a
    /// project at five group types.
    ///
    /// Insights take `aggregation_group_type_index` instead, which changes what
    /// a *series* counts — unique groups rather than unique persons — and is a
    /// different question from "what happened inside this one group". Only the
    /// column answers the second, so only the column is used here.
    static func groupColumn(index: Int) -> String { "$group_\(index)" }

    /// What one group did, as a per-event breakdown with honest totals.
    ///
    /// One request, and it carries its own denominators. `sum(count()) OVER ()`
    /// and `uniqExact(event) OVER ()` are evaluated across every group the
    /// `GROUP BY` produced, **before** `LIMIT`. So a screen can show the top handful
    /// and still say truthfully how many events and how many distinct event
    /// names there were.
    ///
    /// `QueryResponse.isTruncated` only reports a service-applied cap, not an
    /// explicit query limit. These window totals provide truncation evidence for
    /// the query's own `LIMIT`.
    ///
    /// `since` is required because an unbounded scan of a shared `events` table
    /// denies partition pruning.
    static func groupEventBreakdown(
        projectID: Int,
        groupTypeIndex: Int,
        groupKey: String,
        since floor: Date,
        limit: Int = 12
    ) -> Endpoint {
        hogql(projectID: projectID, sql: """
            SELECT
                event,
                count() AS occurrences,
                uniq(person_id) AS people,
                max(timestamp) AS last_seen,
                sum(count()) OVER () AS total_occurrences,
                uniqExact(event) OVER () AS distinct_events
            FROM events
            WHERE \(groupClause(index: groupTypeIndex, key: groupKey))
              AND timestamp > toDateTime64('\(sqlTimestamp(floor))', 6)
            GROUP BY event
            ORDER BY occurrences DESC
            LIMIT \(limit)
            """)
    }

    /// The group's own events, newest first — the raw feed, not the breakdown.
    ///
    /// Written through `eventsSQL`, which is the one place the feed's SQL lives,
    /// so the time bound and the tie-safe `(timestamp, uuid)` ordering cannot be
    /// present in the main feed and missing from this one. It selects the same
    /// columns, so these rows decode as `EventRow` and the app's existing event
    /// row and detail views read them unchanged.
    ///
    /// - Parameter eventName: narrows to one name, which is what a breakdown row
    ///   pushes. `nil` is the whole feed for the group.
    static func groupEvents(
        projectID: Int,
        groupTypeIndex: Int,
        groupKey: String,
        eventName: String? = nil,
        since floor: Date,
        before cursor: EventCursor? = nil,
        limit: Int = 50
    ) -> Endpoint {
        var filters = [groupClause(index: groupTypeIndex, key: groupKey)]
        if let eventName, !eventName.isEmpty {
            filters.append("event = '\(escape(eventName))'")
        }
        return hogql(
            projectID: projectID,
            sql: eventsSQL(limit: limit, since: floor, before: cursor, filters: filters)
        )
    }

    /// The people who acted inside one group, busiest first.
    ///
    /// Group membership is not a stored person-to-group edge anywhere this key
    /// can read — it is "this person emitted an event carrying this group key".
    /// So this is a relationship *observed over a window*, and a person who last
    /// touched the group before `since` is absent rather than listed at zero.
    /// The screen says which it is showing; inventing a membership list the API
    /// never stated is the failure to avoid.
    ///
    /// `person.properties.email` is read through the person-on-events join, so
    /// the value is the one attached at ingestion rather than the person's
    /// current one. `any()` picks whichever the first row carried.
    static func groupPeople(
        projectID: Int,
        groupTypeIndex: Int,
        groupKey: String,
        since floor: Date,
        limit: Int = 25
    ) -> Endpoint {
        hogql(projectID: projectID, sql: """
            SELECT
                person_id,
                any(distinct_id) AS distinct_id,
                any(person.properties.email) AS email,
                any(person.properties.name) AS name,
                count() AS occurrences,
                max(timestamp) AS last_seen,
                uniqExact(person_id) OVER () AS distinct_people
            FROM events
            WHERE \(groupClause(index: groupTypeIndex, key: groupKey))
              AND timestamp > toDateTime64('\(sqlTimestamp(floor))', 6)
            GROUP BY person_id
            ORDER BY occurrences DESC
            LIMIT \(limit)
            """)
    }

    /// Session recordings from sessions that touched one group.
    ///
    /// The recording list narrows on `$group_N` as an ordinary **event**
    /// property. It always supplies an explicit date window so a default window
    /// cannot make an active group appear to have no recordings.
    ///
    /// Proven to filter rather than to be ignored: the same call with a real key
    /// returned five recordings whose session ids matched an independent HogQL
    /// list of that group's sessions, with `definitely-not-a-real-group-key`
    /// returning zero. A filter that silently does nothing looks identical to
    /// one that works until you ask it for something absent.
    ///
    /// Billed against `.analytics` rather than `.query`, because this is the
    /// ordinary recordings list endpoint with two extra query items.
    static func groupRecordings(
        projectID: Int,
        groupTypeIndex: Int,
        groupKey: String,
        window: SessionRecordingFilter.DateWindow = .last30Days,
        limit: Int = 20
    ) -> Endpoint {
        sessionRecordings(
            projectID: projectID,
            limit: limit,
            filter: groupRecordingFilter(
                groupTypeIndex: groupTypeIndex,
                groupKey: groupKey,
                window: window
            )
        )
    }

    /// The filter behind `groupRecordings`, exposed so the recordings screen can
    /// be handed the same narrowing the group screen ran.
    ///
    /// `.allTime` is deliberately not offered a free pass: it resolves to no
    /// `date_from` at all, which is the three-day default described above. The
    /// window falls back to 90 days rather than being dropped.
    static func groupRecordingFilter(
        groupTypeIndex: Int,
        groupKey: String,
        window: SessionRecordingFilter.DateWindow = .last30Days
    ) -> SessionRecordingFilter {
        var filter = SessionRecordingFilter()
        filter.dateWindow = window == .allTime ? .last90Days : window
        filter.inheritedProperties = [
            SessionRecordingFilter.PropertyClause(
                key: groupColumn(index: groupTypeIndex),
                type: "event",
                value: .array([.string(groupKey)]),
                op: "exact"
            )
        ]
        return filter
    }

    /// `$group_N = '…'`, escaped once so no caller writes it by hand.
    static func groupClause(index: Int, key: String) -> String {
        "\(groupColumn(index: index)) = '\(escape(key))'"
    }
}

// MARK: - Property depth

public extension PostHogAPI {

    /// What one property actually contains: its values ranked by how often they
    /// were sent, with the totals that make a share meaningful.
    ///
    /// `EventTaxonomyQuery` ranks values but reports no counts, so the only
    /// route to a distribution is HogQL. The two window columns are what keep
    /// the answer honest under its own `LIMIT`: `total_occurrences` is every
    /// matching event and `distinct_values` every distinct value, both computed
    /// before the limit, so a screen showing ten rows can say ten *of how many*
    /// and can draw each row as a share of the real total rather than of the
    /// visible ten.
    ///
    /// The key is read with bracket syntax rather than as a `properties.foo`
    /// path because property keys are arbitrary text, and bracket syntax takes
    /// one as a string literal.
    ///
    /// - Parameter event: narrows to one event name. `nil` asks across every
    ///   event, which is a real question — "what does `$browser` look like
    ///   project-wide" — and is why this is HogQL rather than the taxonomy
    ///   query, whose eventless form answers HTTP 500.
    static func propertyValueDistribution(
        projectID: Int,
        property: String,
        event: String? = nil,
        since floor: Date,
        limit: Int = 12
    ) -> Endpoint {
        var clauses = [
            "timestamp > toDateTime64('\(sqlTimestamp(floor))', 6)",
            "JSONHas(properties, '\(escape(property))')",
        ]
        if let event, !event.isEmpty {
            clauses.append("event = '\(escape(event))'")
        }

        return hogql(projectID: projectID, sql: """
            SELECT
                properties['\(escape(property))'] AS value,
                count() AS occurrences,
                sum(count()) OVER () AS total_occurrences,
                \(distinctValuesExpression(property: property)) AS distinct_values
            FROM events
            WHERE \(clauses.joined(separator: " AND "))
            GROUP BY value
            ORDER BY occurrences DESC
            LIMIT \(limit)
            """)
    }

    /// Distinct values of a property, **counting the null group**.
    ///
    /// `uniqExact` drops SQL nulls, and a null group survives `JSONHas` — a
    /// property stored as JSON null is present and has no value. Measured on
    /// `utm_source` over 30 days: four `GROUP BY` rows come back, one of them
    /// null, and a bare `uniqExact` reports three.
    ///
    /// That is not a cosmetic difference. The screen says "N more distinct
    /// values not shown" by subtracting the rows it received from this figure,
    /// so an undercount by one silently loses a value from that claim. The
    /// `max(if(isNull(…), 1, 0)) OVER ()` term adds the null group back exactly
    /// once, and adds nothing when there is no null group — verified both ways
    /// against `$referrer` (35 values, no nulls, unchanged) and `utm_source`
    /// (3 → 4, matching the four rows returned).
    static func distinctValuesExpression(property: String) -> String {
        let key = "properties['\(escape(property))']"
        return "uniqExact(\(key)) OVER () + max(if(isNull(\(key)), 1, 0)) OVER ()"
    }

    /// Which events carry a property, and how varied it is on each of them.
    ///
    /// The other half of what a property definition does not say. A definition
    /// is project-wide — `/property_definitions/` will tell you `$browser`
    /// exists and is a String, and nothing about the fact that in this project
    /// it rides on eleven different events and takes 7 values on `$autocapture`
    /// against 8 on `$pageview`.
    ///
    /// Same window-total treatment as the distribution, for the same reason.
    static func propertyCarrierEvents(
        projectID: Int,
        property: String,
        since floor: Date,
        limit: Int = 12
    ) -> Endpoint {
        hogql(projectID: projectID, sql: """
            SELECT
                event,
                count() AS occurrences,
                uniqExact(properties['\(escape(property))'])
                    + max(if(isNull(properties['\(escape(property))']), 1, 0)) AS distinct_values,
                sum(count()) OVER () AS total_occurrences,
                uniqExact(event) OVER () AS distinct_events
            FROM events
            WHERE timestamp > toDateTime64('\(sqlTimestamp(floor))', 6)
              AND JSONHas(properties, '\(escape(property))')
            GROUP BY event
            ORDER BY occurrences DESC
            LIMIT \(limit)
            """)
    }
}
