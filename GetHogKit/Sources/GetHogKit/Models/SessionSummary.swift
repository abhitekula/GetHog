import Foundation

// MARK: - Outcome

/// The verdict on a session, or on one chapter of it.
///
/// `success` and `description` are both optional because the API can and does
/// return a summary the model declined to judge — the list endpoint even offers
/// `?outcome=unknown` for exactly that set. An unjudged session is not a failed
/// one, and nothing here may collapse the two.
public struct SessionOutcome: Sendable, Decodable, Hashable {
    public let succeeded: Bool?
    /// The narrative. This is the one field the whole feature is worth building
    /// for: a paragraph of prose beats scrubbing a video on a phone.
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case success, description, summary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        succeeded = try c.decodeIfPresent(Bool.self, forKey: .success)
        // `session_outcome` calls it `description`; `segment_outcomes` calls the
        // same thing `summary`. One type reads both rather than two near-identical
        // ones that would drift.
        detail = try c.decodeIfPresent(String.self, forKey: .description)
            ?? c.decodeIfPresent(String.self, forKey: .summary)
    }

    init?(succeeded: Bool?, detail: String?) {
        guard succeeded != nil || detail != nil else { return nil }
        self.succeeded = succeeded
        self.detail = detail
    }

    /// A word, never a colour alone. `nil` when the model made no call.
    public var title: String? {
        switch succeeded {
        case true: "Succeeded"
        case false: "Did not finish"
        case nil: nil
        }
    }
}

// MARK: - Sentiment

/// How the session felt, in the model's own vocabulary.
///
/// Known cases provide tailored presentation, while unknown values remain
/// displayable if the service vocabulary expands.
public enum SessionSentimentOutcome: Sendable, Hashable {
    case successful
    case friction
    case frustrated
    case unknown(String)

    init?(raw: String?) {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "successful", "success": self = .successful
        case "friction": self = .friction
        case "frustrated": self = .frustrated
        default: self = .unknown(raw)
        }
    }

    public var title: String {
        switch self {
        case .successful: "Successful"
        case .friction: "Friction"
        case .frustrated: "Frustrated"
        case .unknown(let raw): SessionSummaryText.humanise(raw)
        }
    }

    /// Whether this reading describes a user having a hard time.
    ///
    /// Used to decide emphasis, never to decide wording — the word itself is
    /// always shown, because "the sentiment is a colour" is not a readable
    /// interface.
    public var describesStruggle: Bool {
        switch self {
        case .friction, .frustrated: true
        case .successful, .unknown: false
        }
    }
}

/// The kind of thing that went wrong in a moment of the session.
///
/// Known values receive tailored presentation. Unknown values remain readable
/// so additions to the service vocabulary do not blank the row.
public enum SessionSignalKind: Sendable, Hashable {
    case abandonment
    case confusionLoop
    case deadClick
    case rageClick
    case repeatedError
    case errorCascade
    case backtracking
    case longPause
    case unknown(String)

    init(raw: String?) {
        switch raw?.lowercased() {
        case "abandonment": self = .abandonment
        case "confusion_loop": self = .confusionLoop
        case "dead_click": self = .deadClick
        case "rage_click", "rageclick": self = .rageClick
        case "repeated_error": self = .repeatedError
        case "error_cascade": self = .errorCascade
        case "backtracking": self = .backtracking
        case "long_pause": self = .longPause
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }

    public var title: String {
        switch self {
        case .abandonment: "Abandoned"
        case .confusionLoop: "Repeated attempts"
        case .deadClick: "Dead click"
        case .rageClick: "Rage click"
        case .repeatedError: "Repeated error"
        case .errorCascade: "Error cascade"
        case .backtracking: "Backtracked"
        case .longPause: "Long pause"
        // An empty raw means the field was absent, not that the signal is
        // nameless — and a blank chip beside a written description is worse than
        // a generic word.
        case .unknown(let raw): raw.isEmpty ? "Frustration signal" : SessionSummaryText.humanise(raw)
        }
    }

    /// A glyph, so the kind survives without colour. Deliberately plain shapes:
    /// these describe a person having difficulty, not a system alarm.
    public var systemImage: String {
        switch self {
        case .abandonment: "arrow.uturn.backward"
        case .confusionLoop: "arrow.trianglehead.2.clockwise"
        case .deadClick: "hand.tap"
        case .rageClick: "hand.tap.fill"
        case .repeatedError, .errorCascade: "exclamationmark.triangle"
        case .backtracking: "arrow.left"
        case .longPause: "hourglass"
        case .unknown: "circle.dotted"
        }
    }
}

/// One observation behind the sentiment reading.
public struct SessionSentimentSignal: Sendable, Decodable, Hashable, Identifiable {
    public let type: SessionSignalKind
    /// The model's own sentence. Shown verbatim: it is the only part of this
    /// record that says what actually happened.
    public let detail: String
    /// Clamped to the display range for the same reason as `frustrationScore`.
    public let intensity: Double?
    /// Which chapter it happened in, so the signal can be shown against it.
    public let segmentIndex: Int?

