import Foundation

public enum ReplayVisionObservationStatus: Sendable, Hashable, Decodable {
    case pending
    case running
    case succeeded
    case failed
    case ineligible
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "pending": .pending
        case "running": .running
        case "succeeded": .succeeded
        case "failed": .failed
        case "ineligible": .ineligible
        default: .unknown(raw)
        }
    }

    public var isInFlight: Bool {
        self == .pending || self == .running
    }

    public var isRetryable: Bool {
        self == .failed || self == .ineligible
    }
}

public enum ReplayVisionSummarySegment: Sendable, Hashable, Decodable {
    case text(String)
    case citation(milliseconds: Int)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind, value
        case timestampMilliseconds = "timestamp_ms"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .kind) {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .value) ?? "")
        case "chip":
            guard let milliseconds = try container.decodeIfPresent(
                Int.self,
                forKey: .timestampMilliseconds
            ) else {
                self = .unknown
                return
            }
            self = .citation(milliseconds: milliseconds)
        default:
            self = .unknown
        }
    }
}

public struct ReplayVisionSummary: Sendable, Hashable, Decodable {
    public let scannerType: String?
    public let title: String
    public let summary: String
    public let summarySegments: [ReplayVisionSummarySegment]
    public let intent: String
    public let outcome: String
    public let frictionPoints: [String]
    public let keywords: [String]
    public let confidence: Double?

    private enum CodingKeys: String, CodingKey {
        case scannerType = "scanner_type"
        case title, summary, intent, outcome, keywords, confidence
        case summarySegments = "summary_segments"
        case frictionPoints = "friction_points"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scannerType = try container.decodeIfPresent(String.self, forKey: .scannerType)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summarySegments = try container.decodeIfPresent(
            [ReplayVisionSummarySegment].self,
            forKey: .summarySegments
        ) ?? []
        intent = try container.decodeIfPresent(String.self, forKey: .intent) ?? ""
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        frictionPoints = try container.decodeIfPresent([String].self, forKey: .frictionPoints) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }

    public var hasFriction: Bool { !frictionPoints.isEmpty }

    public var citationOffsets: [TimeInterval] {
        summarySegments.compactMap { segment in
            guard case .citation(let milliseconds) = segment else { return nil }
            return TimeInterval(milliseconds) / 1_000
        }
    }

    public var cardSummary: String? {
        let preferred = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { return preferred }
        let fallback = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }
}

public struct ReplayVisionScannerSnapshot: Sendable, Hashable, Decodable {
    public let name: String?
    public let scannerType: String?
    public let scannerVersion: Int?
    public let model: String?
    public let provider: String?
    public let emitsSignals: Bool?
    public let scannerConfig: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case name, model, provider
        case scannerType = "scanner_type"
        case scannerVersion = "scanner_version"
        case emitsSignals = "emits_signals"
        case scannerConfig = "scanner_config"
    }
}

public struct ReplayVisionScannerResult: Sendable, Hashable, Decodable {
    public let modelOutput: ReplayVisionSummary?
    public let signalsCount: Int?

    private enum CodingKeys: String, CodingKey {
        case modelOutput = "model_output"
        case signalsCount = "signals_count"
    }
}

public struct ReplayVisionObservation: Sendable, Hashable, Decodable, Identifiable {
    public let id: String
    public let scannerID: String
    public let sessionID: String
    public let status: ReplayVisionObservationStatus
    public let errorReason: String?
    public let workflowID: String?
    public let scannerSnapshot: ReplayVisionScannerSnapshot?
    public let scannerResult: ReplayVisionScannerResult?
    public let startedAt: Date?
    public let completedAt: Date?
    public let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, status
        case scannerID = "scanner_id"
        case sessionID = "session_id"
        case errorReason = "error_reason"
        case workflowID = "workflow_id"
        case scannerSnapshot = "scanner_snapshot"
        case scannerResult = "scanner_result"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        scannerID = try container.decode(String.self, forKey: .scannerID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        status = try container.decode(ReplayVisionObservationStatus.self, forKey: .status)
        errorReason = try container.decodeIfPresent(String.self, forKey: .errorReason)
        workflowID = try container.decodeIfPresent(String.self, forKey: .workflowID)
        scannerSnapshot = try container.decodeIfPresent(
            ReplayVisionScannerSnapshot.self,
            forKey: .scannerSnapshot
        )
        scannerResult = try container.decodeIfPresent(
            ReplayVisionScannerResult.self,
            forKey: .scannerResult
        )
        startedAt = Self.date(in: container, key: .startedAt)
        completedAt = Self.date(in: container, key: .completedAt)
        createdAt = Self.date(in: container, key: .createdAt)
    }

