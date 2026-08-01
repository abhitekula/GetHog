import Foundation

// `GET /exports/` can return rendered videos of session recordings as well as
// chart exports. The model therefore keeps the recording render context and the
// optional dashboard or insight references instead of assuming one export kind.
//
// Read-only. GetHog can list and play a render; it cannot queue one.

// MARK: - Format

/// The MIME type of a rendered export.
///
/// Open-ended on purpose. The API exposes a MIME-type string and may add formats;
/// `Page` decoding is all-or-nothing, so one unrecognised format must not empty
/// the whole list.
public enum ExportFormat: Sendable, Hashable {
    case videoMP4
    case unknown(String)

    public init(raw: String?) {
        switch raw {
        case "video/mp4": self = .videoMP4
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }

    public var rawValue: String {
        switch self {
        case .videoMP4: "video/mp4"
        case .unknown(let raw): raw
        }
    }

    /// Whether this can be handed to a video player.
    ///
    /// The prefix check is deliberate: a future `video/webm` is still playable,
    /// and refusing it because this enum has no case for it would be a bug the
    /// quarantine case exists to avoid.
    public var isVideo: Bool {
        switch self {
        case .videoMP4: true
        case .unknown(let raw): raw.hasPrefix("video/")
        }
    }

    public var title: String {
        switch self {
        case .videoMP4: "MP4 video"
        case .unknown(let raw): raw.isEmpty ? "Unknown format" : raw
        }
    }
}

// MARK: - Render context

/// One stretch of the source recording, flagged active or idle.
///
/// This is the map that makes "skip inactivity" possible, so the idle entries
/// are the half that carries the information — dropping them at decode would
/// leave nothing to skip. `ts_*` are offsets into the rendered video and
/// `recording_ts_*` into the original recording; they diverge once a render is
/// sped up or truncated.
public struct ExportInactivityPeriod: Sendable, Decodable, Hashable {
    public let isActive: Bool
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let recordingStartSeconds: TimeInterval
    public let recordingEndSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case active
        case startSeconds = "ts_from_s"
        case endSeconds = "ts_to_s"
        case recordingStartSeconds = "recording_ts_from_s"
        case recordingEndSeconds = "recording_ts_to_s"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        endSeconds = try c.decodeIfPresent(Double.self, forKey: .endSeconds) ?? 0
        recordingStartSeconds =
            try c.decodeIfPresent(Double.self, forKey: .recordingStartSeconds) ?? startSeconds
        recordingEndSeconds =
            try c.decodeIfPresent(Double.self, forKey: .recordingEndSeconds) ?? endSeconds
    }

    /// Never negative: a malformed pair would otherwise subtract from a sum.
    public var duration: TimeInterval { max(0, endSeconds - startSeconds) }
}

/// What PostHog recorded about the render itself.
///
/// Every field is optional because a render still in flight has measured none of
/// them — there is no file yet to have a size, and no video yet to have a
/// duration.
public struct ExportRenderContext: Sendable, Decodable, Hashable {
    /// The recording this video was rendered from — what lets a row link back to
    /// the replay rather than dead-ending at a file.
    public let sessionRecordingID: String?
    public let fileSizeBytes: Int?
    /// Length of the rendered video, in seconds. Not the length of the session:
    /// the render is sped up by `playbackSpeed` and may be `truncated`.
    public let duration: TimeInterval?
    public let recordingFPS: Int?
    public let playbackSpeed: Double?
    /// PostHog cut the render short. A row that reported the full session length
    /// would be claiming the file holds more than it does.
    public let truncated: Bool
    public let showsMetadataFooter: Bool
    public let renderFingerprint: String?
    public let inactivityPeriods: [ExportInactivityPeriod]

    enum CodingKeys: String, CodingKey {
        case truncated
        case sessionRecordingID = "session_recording_id"
        case fileSizeBytes = "file_size_bytes"
        case duration = "video_duration_s"
        case recordingFPS = "recording_fps"
        case playbackSpeed = "playback_speed"
        case showsMetadataFooter = "show_metadata_footer"
        case renderFingerprint = "render_fingerprint"
        case inactivityPeriods = "inactivity_periods"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionRecordingID = try c.decodeIfPresent(String.self, forKey: .sessionRecordingID)
        fileSizeBytes = try c.decodeIfPresent(Int.self, forKey: .fileSizeBytes)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        recordingFPS = try c.decodeIfPresent(Int.self, forKey: .recordingFPS)
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        showsMetadataFooter = try c.decodeIfPresent(Bool.self, forKey: .showsMetadataFooter) ?? false
        renderFingerprint = try c.decodeIfPresent(String.self, forKey: .renderFingerprint)
        inactivityPeriods = ((try? c.decodeIfPresent(
            [ExportInactivityPeriod].self, forKey: .inactivityPeriods
        )) ?? nil) ?? []
    }

    /// Seconds of the source recording somebody was actually doing something in.
    public var activeDuration: TimeInterval {
        inactivityPeriods.filter(\.isActive).reduce(0) { $0 + $1.duration }
    }

    /// Seconds a "skip inactivity" pass would jump over.
    public var idleDuration: TimeInterval {
        inactivityPeriods.filter { !$0.isActive }.reduce(0) { $0 + $1.duration }
    }
}