    public var id: String { "\(segmentIndex ?? -1)-\(type)-\(detail.hashValue)" }

    enum CodingKeys: String, CodingKey {
        case description, intensity
        case signalType = "signal_type"
        case segmentIndex = "segment_index"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = SessionSignalKind(raw: try c.decodeIfPresent(String.self, forKey: .signalType))
        detail = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity)
            .map(SessionSummaryText.clampToUnitRange)
        segmentIndex = try c.decodeIfPresent(Int.self, forKey: .segmentIndex)
    }
}

public struct SessionSentiment: Sendable, Decodable, Hashable {
    /// `nil` when the model did not classify the session, which is different
    /// from classifying it as successful.
    public let outcome: SessionSentimentOutcome?
    /// A normalized score used by a proportion meter. Clamp defensively so an
    /// unexpected service value cannot draw outside the meter's track.
    public let frustrationScore: Double?
    public let signals: [SessionSentimentSignal]

    enum CodingKeys: String, CodingKey {
        case outcome
        case frustrationScore = "frustration_score"
        case sentimentSignals = "sentiment_signals"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = SessionSentimentOutcome(raw: try c.decodeIfPresent(String.self, forKey: .outcome))
        frustrationScore = try c.decodeIfPresent(Double.self, forKey: .frustrationScore)
            .map(SessionSummaryText.clampToUnitRange)
        signals = try c.decodeIfPresent([SessionSentimentSignal].self, forKey: .sentimentSignals) ?? []
    }
}

// MARK: - Segments

/// One named chapter of a session.
///
/// The counters live under a nested `meta` object in the payload and are
/// flattened here, but they are **not** defaulted: every one stays optional.
/// A missing `confusion_count` means the model reported nothing, and rendering
/// that as "0 confusions" would put a number in front of a reader that nobody
/// ever measured.
public struct SessionSummarySegment: Sendable, Decodable, Hashable, Identifiable {
    public let index: Int?
    public let name: String?
    /// The segment's own first event. Carries no time — the offset has to be
    /// joined through `key_actions`, which is what `SessionSummaryChapter` does.
    public let startEventID: String?
    public let endEventID: String?

    public let duration: Double?
    public let eventsCount: Int?
    public let failureCount: Int?
    public let confusionCount: Int?
    public let abandonmentCount: Int?
    public let exceptionCount: Int?
    public let keyActionCount: Int?
    public let durationPercentage: Double?
    public let eventsPercentage: Double?

    public var id: String { "\(index ?? -1)-\(startEventID ?? name ?? "segment")" }

    enum CodingKeys: String, CodingKey {
        case index, name, meta
        case startEventID = "start_event_id"
        case endEventID = "end_event_id"
    }

    enum MetaKeys: String, CodingKey {
        case duration
        case eventsCount = "events_count"
        case failureCount = "failure_count"
        case confusionCount = "confusion_count"
        case abandonmentCount = "abandonment_count"
        case exceptionCount = "exception_count"
        case keyActionCount = "key_action_count"
        case durationPercentage = "duration_percentage"
        case eventsPercentage = "events_percentage"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        startEventID = try c.decodeIfPresent(String.self, forKey: .startEventID)
        endEventID = try c.decodeIfPresent(String.self, forKey: .endEventID)

