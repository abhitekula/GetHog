import Foundation

// The data-plumbing models: warehouse tables, the external sources that fill
// them, and the CDP hog functions that transform and forward events. They share
// a file because they answer one question between them — is data flowing?

// MARK: - Sync health

/// How a source or schema is doing, reduced to something a pill can state.
///
/// Deliberately not derived from colour: every case has a `title`, because a
/// broken sync must be legible to someone who cannot see the red.
public enum SyncHealth: String, Sendable, Hashable, CaseIterable {
    case healthy
    case running
    case paused
    case failed
    case unknown

    public var title: String {
        switch self {
        case .healthy: "Completed"
        case .running: "Running"
        case .paused: "Paused"
        case .failed: "Error"
        case .unknown: "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .healthy: "checkmark.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }

    /// Sorts trouble to the top of the list.
    public var severity: Int {
        switch self {
        case .failed: 0
        case .paused: 1
        case .unknown: 2
        case .running: 3
        case .healthy: 4
        }
    }

    /// PostHog's status strings are capitalised words, but the set has grown
    /// over time, so anything unrecognised stays `.unknown` rather than being
    /// optimistically read as healthy.
    public init(status: String?) {
        switch status?.lowercased() {
        case "completed", "succeeded", "success": self = .healthy
        case "running", "starting", "billing limit reached but running": self = .running
        case "paused", "cancelled", "canceled": self = .paused
        case "error", "failed", "failure": self = .failed
        case nil, "": self = .unknown
        default: self = .unknown
        }
    }
}

// MARK: - External data sources

/// A managed import — Stripe, Postgres, GitHub — that populates warehouse tables.
public struct ExternalDataSource: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let sourceType: String
    public let status: String?
    public let prefix: String?
    public let latestError: String?
    public let lastRunAt: Date?
    public let createdAt: Date?
    public let schemas: [ExternalDataSchema]

    enum CodingKeys: String, CodingKey {
        case id, status, prefix, schemas
        case sourceType = "source_type"
        case latestError = "latest_error"
        case lastRunAt = "last_run_at"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceType = try c.decodeIfPresent(String.self, forKey: .sourceType) ?? "Unknown"
        status = try c.decodeIfPresent(String.self, forKey: .status)
        // `prefix` is null when a project has only one source of a type, and an
        // empty string is equally meaningless as a label.
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix).flatMap {
            $0.isEmpty ? nil : $0
        }
        latestError = try c.decodeIfPresent(String.self, forKey: .latestError).flatMap {
            $0.isEmpty ? nil : $0
        }
        lastRunAt = try c.decodeIfPresent(String.self, forKey: .lastRunAt).flatMap(PostHogDate.parse)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        schemas = (try? c.decodeIfPresent([ExternalDataSchema].self, forKey: .schemas)) ?? []
    }

    public var displayName: String {
        guard let prefix else { return sourceType }
        return "\(sourceType) (\(prefix))"
    }

    /// Most schemas on a source are switched off; only the enabled ones are
    /// evidence that data is still arriving.
    public var syncingSchemaCount: Int {
        schemas.filter(\.shouldSync).count
    }

    public var health: SyncHealth {
        // A source can report "Completed" while carrying the error that ended
        // its last run, so the error wins over the status word.
        if latestError != nil { return .failed }
        let fromStatus = SyncHealth(status: status)
        // Nothing enabled means nothing is arriving, whatever the last run said.
        if fromStatus == .healthy, !schemas.isEmpty, syncingSchemaCount == 0 {
            return .paused
        }
        return fromStatus
    }

    /// Plain-language summary for the row's secondary line and its
    /// accessibility label, so the pill never has to carry it alone.
    public var syncSummary: String {
        guard !schemas.isEmpty else { return "No schemas configured" }
        return "\(syncingSchemaCount) of \(schemas.count) schemas syncing"
    }
}

/// One table's worth of import config inside a source.
public struct ExternalDataSchema: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let shouldSync: Bool
    public let status: String?
    public let syncType: String?
    public let syncFrequency: String?
    public let lastSyncedAt: Date?
    public let latestError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case shouldSync = "should_sync"
        case syncType = "sync_type"
        case syncFrequency = "sync_frequency"
        case lastSyncedAt = "last_synced_at"
        case latestError = "latest_error"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled schema"
        shouldSync = try c.decodeIfPresent(Bool.self, forKey: .shouldSync) ?? false
        // Null for every schema that has never run, which is most of them.
        status = try c.decodeIfPresent(String.self, forKey: .status)
        syncType = try c.decodeIfPresent(String.self, forKey: .syncType)
        syncFrequency = try c.decodeIfPresent(String.self, forKey: .syncFrequency)
        lastSyncedAt = try c.decodeIfPresent(String.self, forKey: .lastSyncedAt)
            .flatMap(PostHogDate.parse)
        latestError = try c.decodeIfPresent(String.self, forKey: .latestError).flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    public var health: SyncHealth {
        if latestError != nil { return .failed }
        if !shouldSync { return .paused }
        return SyncHealth(status: status)
    }
}

// MARK: - Warehouse tables

