import Observation
import GetHogKit
import SwiftUI

// MARK: - Time formatting

/// Session time is always expressed as an offset from the start of the session.
///
/// An absolute wall-clock timestamp tells you nothing useful when you are
/// watching a replay — "+1:23" lines the event up with the playhead.
enum SessionClock {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func offset(_ seconds: TimeInterval) -> String {
        seconds < -0.5 ? "-\(clock(-seconds))" : "+\(clock(seconds))"
    }

    /// VoiceOver should say "1 minute 23 seconds", not "plus one colon twenty three".
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        return Duration.seconds(total).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, zeroValueUnits: .hide)
        )
    }
}

// MARK: - Store

/// Loads the events that happened during one session.
///
/// This is the reliable half of the session screen: it uses the documented
/// `/query/` endpoint, so it keeps working when the internal replay API doesn't.
@MainActor
@Observable
final class SessionTimelineStore {
    static let limit = 500

    private(set) var events: [EventRow] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    private(set) var didHitLimit = false
    /// Rows PostHog returned, which is not `events.count` — see `load`. Kept so
    /// the truncation notice can name the figure that is actually on the wire.
    private(set) var rowsReturned = 0

    /// `window` is the recording's own span, which the caller always has.
    ///
    /// Required rather than optional so the unbounded form cannot return by
    /// omission — the events feed's timeout was exactly that shape, and this
    /// query hits the same shared `events` table.
    func load(
        client: PostHogClient,
        projectID: Int,
        sessionID: String,
        window: ClosedRange<Date>
    ) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.sessionEvents(
                    projectID: projectID,
                    sessionID: sessionID,
                    within: window,
                    limit: Self.limit
                )
            )
            events = response.rows.compactMap(EventRow.init(row:))
            // **`response.rows`, not `events`.** This read `events.count >=
            // limit`, and `events` is what survived `EventRow.init(row:)` — a
            // failable initialiser that returns nil for any row without an
            // `event` column. One undecodable row in a full page put the count
            // at 499 against a ceiling of 500 and the notice below vanished
            // silently, which is to say the notice disappeared precisely when
            // the data was least trustworthy: the reader was shown a partial
            // timeline, missing a row, with nothing saying either thing.
            // Counting the rows PostHog returned answers the question actually
            // being asked — did this query reach its ceiling — and is unaffected
            // by what the client could make of them.
            //
            // `isTruncated` as well, and it is not redundant: measured and
            // recorded in `PostHogAPI+Groups.swift`, `hasMore` and `limit` come
            // back only when PostHog applied its *own* cap, so for a query that
            // writes `LIMIT 500` the flag is silent at the ceiling and the count
            // is the evidence. If PostHog ever caps below our limit, the flag is
            // the only evidence and the count would miss it. Neither subsumes
            // the other.
            rowsReturned = response.rows.count
            didHitLimit = response.isTruncated || rowsReturned >= Self.limit
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Model

struct TimelineEntry: Identifiable {
    let event: EventRow
    let offset: TimeInterval
    let isError: Bool
    let isPageview: Bool
    let isCustom: Bool

    var id: String { event.id }

    init(event: EventRow, origin: Date?) {
        self.event = event
        if let origin, let timestamp = event.timestamp {
            offset = timestamp.timeIntervalSince(origin)
        } else {
            offset = 0
        }
        isError = Self.looksLikeError(event)
        isPageview = ["$pageview", "$pageleave", "$screen"].contains(event.event)
        // Anything without PostHog's `$` prefix was instrumented by the product
        // team, which is usually what someone is scanning a session for.
        isCustom = !event.event.hasPrefix("$")
    }

    var title: String {
        // Shared with the events feed, so the same event never has two names
        // in two tabs.
        EventAppearance.displayName(for: event.event)
    }

    var subtitle: String? {
        if isError, let message = errorMessage { return message }
        if let url = event.currentURL, let parsed = URL(string: url) {
            let path = parsed.path.isEmpty ? "/" : parsed.path
            return parsed.query.map { "\(path)?\($0)" } ?? path
        }
        return event.currentURL
    }