        // `try?` rather than `try`: a segment with no `meta` at all is a shape
        // the API is free to return, and it must cost the counters, not the
        // chapter.
        let meta = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        duration = try? meta?.decodeIfPresent(Double.self, forKey: .duration)
        eventsCount = try? meta?.decodeIfPresent(Int.self, forKey: .eventsCount)
        failureCount = try? meta?.decodeIfPresent(Int.self, forKey: .failureCount)
        confusionCount = try? meta?.decodeIfPresent(Int.self, forKey: .confusionCount)
        abandonmentCount = try? meta?.decodeIfPresent(Int.self, forKey: .abandonmentCount)
        exceptionCount = try? meta?.decodeIfPresent(Int.self, forKey: .exceptionCount)
        keyActionCount = try? meta?.decodeIfPresent(Int.self, forKey: .keyActionCount)
        durationPercentage = try? meta?.decodeIfPresent(Double.self, forKey: .durationPercentage)
        eventsPercentage = try? meta?.decodeIfPresent(Double.self, forKey: .eventsPercentage)
    }
}

/// A per-chapter verdict, related to its segment by `segment_index`.
struct SessionSegmentOutcome: Sendable, Decodable, Hashable {
    let segmentIndex: Int?
    let outcome: SessionOutcome?

    enum CodingKeys: String, CodingKey {
        case success, summary, description
        case segmentIndex = "segment_index"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentIndex = try c.decodeIfPresent(Int.self, forKey: .segmentIndex)
        outcome = SessionOutcome(
            succeeded: try c.decodeIfPresent(Bool.self, forKey: .success),
            detail: try c.decodeIfPresent(String.self, forKey: .summary)
                ?? c.decodeIfPresent(String.self, forKey: .description)
        )
    }
}

// MARK: - Key actions

/// Whether an exception in this moment stopped the user.
///
/// A string where its neighbours `confusion` and `abandonment` are booleans.
/// Decoding it as `Bool` throws on every event that actually carried one, which
/// is exactly the set of events worth surfacing.
public enum SessionExceptionSeverity: Sendable, Hashable {
    case blocking
    case nonBlocking
    case unknown(String)

    init?(raw: String?) {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "blocking": self = .blocking
        case "non-blocking", "non_blocking", "nonblocking": self = .nonBlocking
        default: self = .unknown(raw)
        }
    }

    public var title: String {
        switch self {
        case .blocking: "Blocking error"
        case .nonBlocking: "Non-blocking error"
        case .unknown(let raw): SessionSummaryText.humanise(raw)
        }
    }
}

/// A moment the model thought worth describing.
public struct SessionSummaryKeyEvent: Sendable, Decodable, Hashable, Identifiable {
    public let eventID: String?
    /// PostHog's event name, e.g. `$autocapture`, `$dead_click`, `$exception`.
    public let event: String?
    public let eventType: String?
    /// The model's sentence about what the user did here.
    public let detail: String
    public let currentURL: String?
    /// `true` means the model observed the user struggling. Absent means it
    /// reported nothing — not that the user was fine.
    public let confusion: Bool?
    public let abandonment: Bool?
    public let exception: SessionExceptionSeverity?
    /// Offset from `session_start_time`. **This is the seek anchor** — the one
    /// field that lets a chapter become a position in the replay.
    public let millisecondsSinceStart: Int?
    /// The same instant absolutely. Preferred over the offset when re-basing
    /// onto the replay's own clock, which starts at its first snapshot rather
    /// than at `session_start_time`.
    public let timestamp: Date?
    public let eventIndex: Int?

    public var id: String { eventID ?? "\(eventIndex ?? -1)-\(millisecondsSinceStart ?? -1)" }

    enum CodingKeys: String, CodingKey {
        case event, confusion, abandonment, exception, timestamp, description
        case eventID = "event_id"
        case eventType = "event_type"
        case currentURL = "current_url"
        case millisecondsSinceStart = "milliseconds_since_start"
        case eventIndex = "event_index"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
        event = try c.decodeIfPresent(String.self, forKey: .event)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        detail = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        currentURL = try c.decodeIfPresent(String.self, forKey: .currentURL)
        confusion = try c.decodeIfPresent(Bool.self, forKey: .confusion)
        abandonment = try c.decodeIfPresent(Bool.self, forKey: .abandonment)
        exception = SessionExceptionSeverity(
            raw: try c.decodeIfPresent(String.self, forKey: .exception)
        )
        millisecondsSinceStart = try c.decodeIfPresent(Int.self, forKey: .millisecondsSinceStart)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp).flatMap(PostHogDate.parse)
        eventIndex = try c.decodeIfPresent(Int.self, forKey: .eventIndex)
    }

    /// Offset from the start of the session, in seconds.
    public var offset: TimeInterval? {
        millisecondsSinceStart.map { TimeInterval($0) / 1000 }
    }
}