// MARK: - State

/// Why an export can or cannot be played right now.
///
/// `.failed` and `.pending` can both have `has_content: false`. The exception
/// field distinguishes a permanent failure from work still in progress, so the
/// states remain separate.
public enum RecordingExportState: Sendable, Hashable {
    case ready
    case pending
    case failed(reason: String)
    /// PostHog has deleted the file. The record survives; the download does not.
    case expired
}

// MARK: - Export

/// A rendered session-recording video, from `GET /exports/`.
public struct RecordingExport: Sendable, Decodable, Identifiable, Hashable {
    public let id: Int
    public let format: ExportFormat
    /// Absent until the render finishes.
    public let filename: String?
    /// PostHog has a file for this export. False covers both "still rendering"
    /// and "failed" — read `state(asOf:)` rather than this flag alone.
    public let hasContent: Bool
    /// `exception`. Non-nil means the render failed permanently.
    public let failure: String?
    public let createdAt: Date?
    /// When PostHog deletes the file. Past this, the content link is dead.
    public let expiresAfter: Date?
    public let userAccessLevel: String?
    public let context: ExportRenderContext?
    /// Optional chart references. Their presence distinguishes chart exports
    /// from session-recording renders.
    public let dashboardID: Int?
    public let insightID: Int?

    enum CodingKeys: String, CodingKey {
        case id, filename, exception, dashboard, insight
        case format = "export_format"
        case hasContent = "has_content"
        case createdAt = "created_at"
        case expiresAfter = "expires_after"
        case userAccessLevel = "user_access_level"
        case context = "export_context"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        format = ExportFormat(raw: try c.decodeIfPresent(String.self, forKey: .format))
        filename = (try c.decodeIfPresent(String.self, forKey: .filename))
            .flatMap { $0.isEmpty ? nil : $0 }
        hasContent = try c.decodeIfPresent(Bool.self, forKey: .hasContent) ?? false
        failure = (try c.decodeIfPresent(String.self, forKey: .exception))
            .flatMap { $0.isEmpty ? nil : $0 }
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        expiresAfter = try c.decodeIfPresent(String.self, forKey: .expiresAfter)
            .flatMap(PostHogDate.parse)
        userAccessLevel = try c.decodeIfPresent(String.self, forKey: .userAccessLevel)
        context = (try? c.decodeIfPresent(ExportRenderContext.self, forKey: .context)) ?? nil
        dashboardID = try c.decodeIfPresent(Int.self, forKey: .dashboard)
        insightID = try c.decodeIfPresent(Int.self, forKey: .insight)
    }

    // MARK: List row

    /// The recording this was rendered from, so a row can open the replay.
    public var sessionRecordingID: String? { context?.sessionRecordingID }
    public var duration: TimeInterval? { context?.duration }
    public var fileSizeBytes: Int? { context?.fileSizeBytes }

    /// Row subtitle: how long and how big.
    ///
    /// Says the file does not exist yet rather than printing a zero-length,
    /// zero-byte video the API never claimed.
    public var summary: String {
        let parts = [duration.map(Self.durationText), fileSizeBytes.map(Self.fileSizeText)]
            .compactMap { $0 }
        return parts.isEmpty ? "Not rendered yet" : parts.joined(separator: " · ")
    }

    // MARK: Expiry

    /// Whether the file is gone, as of a date the caller supplies.
    ///
    /// Takes the date rather than reading the clock so that the answer is
    /// reproducible — a view refreshing at midnight and a test running in CI
    /// must be able to ask the same question and both be answerable.
    ///
    /// No `expires_after` means nothing has told us it died, so it has not.
    public func hasExpired(asOf date: Date) -> Bool {
        guard let expiresAfter else { return false }
        return expiresAfter <= date
    }

    /// The single fact worth putting on the row.
    ///
    /// Ordered by what is most permanent: a failure never becomes playable, so
    /// it outranks expiry — reporting a crashed render as merely expired implies
    /// re-requesting it would work. Expiry then outranks readiness, because
    /// `has_content` stays true long after the file has been deleted.
    public func state(asOf date: Date) -> RecordingExportState {
        if let failure { return .failed(reason: failure) }
        if !hasContent { return .pending }
        if hasExpired(asOf: date) { return .expired }
        return .ready
    }

    /// The one word for the row, decided by the same date the rest of the row
    /// was rendered against.
    public func statusText(asOf date: Date) -> String {
        switch state(asOf: date) {
        case .ready: "Ready"
        case .pending: "Rendering"
        case .failed: "Failed"
        case .expired: "Expired"
        }
    }

    // MARK: Formatting

    /// `m:ss`, or `h:mm:ss` past an hour. Hand-rolled rather than
    /// `Duration.formatted` because a list row must not shift with the locale in
    /// the middle of a table of numbers.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Decimal units, matching what PostHog's own console shows for a file size.
    /// `String(format:)` without a locale is deliberate: the separator must not
    /// move.
    static func fileSizeText(_ bytes: Int) -> String {
        guard bytes >= 1000 else { return "\(bytes) bytes" }
        var value = Double(bytes)
        var unit = 0
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }
}
