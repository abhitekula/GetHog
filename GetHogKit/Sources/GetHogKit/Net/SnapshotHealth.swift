import Foundation

// The two health sections of `SharedSnapshot`, and the verdict drawn from them.
//
// **Why these two and not the others.** A widget occupies a slot the user chose
// to give this app, so the bar is not "can it be shown" but "would a glance
// change what someone does next". Away from a desk that question has one
// recurring shape: *is my data still arriving?* Two independent things stop it,
// and neither one is visible in the other:
//
// - **Ingestion warnings** — events arriving malformed, oversized, or
//   unmergeable. PostHog pre-aggregates severity, a count and a sparkline per
//   row, so one `.crud` request yields the whole section with no client rollup
//   and no per-row follow-up.
// - **Quota** — PostHog has stopped accepting a resource. This produces **no
//   ingestion warning at all**: a quota-blocked project looks perfectly healthy
//   to the warnings endpoint while dropping every event. A health surface built
//   on warnings alone would show a clean bill of health at the exact moment it
//   mattered most, which is why the second request is worth spending.
//
// Both reduce to a handful of scalars here rather than in a view, because the
// app is the only process allowed to call the API and the extension is only
// allowed to render.

// MARK: - Vocabulary

extension SharedSnapshot {

    /// How bad the worst ingestion warning is.
    ///
    /// A *snapshot-local* spelling of `IngestionWarningSeverity`, deliberately
    /// separate from it: this value crosses a process boundary as JSON and has to
    /// decode in a binary that may be older than the one that wrote it, which an
    /// enum with associated values cannot do cheaply.
    public enum Severity: String, Codable, Sendable, Hashable {
        case error
        case warning
        case info
        /// Two different unknowns land here, and both mean the same thing to a
        /// reader: PostHog sent a severity this client cannot rank, or a newer
        /// app build wrote one this widget cannot. Never folded into `info` —
        /// PostHog adds severities when it has something new to warn about.
        case unrated

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // `RawRepresentable`'s synthesised decode throws on an unrecognised
            // value, which would take the whole section down over a label.
            self = Severity(rawValue: raw) ?? .unrated
        }

        public var title: String {
            switch self {
            case .error: "Error"
            case .warning: "Warning"
            case .info: "Info"
            case .unrated: "Unrated"
            }
        }

        /// Paired with the title everywhere it is drawn, so severity is never
        /// carried by colour — Lock Screen accessories discard hue entirely.
        public var symbolName: String {
            switch self {
            case .error: "exclamationmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            case .unrated: "questionmark.circle.fill"
            }
        }
    }

    /// How hard the most-pressed metered resource is pressing.
    ///
    /// Mirrors `QuotaPressure`, and exists for the same cross-binary reason as
    /// `Severity`. An unrecognised raw value decodes to `nil` rather than to a
    /// case: the counts beside it carry the meaning, so a label this build cannot
    /// read costs a word and not a verdict.
    public enum QuotaState: String, Codable, Sendable, Hashable {
        case blocked
        case critical
        case watch
        case clear
        case unmetered

        public var title: String {
            switch self {
            case .blocked: "At limit"
            case .critical: "Critical"
            case .watch: "Watch"
            case .clear: "Clear"
            case .unmetered: "Unmetered"
            }
        }
    }
}

// MARK: - Ingestion

extension SharedSnapshot {

    /// Ingestion warnings, reduced to what a glance needs.
    public struct IngestionDigest: Codable, Sendable, Hashable {

        /// Distinct warning types the window returned, at any severity. Zero is
        /// the good news — and is only meaningful because `nil` at the snapshot
        /// level already means "not checked".
        public let typeCount: Int
        public let errorCount: Int
        public let warningCount: Int
        public let infoCount: Int
        /// Types whose severity this build could not rank. Counted separately
        /// because the verdict treats them as concerning, not as benign.
        public let unratedCount: Int
        /// The sum of the server's per-row counts: how many events were affected,
        /// not how many kinds of problem there are.
        public let affectedEvents: Int

        /// The worst row, by the ranking the Ingestion screen itself uses —
        /// severity first, then volume. `nil` on a project with no warnings.
        public let topTitle: String?
        public let topSeverity: Severity?
        public let topCount: Int
        /// The server's own buckets for that row, oldest first.
        public let topSparkline: [Double]

        /// The window the server aggregated over, as a phrase.
        ///
        /// Carried rather than inferred: the row has no bucket field, so the
        /// window that asked for it is the only thing that can label the
        /// sparkline's x-axis, and an unlabelled sparkline is decoration.
        public let windowTitle: String