public struct SessionSummaryKeyAction: Sendable, Decodable, Hashable {
    public let segmentIndex: Int?
    public let events: [SessionSummaryKeyEvent]

    enum CodingKeys: String, CodingKey {
        case events
        case segmentIndex = "segment_index"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentIndex = try c.decodeIfPresent(Int.self, forKey: .segmentIndex)
        events = try c.decodeIfPresent([SessionSummaryKeyEvent].self, forKey: .events) ?? []
    }
}

// MARK: - Summary body

/// The `summary` object. Every child of it is independently absent-able.
public struct SessionSummaryBody: Sendable, Decodable, Hashable {
    public let segments: [SessionSummarySegment]
    public let keyActions: [SessionSummaryKeyAction]
    public let sentiment: SessionSentiment?
    public let outcome: SessionOutcome?
    let segmentOutcomes: [SessionSegmentOutcome]

    enum CodingKeys: String, CodingKey {
        case segments, sentiment
        case keyActions = "key_actions"
        case sessionOutcome = "session_outcome"
        case segmentOutcomes = "segment_outcomes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decodeIfPresent([SessionSummarySegment].self, forKey: .segments) ?? []
        keyActions = try c.decodeIfPresent([SessionSummaryKeyAction].self, forKey: .keyActions) ?? []
        sentiment = try c.decodeIfPresent(SessionSentiment.self, forKey: .sentiment)
        outcome = try c.decodeIfPresent(SessionOutcome.self, forKey: .sessionOutcome)
        segmentOutcomes =
            try c.decodeIfPresent([SessionSegmentOutcome].self, forKey: .segmentOutcomes) ?? []
    }
}

// MARK: - Chapters

/// A segment, its verdict, its signals and — crucially — its position in the
/// replay, resolved from three parallel arrays that the payload relates only by
/// index and by an eight-character event id.
///
/// This is the type the player's table of contents is built from. Everything it
/// needs to seek is derived here rather than in a view, because the join is the
/// interesting part and it must be testable.
public struct SessionSummaryChapter: Sendable, Hashable, Identifiable {
    public let segment: SessionSummarySegment
    public let outcome: SessionOutcome?
    public let signals: [SessionSentimentSignal]
    /// The event the chapter opens on, when one could be found.
    public let startEvent: SessionSummaryKeyEvent?
    /// Every key-action event filed under this chapter, in time order.
    public let events: [SessionSummaryKeyEvent]

    public var id: String { segment.id }

    public var title: String {
        segment.name ?? "Chapter \((segment.index ?? 0) + 1)"
    }

    /// Seconds from `session_start_time`. `nil` when nothing in the payload
    /// pinned this chapter to a time — the chapter is still worth reading, it
    /// just cannot be seeked to, and the screen says so by omitting the control.
    public var startOffset: TimeInterval? {
        startEvent?.offset
    }

    /// The same position measured against the replay's own clock.
    ///
    /// rrweb counts from its first snapshot, which is not `session_start_time` —
    /// they differ by however long recording took to start. Seeking with the
    /// session-relative number lands in the wrong place by that difference, so
    /// when the key event's absolute timestamp is available it is preferred, and
    /// the offset is only the fallback.
    ///
    /// Clamped at zero: a replay whose first snapshot postdates the chapter has
    /// no frame to show for it, and asking the player for a negative position
    /// leaves the playhead wherever it already was.
    public func startOffset(from origin: Date?) -> TimeInterval? {
        if let origin, let timestamp = startEvent?.timestamp {
            return max(0, timestamp.timeIntervalSince(origin))
        }
        return startOffset
    }

