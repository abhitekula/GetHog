import GetHogKit
import GetHogUI
import SwiftUI

/// The network pane of the replay screen: a waterfall of everything the
/// recorded page fetched, positioned against session time.
///
/// Like the console pane, this is read out of rrweb plugin events that were
/// already in the blobs the player fetched — no extra request.
struct ReplayNetworkCard: View {
    let diagnostics: ReplayDiagnostics
    /// The instant offsets are measured from — the replay's own first snapshot.
    let origin: Date?
    /// Total session length, so the waterfall spans the whole thing rather than
    /// only the part that has requests in it.
    let duration: TimeInterval
    /// Playhead, in seconds from `origin`. Drawn as a rule across the waterfall.
    let playhead: TimeInterval
    var canSeek = false
    var isStreaming = false
    var onSeek: ((TimeInterval) -> Void)?

    @State private var filter: ReplayNetworkFilter = .all
    @State private var showingAll = false
    @State private var selected: String?

    /// Half the console pane's. A session's requests run to the hundreds and
    /// they are in time order, so the first screenful is the page's own boot —
    /// fonts and chunks. The chips are how you get past that, and "Show all" is
    /// one tap; what neither of them survives is a card a thousand points tall.
    /// Measured at the old cap of 12: ~1,050pt on a phone, more than a
    /// full screen of waterfall before anything after it. Six rows plus the
    /// summary line says what the network did; the rest is on request.
    private static let collapsedLimit = 6

    private var visible: [ReplayNetworkEntry] {
        diagnostics.network.filter(filter.matches)
    }

    private var shown: [ReplayNetworkEntry] {
        showingAll ? visible : Array(visible.prefix(Self.collapsedLimit))
    }

    private var status: ReplayCaptureStatus {
        diagnostics.capture.status(.network, hasEntries: !diagnostics.network.isEmpty)
    }

    /// Spans every entry *and* the whole playable duration, so the playhead rule
    /// and the bars share one coordinate system.
    private var scale: WaterfallScale {
        WaterfallScale(entries: diagnostics.network, origin: origin, duration: duration)
    }

