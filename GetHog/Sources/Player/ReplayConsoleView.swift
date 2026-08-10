import GetHogKit
import GetHogUI
import SwiftUI

/// The console pane of the replay screen.
///
/// Everything drawn here was already on the device: rrweb ships console output
/// as `type: 6` plugin events inside the same gzipped blobs the player fetches
/// to render frames, so this pane costs no request and no rate-limit budget.
struct ReplayConsoleCard: View {
    let diagnostics: ReplayDiagnostics
    /// The instant offsets are measured from — the replay's own first snapshot.
    let origin: Date?
    /// Playhead, in seconds from `origin`.
    let playhead: TimeInterval
    var canSeek = false
    /// Blobs are still arriving, so an empty list may just be an early one.
    var isStreaming = false
    var onSeek: ((TimeInterval) -> Void)?

    @State private var filter: ReplayConsoleFilter = .all
    @State private var expanded: Set<String> = []
    @State private var showingAll = false

    /// Long enough to be worth scrolling, short enough that a chatty session
    /// does not push the rest of the screen out of reach. The session timeline
    /// below this pane is unbounded already.
    private static let collapsedLimit = 12

    private var visible: [ReplayConsoleEntry] {
        diagnostics.console.filter(filter.matches)
    }

    private var shown: [ReplayConsoleEntry] {
        showingAll ? visible : Array(visible.prefix(Self.collapsedLimit))
    }

    private var status: ReplayCaptureStatus {
        diagnostics.capture.status(.console, hasEntries: !diagnostics.console.isEmpty)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header

                if diagnostics.console.isEmpty {
                    ReplayCaptureNoticeView(
                        notice: .console(status),
                        isStreaming: isStreaming
                    )
                } else {
                    filterChips
                    if visible.isEmpty {
                        Text(filter.emptyMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.Ink.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        list
                        footer
                    }
                }
            }
            // Same measure as the network pane below it, and for the same
            // reason: a console line's seek button was pinned to the trailing
            // edge of an 770pt card while the message it belongs to ended a
            // third of the way across. The two panes are read together, so they
            // are capped together rather than each finding its own width.
            .readableMeasure(Theme.Measure.pane)
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "Console", systemImage: "text.alignleft", productMark: .session)
            Spacer()
            let errors = diagnostics.consoleCount(.error)
            if errors > 0 {
                StatusPill(
                    text: "\(errors) error\(errors == 1 ? "" : "s")",
                    tint: Theme.Status.critical
                )
            }
        }
    }

    private var filterChips: some View {
        ReplayChipStrip {
            ForEach(ReplayConsoleFilter.allCases) { option in
                let count = diagnostics.console.count(where: option.matches)
                Button {
                    filter = option
                    showingAll = false
                } label: {
                    HStack(spacing: 5) {
                        Text(option.rawValue)
                        Text("\(count)").monospacedDigit().opacity(0.7)
                    }
                    .font(.caption.weight(.medium))
                    // A filter's name is a label, not a sentence — see the
                    // network pane's strip.
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(filter == option ? Theme.accent : Color.secondary)
                    .warmGlass(active: filter == option)
                    .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.rawValue), \(count) entries")
                .accessibilityAddTraits(filter == option ? [.isSelected] : [])
            }
        }
    }

    private var list: some View {
        // Lazy for the same reason as the network waterfall: "Show all" can
        // realise hundreds of rows inside the page's scroll view.
        LazyVStack(spacing: 0) {
            ForEach(shown) { entry in
                ReplayConsoleRow(
                    entry: entry,
                    offset: origin.map { entry.offset(from: $0) },
                    // Dimming what has not happened yet is the whole of this
                    // pane's playback sync: it is inside the page's own scroll
                    // view, so it cannot follow the playhead without taking the
                    // scroll position away from whoever is reading.
                    isAhead: isAhead(entry),
                    isExpanded: expanded.contains(entry.id),
                    canSeek: canSeek && origin != nil,
                    onToggle: { toggle(entry.id) },
                    onSeek: {
                        guard let origin else { return }
                        onSeek?(max(0, entry.offset(from: origin)))
                    }
                )
                if entry.id != shown.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if visible.count > Self.collapsedLimit {
            Button(showingAll ? "Show fewer" : "Show all \(visible.count)") {
                showingAll.toggle()
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Status.accentInk)
            .minimumHitTarget()
        }
        if isStreaming {
            Text("More of this session is still loading.")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }

    private func isAhead(_ entry: ReplayConsoleEntry) -> Bool {
        guard let origin else { return false }
        return entry.offset(from: origin) > playhead + 0.25
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

struct ReplayConsoleRow: View {
    let entry: ReplayConsoleEntry
    let offset: TimeInterval?
    let isAhead: Bool
    let isExpanded: Bool
    let canSeek: Bool
    let onToggle: () -> Void
    let onSeek: () -> Void

    /// Same gutter as the session timeline, and for the same reason: "+1:23:45"
    /// is already the full width at default size, so a fixed one truncates the
    /// hour off exactly the sessions long enough to need it.
    @ScaledMetric(relativeTo: .caption2) private var offsetWidth: CGFloat = 54

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(offset.map(SessionClock.offset) ?? "—")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: offsetWidth, alignment: .trailing)
                .padding(.top, 3)

            Circle()
                .fill(entry.level.mark)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary.isEmpty ? entry.rawLevel : entry.summary)
                    .font(.footnote)
                    .foregroundStyle(entry.level == .error ? entry.level.ink : Color.primary)
                    .lineLimit(isExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)

                if !isExpanded, let first = entry.detail.first {
                    Text(first)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                }

                if isExpanded { detail }
            }

            Spacer(minLength: 4)

            if canSeek {
                Button(action: onSeek) {
                    Image(systemName: "play.circle")
                        .font(.body)
                        .foregroundStyle(Theme.accent)
                        .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Play the replay from \(SessionClock.spoken(max(0, offset ?? 0)))"
                )
            }
        }
        .padding(.vertical, 8)
        // Something that has not happened yet is still worth listing — it is how
        // you find out an error is coming — but it should not read as current.
        .opacity(isAhead ? 0.45 : 1)
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(isExpanded ? "Collapses this entry" : "Expands this entry")
        .accessibilityAction(.default, onToggle)
    }

    @ViewBuilder
    private var detail: some View {
        ForEach(Array(entry.detail.enumerated()), id: \.offset) { _, part in
            Text(part)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.Ink.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !entry.trace.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stack")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
                ForEach(Array(entry.trace.prefix(8).enumerated()), id: \.offset) { _, frame in
                    Text(frame)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.Ink.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The level is a coloured dot and nothing else, so it has to be spoken.
    private var spokenLabel: String {
        var parts = [entry.level.label]
        if let offset { parts.append("at \(SessionClock.spoken(max(0, offset)))") }
        parts.append(entry.message)
        if isAhead { parts.append("Later than the playhead") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Empty state

/// The shared shape for "this pane has nothing in it, and here is why".
struct ReplayCaptureNoticeView: View {
    let notice: ReplayCaptureNotice
    var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(notice.title, systemImage: notice.icon)
                .font(.footnote.weight(.medium))
            Text(notice.detail)
                .font(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
            if isStreaming {
                Text("More of this session is still loading.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