    /// Whether the model looked for difficulty in this chapter and found none.
    ///
    /// Three answers, because there are three states and two of them are not the
    /// same: `true` — it counted and found nothing; `false` — it found
    /// something; `nil` — **it reported no counts at all**, which is not a count
    /// of nought and must not be stated as "none". `noteworthyCounts` collapses
    /// the first and last into an empty list, correctly, because neither is
    /// worth a chip; this is what lets a screen still tell them apart in prose.
    public var reportedNoDifficulty: Bool? {
        let counted = [
            segment.confusionCount, segment.abandonmentCount, segment.exceptionCount,
            segment.failureCount,
        ].compactMap { $0 }
        guard !counted.isEmpty else { return nil }
        return counted.allSatisfy { $0 == 0 }
    }

    /// What this chapter reported, as counts that are shown only when present.
    ///
    /// Stated factually and in the model's own units. A user hitting the same
    /// control four times is information about a product, not an incident.
    public var noteworthyCounts: [(label: String, value: Int)] {
        var counts: [(String, Int)] = []
        if let value = segment.confusionCount, value > 0 {
            counts.append((value == 1 ? "1 confusion" : "\(value) confusions", value))
        }
        if let value = segment.abandonmentCount, value > 0 {
            counts.append((value == 1 ? "1 abandonment" : "\(value) abandonments", value))
        }
        if let value = segment.exceptionCount, value > 0 {
            counts.append((value == 1 ? "1 exception" : "\(value) exceptions", value))
        }
        return counts
    }
}

// MARK: - Rows

/// One row of `/single_session_summaries/`.
///
/// **Identified by `session_id`, not by its own `id`.** That is what lets a
/// summary be matched to a recording the app already holds, and it is what the
/// detail endpoint is keyed on — a request built from the row's `id` answers
/// 404, which is indistinguishable from "never summarised".
public struct SessionSummaryRow: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    /// The record's own primary key. Kept because it is what `created_at`
    /// belongs to, and never used to address the detail endpoint.
    public let summaryID: String?
    public let distinctID: String?
    public let startTime: Date?
    public let duration: Double?
    public let outcome: SessionOutcome?
    public let exceptionCount: Int?
    public let hasExceptions: Bool
    public let modelUsed: String?
    public let visualConfirmation: Bool?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case distinctID = "distinct_id"
        case startTime = "session_start_time"
        case duration = "session_duration"
        case outcome = "session_outcome"
        case exceptionCount = "exception_count"
        case hasExceptions = "has_exceptions"
        case modelUsed = "model_used"
        case visualConfirmation = "visual_confirmation"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .sessionID)
        summaryID = try c.decodeIfPresent(String.self, forKey: .id)
        distinctID = try c.decodeIfPresent(String.self, forKey: .distinctID)
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime).flatMap(PostHogDate.parse)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        outcome = try c.decodeIfPresent(SessionOutcome.self, forKey: .outcome)
        exceptionCount = try c.decodeIfPresent(Int.self, forKey: .exceptionCount)
        hasExceptions = try c.decodeIfPresent(Bool.self, forKey: .hasExceptions) ?? false
        modelUsed = try c.decodeIfPresent(String.self, forKey: .modelUsed)
        visualConfirmation = try c.decodeIfPresent(Bool.self, forKey: .visualConfirmation)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
    }

    public var durationText: String? {
        duration.map(SessionSummaryText.clock)
    }
}

// MARK: - Detail