        /// This section's own capture time. Usually the snapshot's, but a
        /// refresh whose warnings request failed carries the previous digest
        /// forward rather than blanking it, and then the two differ.
        public let capturedAt: Date

        /// The snapshot is rewritten on every refresh and re-read on every widget
        /// render, and a thirty-day window returns hundreds of buckets. No widget
        /// is wide enough to draw them, so the file does not carry them.
        public static let sparklineLimit = 24

        public init(
            typeCount: Int = 0,
            errorCount: Int = 0,
            warningCount: Int = 0,
            infoCount: Int = 0,
            unratedCount: Int = 0,
            affectedEvents: Int = 0,
            topTitle: String? = nil,
            topSeverity: Severity? = nil,
            topCount: Int = 0,
            topSparkline: [Double] = [],
            windowTitle: String,
            capturedAt: Date
        ) {
            self.typeCount = typeCount
            self.errorCount = errorCount
            self.warningCount = warningCount
            self.infoCount = infoCount
            self.unratedCount = unratedCount
            self.affectedEvents = affectedEvents
            self.topTitle = topTitle
            self.topSeverity = topSeverity
            self.topCount = topCount
            self.topSparkline = topSparkline
            self.windowTitle = windowTitle
            self.capturedAt = capturedAt
        }

        /// Reduces a warnings response to the digest.
        ///
        /// One request in, one small value out. The ranking is
        /// `IngestionWarning.mostUrgentFirst` rather than a second opinion
        /// invented here: a widget that disagreed with the screen it links to
        /// would be worse than no widget.
        public init(warnings: [IngestionWarning], window: IngestionWarningWindow, capturedAt: Date) {
            let top = warnings.min(by: IngestionWarning.mostUrgentFirst)
            self.init(
                typeCount: warnings.count,
                errorCount: warnings.count { $0.severity == .error },
                warningCount: warnings.count { $0.severity == .warning },
                infoCount: warnings.count { $0.severity == .info },
                unratedCount: warnings.count { if case .unknown = $0.severity { true } else { false } },
                affectedEvents: warnings.reduce(0) { $0 + $1.count },
                topTitle: top?.title,
                topSeverity: top.map { Severity($0.severity) },
                topCount: top?.count ?? 0,
                // The newest buckets are the ones a trend line is read for.
                topSparkline: Array((top?.sparkline ?? []).suffix(Self.sparklineLimit)),
                windowTitle: window.title,
                capturedAt: capturedAt
            )
        }

        /// Whether there is a series worth drawing. An all-zero sparkline is a
        /// fact — the warning fired outside this window — but a flat line at zero
        /// reads as a rendering failure, so the view says it in words instead.
        public var hasTrend: Bool { topSparkline.contains { $0 > 0 } }

        // MARK: Decoding

        /// Every field but the timestamp defaults.
        ///
        /// Synthesised decoding would throw the moment a newer app added a field
        /// and an older widget read it back — one absent key taking down a whole
        /// section. `capturedAt` is the exception, and throwing there is the
        /// point: a section that cannot say how old it is cannot be labelled
        /// honestly, so it is dropped by the snapshot's own decoder rather than
        /// rendered with an invented age.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            capturedAt = try c.decode(Date.self, forKey: .capturedAt)
            typeCount = try c.decodeIfPresent(Int.self, forKey: .typeCount) ?? 0
            errorCount = try c.decodeIfPresent(Int.self, forKey: .errorCount) ?? 0
            warningCount = try c.decodeIfPresent(Int.self, forKey: .warningCount) ?? 0
            infoCount = try c.decodeIfPresent(Int.self, forKey: .infoCount) ?? 0
            unratedCount = try c.decodeIfPresent(Int.self, forKey: .unratedCount) ?? 0
            affectedEvents = try c.decodeIfPresent(Int.self, forKey: .affectedEvents) ?? 0
            topTitle = try c.decodeIfPresent(String.self, forKey: .topTitle)
            topSeverity = (try? c.decodeIfPresent(Severity.self, forKey: .topSeverity)) ?? nil
            topCount = try c.decodeIfPresent(Int.self, forKey: .topCount) ?? 0
            topSparkline = try c.decodeIfPresent([Double].self, forKey: .topSparkline) ?? []
            // Not defaulted to a window name that was never asked for: an empty
            // label draws no axis caption, a wrong one mislabels the axis.
            windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle) ?? "the window"
        }
    }
}

extension SharedSnapshot.Severity {

    /// Flattens the client's open-ended severity into the four bands that cross
    /// the process boundary.
    init(_ severity: IngestionWarningSeverity) {
        switch severity {
        case .error: self = .error
        case .warning: self = .warning
        case .info: self = .info
        case .unknown: self = .unrated
        }
    }
}