    private var errorMessage: String? {
        event.properties?["$exception_message"]?.stringValue
            ?? event.properties?["$exception_type"]?.stringValue
            ?? event.properties?["$exception_list"]?.stringValue
    }

    private static func looksLikeError(_ event: EventRow) -> Bool {
        if event.event == "$exception" { return true }
        if let level = event.properties?["$level"]?.stringValue,
           level.caseInsensitiveCompare("error") == .orderedSame {
            return true
        }
        if event.properties?["$exception_message"] != nil { return true }
        let name = event.event.lowercased()
        return name.contains("error") || name.contains("exception")
    }
}

/// What the timeline actually draws: an entry on its own, or a run of
/// consecutive lookalikes folded into one row.
///
/// Measured in the sweep: a busy session put nine consecutive `Autocapture ·
/// /same/path` rows on screen, four of them stamped the same minute — nineteen
/// rows per screen for ~48 screens, all saying the same thing. A run row says
/// it once, with a count and a span, and expands in place when the individual
/// moments matter. Errors and custom events never fold: they are what someone
/// is scanning a session *for*, and burying an exception inside "×9" would be
/// the exact noise this exists to remove.
enum TimelineDisplayItem: Identifiable {
    case single(TimelineEntry)
    case run([TimelineEntry])

    var id: String {
        switch self {
        case .single(let entry): entry.id
        case .run(let entries): "run-\(entries.first?.id ?? "")"
        }
    }

    /// Three is the floor for folding: two identical rows read fine, and a
    /// "×2" row costs a tap to see what two rows would have just shown.
    static let runThreshold = 3

    static func grouped(_ entries: [TimelineEntry]) -> [TimelineDisplayItem] {
        var result: [TimelineDisplayItem] = []
        var buffer: [TimelineEntry] = []
        func flush() {
            if buffer.count >= runThreshold {
                result.append(.run(buffer))
            } else {
                result.append(contentsOf: buffer.map(TimelineDisplayItem.single))
            }
            buffer.removeAll()
        }
        for entry in entries {
            if entry.isError || entry.isCustom {
                flush()
                result.append(.single(entry))
                continue
            }
            if let last = buffer.last,
               last.title == entry.title,
               last.subtitle == entry.subtitle {
                buffer.append(entry)
            } else {
                flush()
                buffer = [entry]
            }
        }
        flush()
        return result
    }
}

enum TimelineFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case errors = "Errors"
    case pageviews = "Pageviews"
    case custom = "Custom"

    var id: String { rawValue }

    func matches(_ entry: TimelineEntry) -> Bool {
        switch self {
        case .all: true
        case .errors: entry.isError
        case .pageviews: entry.isPageview
        case .custom: entry.isCustom
        }
    }
}

// MARK: - View

struct SessionTimelineView: View {
    let recording: SessionRecording
    let store: SessionTimelineStore
    /// The instant offsets are measured from. Prefer the replay's own first
    /// snapshot when one is loaded, so a tap seeks to the right frame.
    var origin: Date?
    var canSeek = false
    var onSeek: ((TimeInterval) -> Void)?

    @State private var filter: TimelineFilter = .all
    @State private var expanded: Set<String> = []
    @State private var expandedRuns: Set<String> = []
    @State private var showingAll = false

    /// The same collapse contract as the console and network panes, which cap
    /// at 12 with a "Show all N" toggle. The timeline was the only long list
    /// on this screen without one — a busy session rendered up to 500 rows
    /// eagerly, ~47 screens of scrolling before anything below it. The cap is
    /// higher than the siblings' because the timeline is the primary content
    /// here, not the supporting evidence.
    static let collapsedLimit = 25

    private var entries: [TimelineEntry] {
        let base = origin ?? recording.startTime ?? store.events.first?.timestamp
        return store.events.map { TimelineEntry(event: $0, origin: base) }
    }