/// The full stored summary for one session.
public struct SessionSummaryDetail: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    public let summaryID: String?
    public let distinctID: String?
    public let startTime: Date?
    public let duration: Double?
    public let summary: SessionSummaryBody?
    public let modelUsed: String?
    public let visualConfirmation: Bool?
    public let exceptionEventIDs: [String]
    public let createdAt: Date?

    private let topLevelOutcome: SessionOutcome?

    enum CodingKeys: String, CodingKey {
        case summary
        case id
        case sessionID = "session_id"
        case distinctID = "distinct_id"
        case startTime = "session_start_time"
        case duration = "session_duration"
        case outcome = "session_outcome"
        case exceptionEventIDs = "exception_event_ids"
        case runMetadata = "run_metadata"
        case createdAt = "created_at"
    }

    enum RunMetadataKeys: String, CodingKey {
        case modelUsed = "model_used"
        case visualConfirmation = "visual_confirmation"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .sessionID)
        summaryID = try c.decodeIfPresent(String.self, forKey: .id)
        distinctID = try c.decodeIfPresent(String.self, forKey: .distinctID)
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime).flatMap(PostHogDate.parse)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        summary = try c.decodeIfPresent(SessionSummaryBody.self, forKey: .summary)
        topLevelOutcome = try c.decodeIfPresent(SessionOutcome.self, forKey: .outcome)
        exceptionEventIDs = try c.decodeIfPresent([String].self, forKey: .exceptionEventIDs) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)

        let metadata = try? c.nestedContainer(keyedBy: RunMetadataKeys.self, forKey: .runMetadata)
        modelUsed = try? metadata?.decodeIfPresent(String.self, forKey: .modelUsed)
        visualConfirmation = try? metadata?.decodeIfPresent(Bool.self, forKey: .visualConfirmation)
    }

    /// The headline verdict.
    ///
    /// The list carries it at the top level and the detail carries it inside
    /// `summary`; both are read so one type serves both responses.
    public var outcome: SessionOutcome? {
        summary?.outcome ?? topLevelOutcome
    }

    public var sentiment: SessionSentiment? { summary?.sentiment }

    /// The chaptered table of contents, joined and sorted.
    ///
    /// The payload relates segments, outcomes, signals and key actions through
    /// three separate keys — `segment_index` on the outcomes, signals and
    /// actions, and `start_event_id` on the segment itself. The join happens
    /// once, here, so no view ever has to know about any of that.
    public var chapters: [SessionSummaryChapter] {
        guard let summary else { return [] }

        // Event IDs can be abbreviated, so the segment index remains a fallback.
        var eventsByID: [String: SessionSummaryKeyEvent] = [:]
        for action in summary.keyActions {
            for event in action.events where event.eventID != nil {
                eventsByID[event.eventID!] = event
            }
        }

        var eventsBySegment: [Int: [SessionSummaryKeyEvent]] = [:]
        for action in summary.keyActions {
            guard let index = action.segmentIndex else { continue }
            eventsBySegment[index, default: []].append(contentsOf: action.events)
        }

        var outcomesBySegment: [Int: SessionOutcome] = [:]
        for entry in summary.segmentOutcomes {
            guard let index = entry.segmentIndex, let outcome = entry.outcome else { continue }
            outcomesBySegment[index] = outcome
        }

        var signalsBySegment: [Int: [SessionSentimentSignal]] = [:]
        for signal in summary.sentiment?.signals ?? [] {
            guard let index = signal.segmentIndex else { continue }
            signalsBySegment[index, default: []].append(signal)
        }

        let chapters = summary.segments.enumerated().map { position, segment in
            let index = segment.index ?? position
            let events = eventsBySegment[index, default: []]
                .sorted { ($0.millisecondsSinceStart ?? 0) < ($1.millisecondsSinceStart ?? 0) }
            let anchor = segment.startEventID.flatMap { eventsByID[$0] } ?? events.first
            return SessionSummaryChapter(
                segment: segment,
                outcome: outcomesBySegment[index],
                signals: signalsBySegment[index, default: []],
                startEvent: anchor,
                events: events
            )
        }

        // Time order, so the table of contents reads down the session. Chapters
        // with no resolvable time keep their declared order at the end rather
        // than being dropped.
        return chapters.sorted {
            switch ($0.startOffset, $1.startOffset) {
            case (let a?, let b?): a < b
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): ($0.segment.index ?? 0) < ($1.segment.index ?? 0)
            }
        }
    }

    public static func decode(from data: Data) throws -> SessionSummaryDetail {
        try JSONDecoder().decode(SessionSummaryDetail.self, from: data)
    }

    /// Whether an error means "nobody has summarised this session", which is the
    /// ordinary case rather than a fault.
    ///
    /// The API answers `404 {"detail":"No stored summary found for this
    /// session."}`, and most sessions in any project have no summary. Showing an
    /// error card for that would put a failure on the majority of session
    /// screens for a feature that is working exactly as designed.
    public static func isMissingSummary(_ error: PostHogError) -> Bool {
        guard case .http(let status, _) = error else { return false }
        return status == 404
    }
}

// MARK: - Shared formatting

enum SessionSummaryText {
    /// `"confusion_loop"` → `"Confusion loop"`.
    static func humanise(_ raw: String) -> String {
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return raw }
        return first.uppercased() + words.dropFirst()
    }

    /// Clamping keeps proportion meters inside their tracks when service values
    /// fall outside the supported display range.
    static func clampToUnitRange(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