// MARK: - Quota

extension SharedSnapshot {

    /// Metered resources, reduced to the one question worth asking away from a
    /// desk: is anything about to stop being accepted, or has it already.
    public struct QuotaDigest: Codable, Sendable, Hashable {

        /// Resources PostHog has already stopped accepting. Not a forecast.
        public let blockedCount: Int
        /// Resources at or past the app's watch band — half the allowance gone.
        public let pressingCount: Int
        /// How many metered resources the response described at all, so a card
        /// can say "1 of 18" rather than implying the project has one.
        public let resourceCount: Int

        public let topTitle: String?
        public let topState: QuotaState?
        public let topUsage: Double?
        /// `nil` means the payload carried **no limit** for this resource, which
        /// several of them do. It never means zero, and no reader may substitute
        /// one — "18 of 0" beside a full bar claims an overage nobody reported.
        public let topLimit: Double?

        /// Its own capture time, because this section is deliberately older than
        /// the rest of the snapshot most of the time. See `refreshInterval`.
        public let capturedAt: Date

        /// How often quota is worth a request.
        ///
        /// Twelve hours, against a background wake that runs every two. A monthly
        /// allowance does not move meaningfully in two hours, and every refetch
        /// is a request against an organisation-wide budget shared with the
        /// user's production integrations — so this section is fetched at most
        /// twice a day and carried forward in between, with its own age attached
        /// so no surface presents a half-day-old percentage as current.
        public static let refreshInterval: TimeInterval = 12 * 60 * 60

        /// Whether a refresh should spend the request.
        ///
        /// A capture stamped in the future is clock drift, not urgency: it reads
        /// as "not due", which errs towards spending nothing.
        public static func isDue(previous: QuotaDigest?, now: Date) -> Bool {
            guard let previous else { return true }
            return now.timeIntervalSince(previous.capturedAt) >= refreshInterval
        }

        public init(
            blockedCount: Int = 0,
            pressingCount: Int = 0,
            resourceCount: Int = 0,
            topTitle: String? = nil,
            topState: QuotaState? = nil,
            topUsage: Double? = nil,
            topLimit: Double? = nil,
            capturedAt: Date
        ) {
            self.blockedCount = blockedCount
            self.pressingCount = pressingCount
            self.resourceCount = resourceCount
            self.topTitle = topTitle
            self.topState = topState
            self.topUsage = topUsage
            self.topLimit = topLimit
            self.capturedAt = capturedAt
        }

        /// Reduces the eighteen-row response to its headline.
        ///
        /// `QuotaLimits` already ranks worst-first and already knows which rows
        /// are pressing, so nothing is re-derived here — a client that recomputed
        /// the bands would sooner or later disagree with the Settings screen
        /// reading the same response.
        public init(_ limits: QuotaLimits, capturedAt: Date) {
            let top = limits.resources.first
            self.init(
                blockedCount: limits.blockedCount,
                pressingCount: limits.pressing.count,
                resourceCount: limits.resources.count,
                topTitle: top?.title,
                topState: top.map { QuotaState($0.pressure) },
                topUsage: top?.usage,
                topLimit: top?.limit,
                capturedAt: capturedAt
            )
        }

        /// Share of the allowance consumed, uncapped so an overage stays visible
        /// as one. Callers drawing a bar clamp it themselves.
        public var topFraction: Double? {
            guard let topLimit, let topUsage else { return nil }
            guard topLimit > 0 else { return topUsage > 0 ? 1 : 0 }
            return topUsage / topLimit
        }

        // MARK: Decoding

        /// Same rule as `IngestionDigest`: everything defaults except the
        /// timestamp, which is what makes the section droppable rather than
        /// dateable.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            capturedAt = try c.decode(Date.self, forKey: .capturedAt)
            blockedCount = try c.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
            pressingCount = try c.decodeIfPresent(Int.self, forKey: .pressingCount) ?? 0
            resourceCount = try c.decodeIfPresent(Int.self, forKey: .resourceCount) ?? 0
            topTitle = try c.decodeIfPresent(String.self, forKey: .topTitle)
            // A state written by a newer build decodes to nil — "not stated" —
            // rather than throwing. The counts above carry the verdict.
            topState = (try? c.decodeIfPresent(QuotaState.self, forKey: .topState)) ?? nil
            topUsage = try c.decodeIfPresent(Double.self, forKey: .topUsage)
            topLimit = try c.decodeIfPresent(Double.self, forKey: .topLimit)
        }
    }
}

extension SharedSnapshot.QuotaState {