    /// The site being recorded. Rows that went somewhere else say so.
    private var primaryHost: String? {
        ReplayNetworkHosts.primary(of: diagnostics.network)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header

                if diagnostics.network.isEmpty {
                    ReplayCaptureNoticeView(
                        notice: .network(status),
                        isStreaming: isStreaming
                    )
                } else {
                    summary
                    filterChips
                    if visible.isEmpty {
                        Text(filter.emptyMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.Ink.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        waterfall
                        axis
                        footer
                    }
                }
            }
            // The whole pane, not the rows one at a time, so the header, the
            // chips, the bars and the axis under them all end at the same
            // place — a waterfall whose bars stop 130pt short of its own time
            // axis would be lying about when things happened.
            //
            // Measured on `iPad Pro 11-inch (M5)` portrait: a request row put
            // `/_next/static/media/22a5144ee8d83bca-s.p.woff2` at the leading
            // edge and its `200` and `<1 ms` ~1090pt away at the trailing one,
            // with the status column so far from the path that the pair had to
            // be read twice. `pane` rather than `pair` because this row is not a
            // pair: the bar beneath it is a timeline and wants the span.
            .readableMeasure(Theme.Measure.pane)
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "Network", systemImage: "arrow.left.arrow.right", productMark: .session)
            Spacer()
            if diagnostics.failureCount > 0 {
                StatusPill(
                    text: "\(diagnostics.failureCount) failed",
                    tint: Theme.Status.critical
                )
            }
        }
    }

    private var summary: some View {
        Text(summaryText)
            .font(.caption)
            .foregroundStyle(Theme.Ink.secondary)
    }

    /// Describes what is on screen, not the session — under a filter the two
    /// differ, and a line reading "127 requests" above twelve rows and a
    /// "Show all 22" button is three numbers that do not add up.
    ///
    /// `wireSize` is `nil` for every fetch-wrapper entry, so the byte total is a
    /// floor rather than a sum. Saying "1.2 MB" when a third of the rows never
    /// reported a size would be a number nobody measured.
    private var summaryText: String {
        let count = visible.count
        let sized = visible.count { $0.wireSize != nil }
        let bytes = visible.compactMap(\.wireSize).reduce(0, +)
        let requests = "\(count) request\(count == 1 ? "" : "s")"
        guard sized > 0, let total = ReplayByteFormat.short(bytes) else { return requests }
        return sized == count
            ? "\(requests) · \(total)"
            : "\(requests) · \(total) across the \(sized) that reported a size"
    }

    private var filterChips: some View {
        ReplayChipStrip {
            ForEach(ReplayNetworkFilter.allCases) { option in
                let count = diagnostics.network.count(where: option.matches)
                Button {
                    filter = option
                    showingAll = false
                } label: {
                    HStack(spacing: 5) {
                        Text(option.rawValue)
                        Text("\(count)").monospacedDigit().opacity(0.7)
                    }
                    .font(.caption.weight(.medium))
                    // A filter's name is a label, not a sentence: "Documents"
                    // broken as `Docu-` / `ments` names no filter.
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(filter == option ? Theme.accent : Color.secondary)
                    .warmGlass(active: filter == option)
                    .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.rawValue), \(count) requests")
                .accessibilityAddTraits(filter == option ? [.isSelected] : [])
            }
        }
    }

    private var waterfall: some View {
        // Lazy: "Show all" can mean a couple of hundred rows, and eager rows
        // were the payload of the playback-starvation bug — every one carried
        // a GeometryReader re-laid-out on each playhead tick.
        LazyVStack(spacing: 0) {
            ForEach(shown) { entry in
                ReplayNetworkRow(
                    entry: entry,
                    offset: origin.map { entry.offset(from: $0) },
                    foreignHost: entry.host == primaryHost ? nil : entry.host,
                    scale: scale,
                    playheadFraction: scale.fraction(at: playhead),
                    isExpanded: selected == entry.id,
                    canSeek: canSeek && origin != nil,
                    onToggle: { selected = selected == entry.id ? nil : entry.id },
                    onSeek: {
                        guard let origin else { return }
                        onSeek?(max(0, entry.offset(from: origin)))
                    }
                )
            }
        }
    }

    /// The waterfall's own x-axis. Without it the bars are a picture rather than
    /// a measurement — there is no way to read *when* from a position alone.
    private var axis: some View {
        HStack {
            Text(SessionClock.offset(scale.start))
            Spacer()
            Text(SessionClock.clock(scale.end))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.Ink.tertiary)
        .accessibilityLabel(
            "Waterfall spans \(SessionClock.spoken(max(0, scale.start))) to \(SessionClock.spoken(scale.end))"
        )
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
        if visible.contains(where: \.isInitial) {
            Text(
                """
                Faded bars were already in the browser's buffer when recording started, \
                so they happened before the first frame.
                """
            )
            .font(.caption2)
            .foregroundStyle(Theme.Ink.tertiary)
        }
        if isStreaming {
            Text("More of this session is still loading.")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }
}

// MARK: - Row

struct ReplayNetworkRow: View {
    let entry: ReplayNetworkEntry
    let offset: TimeInterval?
    /// Set when this request did not go to the site being recorded.
    let foreignHost: String?
    let scale: WaterfallScale
    let playheadFraction: Double
    let isExpanded: Bool
    let canSeek: Bool
    let onToggle: () -> Void
    let onSeek: () -> Void

    /// Bar height, and — because the bar is a capsule — its own minimum width.
    /// A capsule narrower than it is tall renders as a squeezed sliver; at this
    /// floor a 6 ms request in a 19 minute session is a legible dot.
    private static let barHeight: CGFloat = 6

    /// `Color.secondary` is an alpha composite, and drawn over the track — which
    /// is itself a wash of the same ink — a static asset's bar was very nearly
    /// invisible. Measured on a rendered card before this was an opaque colour.
    private var tint: Color {
        if entry.isFailure { return Theme.Status.critical }
        if entry.method != nil { return Theme.accent }
        return Theme.Ink.secondary
    }

    /// Buffered entries are drawn back, not away. They describe real requests —
    /// the document load is usually one — and the fade is the only thing saying
    /// they happened before the first frame.
    private var barOpacity: Double { entry.isInitial ? 0.5 : 0.9 }

