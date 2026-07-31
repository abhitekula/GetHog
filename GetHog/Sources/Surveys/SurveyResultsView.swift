import Charts
import GetHogKit
import SwiftUI

/// Loads one survey's results.
///
/// Two HogQL queries over `events`, issued together: there is no survey-results
/// API, and one round trip after another on a phone is a visible wait. The
/// summary is a handful of counters, the answers are one row per outcome event —
/// they are separate queries because the second is capped and the first must not
/// be.
@MainActor
@Observable
final class SurveyResultsStore {
    var state: SurveyResultsState?
    var failure: LoadFailure?
    var isLoading = false
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int, survey: Survey) async {
        // A survey that never launched cannot have events. Asking anyway would
        // spend two queries to be told what the survey record already says, and
        // would show a spinner where a plain sentence belongs.
        guard survey.startDate != nil else {
            state = .notLaunched
            failure = nil
            loadedAt = Date()
            return
        }

        isLoading = true
        defer { isLoading = false }

        async let summary: QueryResponse = client.send(
            PostHogAPI.surveyResultsSummary(projectID: projectID, survey: survey)
        )
        async let answers: QueryResponse = client.send(
            PostHogAPI.surveyResponses(projectID: projectID, survey: survey)
        )

        do {
            state = SurveyResults.state(
                survey: survey,
                summary: try await summary,
                answers: try await answers
            )
            failure = nil
            loadedAt = Date()
        } catch {
            failure = LoadFailure(error, loading: "survey results")
        }
    }
}

// MARK: - Summary

/// The funnel, and the sentence that says what it is a funnel of.
struct SurveyResultsSummaryView: View {
    let survey: Survey
    let state: SurveyResultsState

    var body: some View {
        switch state {
        case .notLaunched:
            // Not an empty state. There is no data because the survey has never
            // run, which is a fact about the survey, not about the query.
            SectionEmptyState(
                text: "Not launched. This survey has never been shown, so there are no results to read yet.",
                systemImage: "pause.circle"
            )

        case .noActivity(let summary):
            SectionEmptyState(
                text: survey.statusText == "Stopped"
                    ? "Ran and recorded nothing. No impressions, responses or dismissals were captured for this survey."
                    : "Launched, but nothing has come in yet. No impressions have been recorded for this survey.",
                systemImage: "tray"
            )
            .accessibilityHint(Text(freshness(summary)))

        case .shownButUnanswered(let summary):
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                stats(summary)
                // Distinct from "no data": people saw this and chose not to
                // answer, which is itself the finding.
                Text("Shown \(summary.impressions.formatted()) time\(summary.impressions == 1 ? "" : "s") and answered by nobody.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .measured(let results):
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                stats(results.summary)
                conversion(results.summary)
                coverage(results.coverage)
            }
        }
    }

    /// The funnel, three or four figures wide.
    ///
    /// Laid out rather than scrolled. `StatStrip` is the app's usual answer, but
    /// it is a horizontal `ScrollView`, and a horizontal scroll view nested in a
    /// `List` row inside a sheet has no width to resolve against — rendered, it
    /// took its full height and drew nothing at all. Four short integers fit a
    /// phone without scrolling anyway; past the accessibility threshold they
    /// stack instead of being squeezed into two characters each.
    @ViewBuilder
    private func stats(_ summary: SurveyResultsSummary) -> some View {
        let tiles: [(String, Int)] = {
            var items = [
                ("Impressions", summary.impressions),
                ("Responses", summary.responses),
                ("Dismissed", summary.dismissals),
            ]
            // Only when it happened. A permanent "0 abandoned" column on every
            // survey teaches readers to ignore the row it lives in.
            if summary.abandonments > 0 {
                items.append(("Abandoned", summary.abandonments))
            }
            return items
        }()

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                ForEach(tiles, id: \.0) { label, value in
                    MetricTile(label: label, value: value.formatted(), compact: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(tiles, id: \.0) { label, value in
                    MetricTile(label: label, value: value.formatted(), compact: true)
                }
            }
        }
    }