    init(_ pressure: QuotaPressure) {
        switch pressure {
        case .blocked: self = .blocked
        case .critical: self = .critical
        case .watch: self = .watch
        case .clear: self = .clear
        case .unmetered: self = .unmetered
        }
    }
}

// MARK: - Verdict

extension SharedSnapshot {

    /// What the health surfaces lead with.
    public enum HealthVerdict: Sendable, Hashable {
        /// Something is already broken: data is being refused or rejected now.
        case critical
        /// Something is heading that way and there is still time to act.
        case attention
        /// Every check that ran came back clean.
        case clear
        /// No check ran. **Not** the same as clear, and never drawn as one.
        case unchecked

        public var title: String {
            switch self {
            case .critical: "Critical"
            case .attention: "Needs attention"
            case .clear: "Healthy"
            case .unchecked: "Not checked"
            }
        }

        /// State is carried by glyph and word together; the tint only repeats it.
        public var symbolName: String {
            switch self {
            case .critical: "exclamationmark.octagon.fill"
            case .attention: "exclamationmark.triangle.fill"
            case .clear: "checkmark.circle.fill"
            case .unchecked: "arrow.down.circle.dotted"
            }
        }
    }

    /// The worst thing either section is reporting.
    ///
    /// Ordered by consequence rather than by severity label. A blocked quota is
    /// first because it is the only state where data is already being *refused*
    /// — an ingestion error rejects some events, a quota block rejects all of
    /// them — and it is the one failure that produces no warning anywhere else.
    public var healthVerdict: HealthVerdict {
        guard ingestion != nil || quota != nil else { return .unchecked }
        if (quota?.blockedCount ?? 0) > 0 { return .critical }
        if (ingestion?.errorCount ?? 0) > 0 { return .critical }
        if quota?.topState == .critical { return .attention }
        if ((ingestion?.warningCount ?? 0) + (ingestion?.unratedCount ?? 0)) > 0 { return .attention }
        if quota?.topState == .watch { return .attention }
        return .clear
    }

    /// The single worst fact, short enough for an accessory family.
    public var healthHeadline: String {
        switch healthVerdict {
        case .unchecked:
            return "Not checked yet"
        case .critical:
            if let blocked = quota?.blockedCount, blocked > 0 {
                return blocked == 1 ? "1 quota at its limit" : "\(blocked) quotas at their limit"
            }
            let errors = ingestion?.errorCount ?? 0
            return errors == 1 ? "1 ingestion error" : "\(errors) ingestion errors"
        case .attention:
            if quota?.topState == .critical, let title = quota?.topTitle {
                return "\(title) near its limit"
            }
            let concerning = (ingestion?.warningCount ?? 0) + (ingestion?.unratedCount ?? 0)
            if concerning > 0 {
                return concerning == 1 ? "1 ingestion warning" : "\(concerning) ingestion warnings"
            }
            if let title = quota?.topTitle { return "\(title) over half used" }
            return "Needs attention"
        case .clear:
            // Not "OK" and not an empty string: a project that genuinely has
            // nothing wrong has to read as an answer, not as a widget that
            // failed to load.
            return "Nothing to report"
        }
    }

    /// Which checks actually ran.
    ///
    /// Load-bearing rather than decorative. A quota-blocked project produces no
    /// ingestion warnings at all, so "nothing to report" over an unchecked quota
    /// is a clean bill of health for a project dropping every event. This line is
    /// what stops the headline from over-claiming.
    public var healthDetail: String {
        switch (ingestion != nil, quota != nil) {
        case (true, true): "Ingestion and quota checked"
        case (true, false): "Quota not checked"
        case (false, true): "Ingestion not checked"
        case (false, false): "Open GetHog to sync"
        }
    }

    /// Spoken form: the verdict, the fact, and what was looked at.
    public var healthSpokenLabel: String {
        "\(healthVerdict.title). \(healthHeadline). \(healthDetail)."
    }

    /// How far a section's own capture may lag the snapshot's before its age has
    /// to be stated separately. One widget timeline step: below that the two
    /// round to the same phrase anyway.
    public static let sectionAgeTolerance: TimeInterval = 15 * 60

    /// Whether a section was carried forward from an earlier refresh.
    ///
    /// The footer's "Updated 4m ago" is a claim about the metrics. Letting it
    /// stand over a twelve-hour-old quota figure would be this app lying about
    /// freshness, so a carried-forward section states its own age instead.
    public func isCarriedForward(_ sectionCapturedAt: Date) -> Bool {
        capturedAt.timeIntervalSince(sectionCapturedAt) > Self.sectionAgeTolerance
    }
}