    private var bar: (x: Double, width: Double) {
        scale.bar(at: offset ?? 0, duration: entry.duration)
    }

    /// The waiting share of the bar, so a request that was slow to *start*
    /// answering looks different from one that was slow to download.
    private var waitingWidth: Double? {
        guard let waiting = entry.waiting, entry.duration > 0 else { return nil }
        return bar.width * min(waiting / entry.duration, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
            track
            if isExpanded { detail }
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        // `.contain`, not `.combine`: the seek button lives inside this row, and
        // combining the subtree would flatten it out of VoiceOver's reach.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(isExpanded ? "Collapses this request" : "Expands this request")
        .accessibilityAction(.default, onToggle)
    }

    /// `host/path` for a third-party request, bare path for the site's own.
    private var rowLabel: String {
        guard let foreignHost else { return entry.pathLabel }
        return foreignHost + entry.pathLabel
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let method = entry.method {
                Text(method)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.Ink.secondary)
            }
            Text(rowLabel)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.isFailure ? Theme.Status.criticalInk : Color.primary)

            Spacer(minLength: 4)

            if let status = entry.status {
                Text("\(status)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(
                        entry.isFailure ? Theme.Status.criticalInk : Theme.Ink.secondary
                    )
            }
            Text(ReplayByteFormat.duration(entry.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.Ink.tertiary)

            if canSeek {
                Button(action: onSeek) {
                    Image(systemName: "play.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                        .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Play the replay from \(SessionClock.spoken(max(0, offset ?? 0)))"
                )
            }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let barWidth = max(width * bar.width, Self.barHeight)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: Self.barHeight)

                // The whole request.
                Capsule()
                    .fill(tint.opacity(barOpacity))
                    .frame(width: barWidth, height: Self.barHeight)
                    // Clamped so a bar starting at the right edge stays inside
                    // the card rather than overflowing it.
                    .offset(x: min(width * bar.x, max(width - barWidth, 0)))

                // The part of it spent waiting for the first byte, drawn back
                // over the head of the bar: a request slow to *start* answering
                // looks different from one that was slow to download.
                if let waitingWidth {
                    Capsule()
                        .fill(Theme.cardBackground.opacity(0.55))
                        .frame(
                            width: max(width * waitingWidth, 1),
                            height: Self.barHeight - 2
                        )
                        .offset(x: min(width * bar.x, max(width - barWidth, 0)))
                }

                // Playback sync: where the playhead is, in the same coordinate
                // system as the bars.
                Rectangle()
                    .fill(Theme.accentWarm)
                    .frame(width: 1.5, height: 13)
                    .offset(x: min(max(width * playheadFraction - 0.75, 0), width - 1.5))
            }
            .frame(height: 13)
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.url)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.Ink.secondary)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                ForEach(facts, id: \.0) { fact in
                    Text("\(fact.0) \(fact.1)")
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    /// Only what the entry actually reported. A missing size is unknown, and
    /// printing "0 bytes" for it would be an invented measurement.
    private var facts: [(String, String)] {
        var out: [(String, String)] = []
        if let offset { out.append(("Start", SessionClock.offset(offset))) }
        if let waiting = entry.waiting {
            out.append(("Waiting", ReplayByteFormat.duration(waiting)))
        }
        if let size = ReplayByteFormat.short(entry.wireSize) {
            out.append((entry.isCached ? "Cached" : "Transferred", size))
        }
        if let initiator = entry.initiator { out.append(("Via", initiator)) }
        return out
    }

    private var spokenLabel: String {
        var parts: [String] = []
        if let method = entry.method { parts.append(method) }
        parts.append(rowLabel)
        if let status = entry.status {
            parts.append(entry.isFailure ? "failed with \(status)" : "status \(status)")
        }
        if let offset {
            parts.append("at \(SessionClock.spoken(max(0, offset)))")
        }
        parts.append("took \(ReplayByteFormat.duration(entry.duration))")
        if entry.isInitial { parts.append("Buffered before recording started") }
        return parts.joined(separator: ", ")
    }
}