    private var visible: [TimelineEntry] {
        entries.filter(filter.matches)
    }

    /// Consecutive lookalikes folded into runs — see `TimelineDisplayItem`.
    private var items: [TimelineDisplayItem] {
        TimelineDisplayItem.grouped(visible)
    }

    /// The cap counts drawn rows, not events: a folded run is one row however
    /// many moments it holds, and the "Show all" figure below matches what
    /// pressing it will actually add to the screen.
    private var shown: [TimelineDisplayItem] {
        showingAll ? items : Array(items.prefix(Self.collapsedLimit))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                filterChips

                if let error = store.error, store.events.isEmpty {
                    failure(error)
                } else if store.events.isEmpty && store.isLoading {
                    loading
                } else if store.events.isEmpty {
                    empty("No events were captured during this session.")
                } else if visible.isEmpty {
                    empty("No \(filter.rawValue.lowercased()) in this session.")
                } else {
                    timeline
                    showAllFooter
                }

                if let earliest = visible.first?.offset, earliest < -1 {
                    // The network pane explains its own sub-zero starts; the
                    // timeline owed the same sentence. Offsets count from the
                    // replay's first frame, and PostHog stamps events the page
                    // fired while recording was still spinning up.
                    Text("Events before +0:00 had already fired when the recording's first frame was captured.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if store.didHitLimit {
                    // Reports what came back, not what was asked for. The two
                    // used to be the same number by construction, because the
                    // only way this notice appeared was the count reaching the
                    // ceiling; now that PostHog's own cap can raise it as well,
                    // the request's limit is no longer necessarily the figure on
                    // screen. Naming the wrong one would be a smaller version of
                    // the defect this whole notice exists to prevent.
                    Text("Showing the first \(store.rowsReturned) events of this session.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "Timeline", productMark: .session)
            Spacer()
            Text("\(visible.count) of \(entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Showing \(visible.count) of \(entries.count) events")
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(TimelineFilter.allCases) { option in
                    let count = entries.filter(option.matches).count
                    Button {
                        filter = option
                        // A fresh filter starts collapsed again, as the console
                        // and network panes do: "show all errors" and "show all
                        // 500 of everything" are different-sized requests.
                        showingAll = false
                        expandedRuns.removeAll()
                    } label: {
                        HStack(spacing: 5) {
                            Text(option.rawValue)
                            Text("\(count)").monospacedDigit().opacity(0.7)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(filter == option ? Theme.accent : Color.secondary)
                        // Glass rather than a drawn capsule, so the chips read as
                        // chrome over the card instead of as four small tiles.
                        // The active tint is the app accent, which is what makes
                        // the selected chip read as "on" and not merely filled.
                        .warmGlass(active: filter == option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.rawValue), \(count) events")
                    .accessibilityAddTraits(filter == option ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private var timeline: some View {
        // Lazy because "Show all" can realise hundreds of rows at once; the
        // page's scroll view lets laziness actually defer the off-screen ones.
        LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                let isLastItem = index == shown.count - 1
                switch item {
                case .single(let entry):
                    row(entry, isLast: isLastItem)
                case .run(let runEntries):
                    if expandedRuns.contains(item.id) {
                        ForEach(Array(runEntries.enumerated()), id: \.element.id) { position, entry in
                            row(entry, isLast: isLastItem && position == runEntries.count - 1)
                        }
                    } else {
                        TimelineRunRowView(
                            entries: runEntries,
                            isLast: isLastItem,
                            canSeek: canSeek,
                            onToggle: { expandedRuns.insert(item.id) },
                            onSeek: { onSeek?(runEntries[0].offset) }
                        )
                    }
                }
            }
        }
        .skeleton(store.isLoading && store.events.isEmpty)
    }

    private func row(_ entry: TimelineEntry, isLast: Bool) -> some View {
        TimelineRowView(
            entry: entry,
            isLast: isLast,
            isExpanded: expanded.contains(entry.id),
            canSeek: canSeek,
            onToggle: { toggle(entry.id) },
            onSeek: { onSeek?(entry.offset) }
        )
    }

    @ViewBuilder
    private var showAllFooter: some View {
        if items.count > Self.collapsedLimit {
            Button(showingAll ? "Show fewer" : "Show all \(items.count) rows") {
                showingAll.toggle()
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Status.accentInk)
            .minimumHitTarget()
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 10) {
                    Text("+0:00").font(.caption2.monospacedDigit())
                    Circle().frame(width: 9, height: 9)
                    Text("Loading event").font(.subheadline)
                    Spacer()
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private func empty(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load the timeline", systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Status.criticalInk)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

// MARK: - Row

/// A folded run of consecutive lookalike events: one gutter timestamp, one
/// title carrying the count, and the span the run covers. Tapping unfolds it
/// into its individual rows in place.
struct TimelineRunRowView: View {
    let entries: [TimelineEntry]
    let isLast: Bool
    let canSeek: Bool
    let onToggle: () -> Void
    let onSeek: () -> Void

    @ScaledMetric(relativeTo: .caption2) private var offsetWidth: CGFloat = 54
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var first: TimelineEntry { entries[0] }
    private var span: String {
        let last = entries[entries.count - 1]
        return "\(SessionClock.offset(first.offset)) – \(SessionClock.offset(last.offset))"
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    offsetLabel
                    summary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 14)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    offsetLabel
                        .frame(width: offsetWidth, alignment: .trailing)
                        .padding(.top, 2)

                    rail

                    summary
                        .padding(.bottom, isLast ? 0 : 14)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
    }

    private var offsetLabel: some View {
        Text(SessionClock.offset(first.offset))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// A stack of three dots rather than one: the rail's way of saying this
    /// stop stands for several.
    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
            }
            .padding(.top, 1)
            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 9)
        .accessibilityHidden(true)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(first.title) ×\(entries.count)")
                    .font(.subheadline.weight(.medium))
                if let subtitle = first.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .typesettingLanguage(Locale.Language(identifier: "zxx"))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                Text(span)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Ink.tertiary)
            }

            Spacer(minLength: 4)

            if canSeek {
                Button(action: onSeek) {
                    Image(systemName: "play.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                        .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Play the replay from \(SessionClock.spoken(max(0, first.offset)))"
                )
            }

            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entries.count) \(first.title) events between \(SessionClock.spoken(max(0, first.offset))) and \(SessionClock.spoken(max(0, entries[entries.count - 1].offset)))"
        )
        .accessibilityHint("Expands into individual events")
    }
}

struct TimelineRowView: View {
    let entry: TimelineEntry
    let isLast: Bool
    let isExpanded: Bool
    let canSeek: Bool
    let onToggle: () -> Void
    let onSeek: () -> Void

    /// The gutter holds `SessionClock.offset`, which is "+1:23:45" for any
    /// session over an hour — already the full 54pt at default size, so a fixed
    /// width truncated the hour off exactly the sessions long enough to need it.
    @ScaledMetric(relativeTo: .caption2) private var offsetWidth: CGFloat = 54

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tint: Color {
        if entry.isError { return Theme.Status.critical }
        if entry.isCustom { return Theme.accent }
        return Color.secondary
    }

    /// A gutter, a rail and the event — until the gutter costs more than the
    /// event is worth.
    ///
    /// `offsetWidth` scales with the type, which is right and is also the whole
    /// problem: 54pt at the default size is **206pt at AX5**, and with the rail
    /// beside it two thirds of a phone's width were spent on a timestamp before
    /// the event got a character. What the event had left could not hold its own
    /// longest word, so the row reported a width past the viewport — and because
    /// every card on this screen shares one stack, the *page* was that wide.
    /// Measured in a 393pt window: the timeline alone asked for 413pt, and the
    /// summary card next door for 447pt.
    ///
    /// Stacked, the timestamp is a line of its own and everything below it gets
    /// the full width. Same reflow as `FunnelStepRow` and `InsightLegend`.
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    offsetLabel
                    summary
                    if isExpanded { properties }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 14)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    offsetLabel
                        .frame(width: offsetWidth, alignment: .trailing)
                        .padding(.top, 2)

                    rail

                    VStack(alignment: .leading, spacing: 6) {
                        summary
                        if isExpanded { properties }
                    }
                    .padding(.bottom, isLast ? 0 : 14)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
    }

    private var offsetLabel: some View {
        Text(SessionClock.offset(entry.offset))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 9)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var summary: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The chevron is dropped for the reason `RowCard` drops its own
                // when it stacks: it is decorative, hidden from VoiceOver, and on
                // its own line it is a large grey arrow pointing at nothing. The
                // seek button is content and keeps its place.
                VStack(alignment: .leading, spacing: 6) {
                    titleBlock
                    seekButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleBlock

                    Spacer(minLength: 4)

                    seekButton

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(isExpanded ? "Collapses properties" : "Expands properties")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The pill refuses compression by design, so beside a title it is a
            // second column that cannot yield — at accessibility sizes the two
            // do not share a line.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) { nameAndErrorPill }
            } else {
                HStack(spacing: 6) { nameAndErrorPill }
            }
            if let subtitle = entry.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
    }

    @ViewBuilder
    private var nameAndErrorPill: some View {
        // Two lines: custom events fall through to their raw name, and
        // `checkout_payment_method_selected` clipped to one line reads the same
        // as its neighbours — the tail is the part someone is scanning this
        // timeline for.
        Text(entry.title)
            .font(.subheadline.weight(entry.isCustom ? .semibold : .regular))
            .foregroundStyle(entry.isError ? Theme.Status.criticalInk : .primary)
            // An event name is an identifier, never prose.
            .typesettingLanguage(Locale.Language(identifier: "zxx"))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        if entry.isError {
            StatusPill(text: "Error", tint: Theme.Status.critical)
        }
    }

    /// Measured at **16.0 × 16.0pt** through XCUITest on iPhone 17, against a
    /// 44 × 44 floor — and it is the worst kind of undersized control, because
    /// the 28pt of row around it is not dead space but the *toggle*. Missing the
    /// glyph does not do nothing; it expands the row instead, which reads as the
    /// seek having been ignored. `ReplayConsoleRow` and `ReplayNetworkRow` are
    /// the same button in the same kind of row and already carry the modifier;
    /// these two were the pair that did not.
    ///
    /// Inside the label closure, for the reason `HitTargetTests` records: under
    /// `.plain` the tap region is the label's bounds and nothing else, so the
    /// same modifier applied to the `Button` moves nothing.
    ///
    /// The guide is the other half of it. An `Image` baseline-aligns on its
    /// *bottom* edge, so a 44pt box in a `.firstTextBaseline` row would hang its
    /// whole height above the title's baseline and the glyph would rise 22pt out
    /// of the row. Centring the box on the baseline puts the glyph on the line it
    /// belongs to and grows the row symmetrically.
    @ViewBuilder
    private var seekButton: some View {
        if canSeek {
            Button(action: onSeek) {
                Image(systemName: "play.circle")
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .minimumHitTarget()
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            .accessibilityLabel("Play the replay from \(SessionClock.spoken(entry.offset))")
        }
    }

    @ViewBuilder
    private var properties: some View {
        if case .object(let dictionary)? = entry.event.properties, !dictionary.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(dictionary.keys.sorted(), id: \.self) { key in
                    PropertyRow(key: key, value: dictionary[key] ?? .null)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.pageBackground, in: .rect(cornerRadius: 8))
        } else {
            Text("No properties recorded.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilityDescription: String {
        var parts = ["\(entry.title), \(SessionClock.spoken(entry.offset)) into the session"]
        if entry.isError { parts.append("error") }
        if let subtitle = entry.subtitle { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}
