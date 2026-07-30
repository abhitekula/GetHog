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
    static func propertyDefinitions(
        projectID: Int,
        eventNames: [String] = [],
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

        return Endpoint(
            path: "/api/projects/\(projectID)/property_definitions/",
            query: query,
            category: .crud
        )
    }
}