    @ViewBuilder
    private func conversion(_ summary: SurveyResultsSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let rate = summary.responseRate, let dismissal = summary.dismissalRate {
                Text("\(rate.formatted(.percent.precision(.fractionLength(0...1)))) of impressions were answered; \(dismissal.formatted(.percent.precision(.fractionLength(0...1)))) were dismissed.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The number below every breakdown on this screen, said once here.
            // Without it a reader comparing "1 response" against a rating chart
            // built from four answers has no way to tell which is wrong.
            if summary.partials > 0 {
                Text("\(summary.partials.formatted()) further dismissal\(summary.partials == 1 ? "" : "s") carried partial answers. Those answers are included in the breakdowns below, so a question can show more answers than there are responses.")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the per-question breakdowns below actually cover.
    ///
    /// The one place on this sheet where the two figures a reader is most likely
    /// to conflate sit together: the funnel directly above comes from a query
    /// with **no** `LIMIT`, so its response and dismissal counts are the whole
    /// survey's, while every mean, share and score below comes from at most 500
    /// answer events. `SurveyAnswerCoverage` was computed from the moment this
    /// screen shipped and rendered nowhere, which put a correct total and a
    /// capped statistic side by side with nothing distinguishing them.
    ///
    /// A sentence rather than a badge, and no tint: this is not a failure, it is
    /// the scope of a figure, and the same `Label`-plus-caption treatment
    /// `WebAnalyticsRoot.truncationNote` and `SchemaBrowser` already use. The
    /// glyph carries no state — the words do — so nothing here is conveyed by
    /// colour, and `fixedSize` lets it wrap to as many lines as AX5 needs
    /// instead of truncating a caveat down to half a caveat.
    @ViewBuilder
    private func coverage(_ coverage: SurveyAnswerCoverage) -> some View {
        if let note = coverage.note {
            Label(note, systemImage: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func freshness(_ summary: SurveyResultsSummary) -> String {
        guard let last = summary.lastSeen else { return "" }
        return "Last event \(last.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Question results

struct SurveyQuestionResultsView: View {
    let results: SurveyQuestionResults
    /// What the answers behind this breakdown span, when that is less than the
    /// survey. `nil` while results are loading, and on the placeholder.
    var coverage: SurveyAnswerCoverage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            answeredLabel

            switch results.breakdown {
            case .rating(let breakdown):
                SurveyRatingBreakdownView(
                    title: results.title,
                    question: results.question,
                    breakdown: breakdown
                )
            case .choice(let breakdown):
                SurveyChoiceBreakdownView(title: results.title, breakdown: breakdown)
            case .text(let answers):
                SurveyTextAnswersView(title: results.title, answers: answers)
            case .notAggregatable(let reason):
                // Says which of the three empty-ish things this is: the type
                // can't be totalled, which is not "nobody answered".
                Label(reason, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var answeredLabel: some View {
        if case .notAggregatable = results.breakdown {
            EmptyView()
        } else if results.answered == 0 {
            Text(results.question.isOptional
                 ? "No answers. This question was optional."
                 : "No answers yet.")
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
        } else if let scope = coverage?.shortNote {
            // The count qualified where it is read, not only in the summary at
            // the top of the sheet. A reader scrolling to question four meets
            // "Mean 2.75" long after any header has gone, and the mean is the
            // figure this project has already had wrong once — the whole reason
            // `SurveyRatingBreakdownView` prints the scale's provenance under
            // every chart. The provenance of the *sample* belongs there for the
            // same reason. The full sentence, with the survey's real size in it,
            // stays in one place above; this is the fragment that says which
            // number the answer count is.
            Text("\(results.answered.formatted()) answer\(results.answered == 1 ? "" : "s"), \(scope)")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(results.answered.formatted()) answer\(results.answered == 1 ? "" : "s")")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Ink.secondary)
        }
    }
}

// MARK: - Rating

struct SurveyRatingBreakdownView: View {
    let title: String
    let question: SurveyQuestion
    let breakdown: SurveyRatingBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if breakdown.answered > 0 {
                header
                SurveyDistributionChart(
                    title: title,
                    axisTitle: "Rating",
                    bars: breakdown.buckets.map {
                        SurveyDistributionBar(
                            label: String($0.value),
                            count: $0.count,
                            share: $0.share
                        )
                    },
                    valueAxisIsNumeric: true
                )
                bounds
                // The scale's own provenance, always. A rating chart with no
                // statement of where its axis came from is the one place on this
                // screen a wrong number could hide in plain sight.
                // Sentence case, not `localizedCapitalized` — that rendered
                // "1–5 Scale, From The Survey's Question Definition."
                Text(breakdown.scale.provenance.sentenceCased + ".")
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                netPromoter
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("Mean \(breakdown.mean.formatted(.number.precision(.fractionLength(0...2))))")
                .font(.caption.weight(.semibold).monospacedDigit())
            if breakdown.outOfRange > 0 {
                StatusPill(
                    text: "\(breakdown.outOfRange) off scale",
                    tint: Theme.Status.warningInk
                )
            }
        }
    }

    @ViewBuilder
    private var bounds: some View {
        if let low = question.lowerBoundLabel, let high = question.upperBoundLabel {
            HStack {
                Text("\(breakdown.scale.lowerBound) = \(low)")
                Spacer(minLength: Theme.Space.s)
                Text("\(breakdown.scale.upperBound) = \(high)")
            }
            .font(.caption2)
            .foregroundStyle(Theme.Ink.tertiary)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var netPromoter: some View {
        if let nps = breakdown.netPromoter {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text("NPS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Ink.secondary)
                    Text(nps.score.formatted(.number.sign(strategy: .always(includingZero: false))))
                        .font(Theme.Typography.metricSmall)
                }
                Text("\(nps.promoters.formatted()) promoters · \(nps.passives.formatted()) passives · \(nps.detractors.formatted()) detractors")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Ink.secondary)
                // The bucketing travels with the score. A bare NPS number whose
                // bands a reader cannot check is the failure mode this whole
                // screen was built to avoid.
                Text(nps.basis)
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Net promoter score \(nps.score). \(nps.promoters) promoters, \(nps.passives) passives, \(nps.detractors) detractors. \(nps.basis)")
        } else if let absence = breakdown.netPromoterAbsence {
            // Named absence, not silence. A survey called "NPS" that shows no
            // score has to say why, or the reader assumes the app is broken.
            Text(absence)
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Choice

struct SurveyChoiceBreakdownView: View {
    let title: String
    let breakdown: SurveyChoiceBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if breakdown.answered > 0 {
                SurveyDistributionChart(
                    title: title,
                    axisTitle: "Choice",
                    bars: breakdown.counts.map {
                        SurveyDistributionBar(
                            label: $0.label,
                            count: $0.count,
                            share: $0.share
                        )
                    },
                    valueAxisIsNumeric: false
                )
                if breakdown.allowsMultiple {
                    // Otherwise the percentages look broken when they sum past
                    // 100, which for a multi-select is correct arithmetic.
                    Text("People could pick more than one, so these shares are of respondents and add up to more than 100%.")
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Free text

struct SurveyTextAnswersView: View {
    let title: String
    let answers: [SurveyTextAnswer]

    /// Enough to read the shape of the feedback without turning a survey sheet
    /// into a scroll to nowhere.
    ///
    /// Not `private`: this is also the number that decides whether the "All N
    /// answers" screen exists, and `AnswerSummaryBrief.minimumAnswers` is pinned
    /// against it so the on-device summary and the screen that hosts it can
    /// never appear one without the other.
    static let inlineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(answers.prefix(Self.inlineLimit)) { answer in
                SurveyTextAnswerRow(answer: answer)
            }
            if answers.count > Self.inlineLimit {
                NavigationLink {
                    SurveyTextAnswersList(title: title, answers: answers)
                } label: {
                    Label(
                        "All \(answers.count.formatted()) answers",
                        systemImage: "text.alignleft"
                    )
                    .font(.caption)
                }
                .frame(minHeight: 44)
            }
        }
    }
}

struct SurveyTextAnswerRow: View {
    let answer: SurveyTextAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(answer.text)
                .font(.callout)
                // Free text is the content, so it wraps in full: a truncated
                // complaint is a complaint you have to leave the app to read.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: Theme.Space.xs) {
                if let date = answer.date {
                    Text(date, format: .dateTime.year().month(.abbreviated).day())
                }
                if answer.isPartial {
                    // Word plus glyph, never a colour on its own: this answer
                    // came in on a dismissal and the person never finished.
                    Label("Partial", systemImage: "clock.badge.exclamationmark")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.Ink.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct SurveyTextAnswersList: View {
    let title: String
    let answers: [SurveyTextAnswer]

    var body: some View {
        List {
            // The one screen in this feature that exists *because* there are too
            // many answers to read is the one that gets the précis. Offered only
            // past `AnswerSummaryBrief.minimumAnswers`, which is the same
            // threshold that makes this screen reachable at all — so the summary
            // and the screen appear together rather than one arriving alone.
            //
            // Above the answers rather than below them, because it is a way in
            // to a long list. It is a `Card` on a clear row, so it reads as a
            // block laid over the list rather than as its first entry: the rows
            // below are what people wrote, and this is not one of them. The
            // insets are zeroed so the card spans the same rect the answer rows'
            // own `listRowBackground` fills, rather than sitting indented inside
            // it.
            //
            // **Not seen on screen.** `OnDeviceSummaryCard` was rendered on its
            // own and reviewed at default size, dark, and AX5; *this* row was
            // not, in either available way. `ImageRenderer` refuses to draw a
            // `List` at all — it produced the yellow "unsupported" placeholder —
            // and demo mode cannot reach this screen, because `DemoTransport`
            // routes the two survey-results queries to the generic `HogQLQuery`
            // recording, which carries no `impressions` column and lands the
            // sheet on `.noActivity` before any answers exist to open. A demo
            // route for `surveyResultsSummary` / `surveyResponses` would make
            // this reviewable and screenshot-able; that file is outside this
            // change.
            if AnswerSummaryBrief.isWorthwhile(answers) {
                Section {
                    OnDeviceSummaryCard(
                        heading: "What people wrote",
                        actionTitle: "Summarise these answers",
                        brief: AnswerSummaryBrief.make(question: title, answers: answers)
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                ForEach(answers) { answer in
                    SurveyTextAnswerRow(answer: answer)
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(text: title, systemImage: "text.alignleft")
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .navigationTitle("Answers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Distribution chart

struct SurveyDistributionBar: Hashable {
    let label: String
    let count: Int
    let share: Double
}

/// A horizontal distribution, drawn the way this app already draws a breakdown.
///
/// Rows rather than a `Chart` for the same reason `BarValueRow` exists: on a
/// phone at accessibility sizes a bar chart's category axis collapses to
/// unreadable stubs, where a labelled row reflows. The `AXChartDescriptor` is
/// still published, so VoiceOver's audio graph reads the distribution.
struct SurveyDistributionChart: View {
    let title: String
    let axisTitle: String
    let bars: [SurveyDistributionBar]
    /// True when the labels are scale points, which sort and read as numbers.
    let valueAxisIsNumeric: Bool

    private var maxCount: Int { bars.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(bars, id: \.label) { bar in
                SurveyDistributionRow(bar: bar, maxCount: maxCount)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityChartDescriptor(
            SurveyDistributionDescriptor(
                title: title,
                axisTitle: axisTitle,
                bars: bars,
                isNumericAxis: valueAxisIsNumeric
            )
        )
    }
}

struct SurveyDistributionRow: View {
    let bar: SurveyDistributionBar
    let maxCount: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 6

    private var fraction: Double {
        maxCount > 0 ? Double(bar.count) / Double(maxCount) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Past the accessibility threshold a label and its figure sharing a
            // row leave the figure a couple of characters wide — the same reflow
            // `BarValueRow` makes, for the same measured reason.
            if dynamicTypeSize.isAccessibilitySize {
                label
                value
            } else {
                HStack(alignment: .firstTextBaseline) {
                    label
                    Spacer(minLength: Theme.Space.s)
                    value
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if bar.count > 0 {
                        Capsule()
                            .fill(SeriesPalette.color(at: 0))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: barHeight)
            .clipShape(.capsule)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.label)
        .accessibilityValue("\(bar.count.formatted()), \(bar.share.formatted(.percent.precision(.fractionLength(0...1))))")
    }

    private var label: some View {
        Text(bar.label)
            .font(.caption)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    private var value: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(bar.count.formatted())
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(bar.share.formatted(.percent.precision(.fractionLength(0...1))))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }
}

extension String {
    /// First character upper-cased, the rest left alone.
    var sentenceCased: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

struct SurveyDistributionDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let axisTitle: String
    let bars: [SurveyDistributionBar]
    let isNumericAxis: Bool

    func makeChartDescriptor() -> AXChartDescriptor {
        let counts = bars.map { Double($0.count) }
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: axisTitle,
            categoryOrder: bars.map(\.label)
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Answers",
            range: 0...(max(counts.max() ?? 1, 1)),
            gridlinePositions: []
        ) { $0.formatted(.number.precision(.fractionLength(0))) }

        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: false,
            dataPoints: bars.map { AXDataPoint(x: $0.label, y: Double($0.count)) }
        )

        let total = bars.map(\.count).reduce(0, +)
        let top = bars.max { $0.count < $1.count }
        var summary = "\(total.formatted()) answer\(total == 1 ? "" : "s") across \(bars.count) \(isNumericAxis ? "scale points" : "options")."
        if let top, top.count > 0 {
            summary += " Most common: \(top.label), \(top.count.formatted())."
        }

        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
