import GetHogKit
import SwiftUI

/// What the iPad detail pane shows before an issue is picked.
///
/// Measured on an 11-inch iPad in dark mode: `ContentUnavailableView("Select an
/// issue")` held roughly two thirds of the canvas — the largest surface in the
/// app spent on a single sentence, every time the screen was opened.
///
/// **Cost:** nothing. Every figure here is folded out of the same page of issues
/// the list is already holding. The rate-limit budget is organisation-wide, so a
/// summary nobody asked for must not spend a request of it.
///
/// **What is deliberately absent:** an occurrences-over-time chart. `ErrorIssue`
/// carries totals and first/last-seen stamps, never a series, so that chart
/// cannot be drawn from this data at all — only by asking for more. "New in
/// period" is the honest stand-in: it comes from `firstSeen`, and it answers the
/// same question of whether this is getting worse.
struct ErrorsOverview: View {
    let issues: [ErrorIssue]
    /// What `issues` is a page of. `nil` before the first load, when there are
    /// no figures to qualify yet.
    var coverage: ErrorIssueCoverage?
    let window: AnalyticsWindow
    let loadedAt: Date?
    @Binding var selection: ErrorIssue?

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(spacing: Theme.Space.xl) {
            header
            statusSection
            impactSection
            noisiestSection
            FreshnessLabel(date: loadedAt)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Error tracking · \(window.spokenTitle)", systemImage: "ladybug")

            Text(model.selectedProject?.name ?? "PostHog")
                .font(.largeTitle.weight(.semibold))

            StatStrip {
                MetricTile(label: "Issues", value: "\(issues.count)", compact: true)
                // Occurrences total because every occurrence belongs to exactly
                // one issue. Users deliberately do not: one person hitting three
                // issues would be counted three times, and a headline that
                // overstates how many people are hurt is worse than no headline.
                MetricTile(
                    label: "Occurrences",
                    value: totalOccurrences.compactFormatted,
                    compact: true
                )
                if let newInWindow {
                    MetricTile(label: "New in period", value: "\(newInWindow)", compact: true)
                }
            }
            .padding(.horizontal, -Theme.Space.l)

            coverageNote
        }
    }

    /// What the tiles above — and the status split and both rankings below —
    /// are totals *of*.
    ///
    /// The file header already said, correctly, that every figure here is folded
    /// out of the page the list is holding — and then the screen printed them as
    /// "Issues" and "Occurrences" with nothing on it naming the page. The query
    /// asks for a capped page of issues with the most people affected. When the
    /// envelope reports more rows,
    /// "Occurrences" is not a partial answer to how many occurrences there were,
    /// it is the sum over a ranked prefix. `ErrorIssueCoverage` explains why the
    /// better remedy — a denominator inside the query, the way
    /// `PostHogAPI.groupEventBreakdown` carries one — is not available for this
    /// query node.
    ///
    /// Always present, both readings, for the reason `HeatmapProfile.coverageNote`
    /// is: a line that appears only in the bad case makes its absence a claim,
    /// and the reader has no way to tell "complete" from "nobody wired the
    /// notice up on this branch".
    ///
    /// A sentence in the screen's own caption style, with no tint and no status
    /// glyph. Ranked coverage is not a fault — the app asked for a page and got
    /// one — and dressing it as a warning would put an alarm on every healthy
    /// project with more than fifty issues.
    @ViewBuilder
    private var coverageNote: some View {
        if let coverage, !issues.isEmpty {
            Text(coverage.note(shown: issues.count, window: window.spokenTitle.lowercased()))
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                // Wraps to whatever AX5 needs: the sentence names the scope of
                // every number on the screen, and half of that scope is not a
                // scope. Rendered and looked at at AX5 — it reflows to nine
                // lines in a 393pt window and is not clipped.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "By status", systemImage: "circle.lefthalf.filled")

            Card {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    statusCount("Active", active.count, Theme.Status.critical)
                    statusCount("Resolved", resolved.count, Theme.Status.good)
                    statusCount("Suppressed", suppressed.count, .secondary)
                }
            }
        }
    }

    /// The word is carried by the pill, never by the tint alone — same rule the
    /// list rows follow, and the reason the row glyph and this pill agree.
    private func statusCount(_ title: String, _ count: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            StatusPill(text: title, tint: tint)
            Text("\(count)")
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(title.lowercased())")
    }

    private var impactSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Most impacted", systemImage: "person.2.fill")

            Text("Ranked by people affected, the same way the list is.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: Theme.Space.s) {
                ForEach(mostImpacted) { issue in
                    issueRow(
                        issue,
                        metric: issue.users.compactFormatted,
                        spokenMetric: "\(whole(issue.users)) users affected",
                        footnote: [
                            "\(issue.sessions.compactFormatted) sessions",
                            "\(issue.occurrences.compactFormatted) occurrences",
                        ]
                    )
                }
            }
        }
    }

    /// Only shown when the two rankings disagree.
    ///
    /// The list is ordered by people hurt on purpose, which means a single retry
    /// loop firing 50,000 times can sit well down it. When that is happening it
    /// is worth saying; when the same issue tops both rankings this section
    /// would just be the one above, printed twice.
    @ViewBuilder
    private var noisiestSection: some View {
        if let noisiest {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Noisiest", systemImage: "waveform")

                Text("Most occurrences. Different from the list above, so volume and impact are not the same story here.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: Theme.Space.s) {
                    ForEach(noisiest) { issue in
                        issueRow(
                            issue,
                            metric: issue.occurrences.compactFormatted,
                            spokenMetric: "\(whole(issue.occurrences)) occurrences",
                            footnote: [
                                "\(issue.users.compactFormatted) users",
                                "\(issue.sessions.compactFormatted) sessions",
                            ]
                        )
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func issueRow(
        _ issue: ErrorIssue,
        metric: String,
        spokenMetric: String,
        footnote: [String]
    ) -> some View {
        Button {
            selection = issue
        } label: {
            Card(padding: Theme.Space.m) {
                DataRow(
                    glyph: "ladybug.fill",
                    tint: issue.statusTint,
                    title: issue.name,
                    subtitle: issue.issueDescription,
                    footnote: (footnote + lastSeenPart(issue)).joined(separator: " · "),
                    isSubtitleMonospaced: true,
                    // Four of the six issues in this project are titled "Error".
                    // The message underneath is the only thing separating them,
                    // so it gets the second line rather than being cut at
                    // "An unexpecte…" the way the narrow column cut it.
                    subtitleLineLimit: 2,
                    accessory: .metric(metric)
                )
            }
        }
        .buttonStyle(.plain)
        .pointerHighlight(cornerRadius: Theme.Radius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary(issue, metric: spokenMetric))
    }

    private func spokenSummary(_ issue: ErrorIssue, metric: String) -> String {
        var parts = [issue.name]
        if let description = issue.issueDescription, !description.isEmpty {
            parts.append(description)
        }
        parts.append(metric)
        parts.append(issue.statusTitle)
        // `issueDescription` is server prose and arrives with its own full stop.
        return parts.joinedAsSentences()
    }

    private func lastSeenPart(_ issue: ErrorIssue) -> [String] {
        guard let lastSeen = issue.lastSeen else { return [] }
        return [lastSeen.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))]
    }

    /// Speech gets the whole number: "12.4K" is a reading aid for a narrow
    /// column, not a figure, and VoiceOver has no trouble with the real one.
    private func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    // MARK: - Data

    private var active: [ErrorIssue] { issues.filter(\.isActive) }
    private var resolved: [ErrorIssue] { issues.filter(\.isResolved) }
    private var suppressed: [ErrorIssue] { issues.filter(\.isSuppressed) }

    private var totalOccurrences: Double {
        issues.reduce(0) { $0 + $1.occurrences }
    }

    private var mostImpacted: [ErrorIssue] {
        Array(issues.sorted { $0.users > $1.users }.prefix(5))
    }

    private var byOccurrences: [ErrorIssue] {
        Array(issues.sorted { $0.occurrences > $1.occurrences }.prefix(3))
    }

    private var noisiest: [ErrorIssue]? {
        guard mostImpacted.first?.id != byOccurrences.first?.id else { return nil }
        return byOccurrences
    }

    /// Absent rather than zero when the API gave no `first_seen` at all —
    /// "0 new" and "we cannot tell" are different claims.
    private var newInWindow: Int? {
        guard let start = windowStart, issues.contains(where: { $0.firstSeen != nil }) else {
            return nil
        }
        return issues.filter { ($0.firstSeen ?? .distantPast) >= start }.count
    }

    /// `AnalyticsWindow` states its range as the date literal the query needs,
    /// not as a length, so the cutoff is derived here rather than read off it.
    private var windowStart: Date? {
        let days: Int
        switch window {
        case .day: days = 1
        case .week: days = 7
        case .month: days = 30
        case .quarter: days = 90
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}