/// A queryable table in the warehouse.
public struct WarehouseTable: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let hogqlName: String?
    public let format: String?
    public let rowCount: Int?
    public let columns: [WarehouseColumn]
    public let createdAt: Date?

    /// Flattened from the nested `external_data_source` / `external_schema`
    /// objects: the table row is the only place they appear together, and the
    /// screen needs the pairing to say where a table came from.
    public let sourceID: String?
    public let sourceType: String?
    public let sourceStatus: String?
    public let schemaName: String?
    public let lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, format, columns
        case hogqlName = "hogql_name"
        case rowCount = "row_count"
        case createdAt = "created_at"
        case externalDataSource = "external_data_source"
        case externalSchema = "external_schema"
    }

    private enum SourceKeys: String, CodingKey {
        case id, status
        case sourceType = "source_type"
    }

    private enum SchemaKeys: String, CodingKey {
        case name
        case lastSyncedAt = "last_synced_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled table"
        hogqlName = try c.decodeIfPresent(String.self, forKey: .hogqlName)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        // Absent from the list payload entirely. Defaulting to 0 would claim an
        // empty table, so an unknown count stays unknown.
        rowCount = try c.decodeIfPresent(Int.self, forKey: .rowCount)
        columns = (try? c.decodeIfPresent([WarehouseColumn].self, forKey: .columns)) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)

        let source = try? c.nestedContainer(keyedBy: SourceKeys.self, forKey: .externalDataSource)
        sourceID = try? source?.decodeIfPresent(String.self, forKey: .id)
        sourceType = try? source?.decodeIfPresent(String.self, forKey: .sourceType)
        sourceStatus = try? source?.decodeIfPresent(String.self, forKey: .status)

        let schema = try? c.nestedContainer(keyedBy: SchemaKeys.self, forKey: .externalSchema)
        schemaName = try? schema?.decodeIfPresent(String.self, forKey: .name)
        lastSyncedAt = (try? schema?.decodeIfPresent(String.self, forKey: .lastSyncedAt))?
            .flatMap(PostHogDate.parse)
    }

    /// Tables created by a query rather than an import have no source.
    public var isManaged: Bool { sourceID != nil }
}

public struct WarehouseColumn: Sendable, Decodable, Identifiable, Hashable {
    public let name: String
    public let type: String
    public let schemaValid: Bool

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case key, name, type
        case schemaValid = "schema_valid"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .key)
            ?? "unnamed"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        schemaValid = try c.decodeIfPresent(Bool.self, forKey: .schemaValid) ?? true
    }
}

// MARK: - CDP hog functions

/// What a hog function does, folded down from PostHog's growing `type` list.
public enum HogFunctionKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case transformation
    case destination
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .transformation: "Transformations"
        case .destination: "Destinations"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .transformation: "wand.and.rays"
        case .destination: "arrow.up.forward.square"
        case .other: "puzzlepiece"
        }
    }

    /// The live API returns `internal_destination` and `site_destination`
    /// alongside plain `destination`; matching the literal string would leave
    /// most real rows ungrouped.
    public init(rawType: String) {
        if rawType.contains("transformation") {
            self = .transformation
        } else if rawType.contains("destination") {
            self = .destination
        } else {
            self = .other
        }
    }

    /// Groups a page for display, keeping a fixed section order and dropping
    /// sections that would be empty.
    public static func grouped(
        _ functions: [HogFunction]
    ) -> [(kind: HogFunctionKind, functions: [HogFunction])] {
        let byKind = Dictionary(grouping: functions, by: \.kind)
        return allCases.compactMap { kind in
            guard let items = byKind[kind], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (kind: kind, functions: sorted)
        }
    }
}

/// Health of a deployed function, as PostHog's `status.state` integer.
public enum HogFunctionState: Int, Sendable, Hashable {
    case unknown = 0
    case healthy = 1
    case degraded = 2
    case disabledTemporarily = 3
    case disabledPermanently = 4

    public var title: String {
        switch self {
        case .unknown: "Unknown"
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .disabledTemporarily: "Disabled (rate limited)"
        case .disabledPermanently: "Disabled by PostHog"
        }
    }
}

/// A CDP function: a transformation applied during ingestion, or a destination
/// that forwards events out of PostHog.
public struct HogFunction: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let type: String
    public let enabled: Bool
    public let state: HogFunctionState
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, description, type, enabled, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    private enum StatusKeys: String, CodingKey {
        case state
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled function"
        description = try c.decodeIfPresent(String.self, forKey: .description).flatMap {
            $0.isEmpty ? nil : $0
        }
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "destination"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(PostHogDate.parse)

        // `status` is an object — `{"state": 1, "tokens": 10000}` — not the
        // scalar the field name suggests. Older responses do send a bare int,
        // so both are accepted and anything else degrades to `.unknown`
        // rather than failing the whole page.
        if let nested = try? c.nestedContainer(keyedBy: StatusKeys.self, forKey: .status),
           let raw = try? nested.decodeIfPresent(Int.self, forKey: .state) {
            state = HogFunctionState(rawValue: raw) ?? .unknown
        } else if let raw = try? c.decodeIfPresent(Int.self, forKey: .status) {
            state = HogFunctionState(rawValue: raw ?? 0) ?? .unknown
        } else {
            state = .unknown
        }
    }

    public var kind: HogFunctionKind { HogFunctionKind(rawType: type) }

    public var statusText: String { enabled ? "Enabled" : "Disabled" }
}