    public var isSummarizer: Bool {
        scannerSnapshot?.scannerType == "summarizer"
            || scannerResult?.modelOutput?.scannerType == "summarizer"
    }

    public var summary: ReplayVisionSummary? {
        guard isSummarizer else { return nil }
        return scannerResult?.modelOutput
    }

    private static func date(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Date? {
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return PostHogDate.parse(value)
    }
}

public enum ReplayVisionScanOutcome: Sendable, Hashable, Decodable {
    case started
    case alreadyRunning
    case alreadyScanned
    case skippedLimit
    case skippedQuota
    case skippedScannerLimit
    case failed
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "started": .started
        case "already_running": .alreadyRunning
        case "already_scanned": .alreadyScanned
        case "skipped_limit": .skippedLimit
        case "skipped_quota": .skippedQuota
        case "skipped_scanner_limit": .skippedScannerLimit
        case "failed": .failed
        default: .unknown(raw)
        }
    }
}

public struct ReplayVisionInlineScanResult: Sendable, Hashable, Decodable {
    public let sessionID: String
    public let outcome: ReplayVisionScanOutcome

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case outcome = "scan_outcome"
    }
}

public struct ReplayVisionInlineScanResponse: Sendable, Hashable, Decodable {
    public let scanID: String?
    public let started: Int
    public let results: [ReplayVisionInlineScanResult]

    private enum CodingKeys: String, CodingKey {
        case scanID = "scan_id"
        case started, results
    }
}

public struct ReplayVisionRetryResponse: Sendable, Hashable, Decodable {
    public let workflowID: String

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflow_id"
    }
}

public struct ReplayVisionSummaryDigest: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let intent: String
    public let outcome: String
    public let frictionPoints: [String]
    public let confidence: Double?
    public let model: String?
    public let completedAt: Date?

    public init?(observation: ReplayVisionObservation) {
        guard let summary = observation.summary else { return nil }
        id = observation.sessionID
        title = summary.title
        self.summary = summary.summary
        intent = summary.intent
        outcome = summary.outcome
        frictionPoints = summary.frictionPoints
        confidence = summary.confidence
        model = observation.scannerSnapshot?.model
        completedAt = observation.completedAt
    }

    private init(
        id: String,
        title: String,
        summary: String,
        intent: String,
        outcome: String,
        frictionPoints: [String],
        confidence: Double?,
        model: String?,
        completedAt: Date?
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.intent = intent
        self.outcome = outcome
        self.frictionPoints = frictionPoints
        self.confidence = confidence
        self.model = model
        self.completedAt = completedAt
    }

    public var cardSummary: String? {
        let preferred = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { return preferred }
        let fallback = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    public var hasFriction: Bool { !frictionPoints.isEmpty }

    public static func rows(from response: QueryResponse) -> [Self] {
        response.rows.compactMap { row in
            guard let sessionID = row.string("session_id"), !sessionID.isEmpty else { return nil }
            return ReplayVisionSummaryDigest(
                id: sessionID,
                title: row.string("title") ?? "",
                summary: row.string("summary") ?? "",
                intent: row.string("intent") ?? "",
                outcome: row.string("outcome") ?? "",
                frictionPoints: frictionPoints(from: row.value("friction_points")),
                confidence: row.double("confidence"),
                model: row.string("model"),
                completedAt: row.date("completed_at")
            )
        }
    }

    private static func frictionPoints(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        if case .array(let values) = value {
            return values.compactMap(\.stringValue)
        }
        guard let raw = value.stringValue,
              let data = raw.data(using: .utf8),
              let points = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return points
    }
}
