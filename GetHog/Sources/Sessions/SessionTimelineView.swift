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

    func load(client: PostHogClient, projectID: Int, sessionID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.sessionEvents(projectID: projectID, sessionID: sessionID, limit: Self.limit)
            )
            events = response.rows.compactMap(EventRow.init(row:))
            didHitLimit = events.count >= Self.limit
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
        switch event.event {
        case "$pageview": "Page view"
        case "$pageleave": "Page leave"
        case "$autocapture": "Autocapture"
        case "$exception": "Exception"
        case "$rageclick": "Rage click"
        default: event.event
        }
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

    private var entries: [TimelineEntry] {
        let base = origin ?? recording.startTime ?? store.events.first?.timestamp
        return store.events.map { TimelineEntry(event: $0, origin: base) }
    }

    private var visible: [TimelineEntry] {
        entries.filter(filter.matches)
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
                }

                if store.didHitLimit {
                    Text("Showing the first \(SessionTimelineStore.limit) events.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "Timeline", systemImage: "list.bullet.indent")
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
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                TimelineRowView(
                    entry: entry,
                    isLast: index == visible.count - 1,
                    isExpanded: expanded.contains(entry.id),
                    canSeek: canSeek,
                    onToggle: { toggle(entry.id) },
                    onSeek: { onSeek?(entry.offset) }
                )
            }
        }
        .skeleton(store.isLoading && store.events.isEmpty)
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
                .foregroundStyle(Theme.Status.critical)
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

    private var tint: Color {
        if entry.isError { return Theme.Status.critical }
        if entry.isCustom { return Theme.accent }
        return Color.secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(SessionClock.offset(entry.offset))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: offsetWidth, alignment: .trailing)
                .padding(.top, 2)

            rail

            VStack(alignment: .leading, spacing: 6) {
                summary
                if isExpanded { properties }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
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

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Two lines: custom events fall through to their raw name,
                    // and `checkout_payment_method_selected` clipped to one line
                    // reads the same as its neighbours — the tail is the part
                    // someone is scanning this timeline for.
                    Text(entry.title)
                        .font(.subheadline.weight(entry.isCustom ? .semibold : .regular))
                        .foregroundStyle(entry.isError ? Theme.Status.critical : .primary)
                        .lineLimit(2)
                    if entry.isError {
                        StatusPill(text: "Error", tint: Theme.Status.critical)
                    }
                }
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if canSeek {
                Button(action: onSeek) {
                    Image(systemName: "play.circle")
                        .font(.body)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play the replay from \(SessionClock.spoken(entry.offset))")
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(isExpanded ? "Collapses properties" : "Expands properties")
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
