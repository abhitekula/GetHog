import GetHogKit
import SwiftUI

@MainActor
@Observable
final class SurveysStore {
    var surveys: [Survey] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// Lifecycle order, not alphabetical: what is live matters most, what is
    /// archived matters least.
    private static let statusOrder = ["Running", "Draft", "Stopped", "Archived"]

    func load(
        client: PostHogClient,
        projectID: Int,
        lifecycle: SurveyLifecycleController? = nil
    ) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<Survey> = try await client.send(
                PostHogAPI.surveys(projectID: projectID)
            )
            surveys = page.results
            // A fresh fetch wins over anything this app wrote. Done here rather
            // than in the view so a refresh cannot land without it — a local
            // override that outlives its write quietly misreports which surveys
            // are running.
            lifecycle?.reconcile(with: page.results)
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Grouped by the status the *screen* shows, which includes this app's own
    /// in-flight writes — otherwise a survey stopped from its sheet stays filed
    /// under "Running" until the next fetch, one row away from a sheet saying
    /// "Stopped".
    func groups(
        lifecycle: SurveyLifecycleController? = nil
    ) -> [(status: String, surveys: [Survey])] {
        let grouped = Dictionary(grouping: surveys) {
            lifecycle?.effectiveStatusText($0) ?? $0.statusText
        }
        var result: [(status: String, surveys: [Survey])] = Self.statusOrder.compactMap { status in
            guard let items = grouped[status], !items.isEmpty else { return nil }
            let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return (status: status, surveys: sorted)
        }
        // Anything PostHog starts reporting that we don't know about still shows
        // up rather than silently disappearing from the list.
        for status in grouped.keys.sorted() where !Self.statusOrder.contains(status) {
            result.append((status, grouped[status] ?? []))
        }
        return result
    }
}

struct SurveysRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @Environment(SurveyLifecycleController.self) private var lifecycle
    @State private var store = SurveysStore()

    /// The open survey, and deliberately neither `@State` nor a `.sheet` of this
    /// screen's own.
    ///
    /// A sheet rather than a second column: response analysis lives on the web,
    /// so there is nothing to keep persistently open beside the list. But this
    /// screen is one of `AppTab.secondary`, reached through the search tab, so
    /// it is hosted by a sidebar `Tab` above the size-class boundary and by the
    /// search stack below it — and crossing the boundary rebuilds it in the
    /// other host.
    /// Measured with "30-Day NPS" open, dragging the window 834 → 375 → 834pt:
    /// `navigationBars` went `["30-Day NPS", "Surveys"]` → `["Surveys"]` →
    /// `["Surveys"]`. The sheet was dismissed by the resize and never came back.
    ///
    /// So this screen writes the survey and stops. `RootView` presents it, from
    /// above the boundary — see `RootView.presentedDetail` for why a sheet in
    /// *this* view cannot be made to survive, whichever state drives it.
    private var selected: Survey? {
        get { openDetails[.surveys] as? Survey }
        nonmutating set { openDetails[.surveys] = newValue.map(AnyHashable.init) }
    }

    var body: some View {
        content
            .navigationTitle("Surveys")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.surveys.isEmpty {
            EmptyStateView(
                title: "Couldn't load surveys",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again"
            ) {
                Task { await load() }
            }
        } else if store.surveys.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No surveys",
                systemImage: "text.bubble",
                illustration: .experiment,
                message: "This project doesn't have any surveys yet."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(store.groups(lifecycle: lifecycle), id: \.status) { group in
                Section {
                    ForEach(group.surveys) { survey in
                        Button {
                            selected = survey
                        } label: {
                            SurveyRowView(survey: lifecycle.effective(survey))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the survey's questions")
                        .listRowBackground(
                            Theme.cardBackground
                                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                                .padding(.vertical, 1)
                        )
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    SectionLabel(text: group.status, systemImage: surveyStatusSymbol(group.status))
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.surveys.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, lifecycle: lifecycle)
    }
}

struct SurveyRowView: View {
    let survey: Survey

    var body: some View {
        DataRow(
            glyph: surveySymbol(survey.type),
            tint: surveyStatusTint(survey.statusText),
            title: survey.name,
            // The type still travels as a word: the glyph reinforces it, but a
            // reader should never have to decode an icon to learn how a survey
            // reaches people.
            //
            // The space before the separator is non-breaking because at
            // accessibility sizes this wrapped between the type and the dot,
            // leaving a `·` hanging alone at the end of a line pointing at
            // nothing. A separator belongs to the thing it follows.
            subtitle: "\(surveyTypeLabel(survey.type))\u{00A0}· \(questionCount)",
            footnote: surveyRangeText(start: survey.startDate, end: survey.endDate),
            accessory: .pill(survey.statusText, surveyStatusTint(survey.statusText))
        )
    }

    private var questionCount: String {
        survey.questions.count == 1 ? "1 question" : "\(survey.questions.count) questions"
    }
}

// MARK: - Detail

struct SurveyDetailSheet: View {
    let survey: Survey
    let webURL: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    /// Owned by `RootView` and injected, not `@State` here, for the reason
    /// `OpenDetails` is: this sheet is presented from above the size-class
    /// boundary, and the list underneath needs to show the same status word this
    /// screen just wrote.
    @Environment(SurveyLifecycleController.self) private var lifecycle
    @State private var results = SurveyResultsStore()

    @State private var isConfirmingStop = false
    @State private var isConfirmingLaunch = false
    @State private var isConfirmingResume = false

    /// The survey with our own in-flight writes laid over it. Every derived
    /// reading on this screen comes from here, so the pill, the section it groups
    /// under and the two date rows cannot disagree.
    private var live: Survey { lifecycle.effective(survey) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    resultsSummary
                } header: {
                    SectionLabel(text: "Results", systemImage: "chart.bar")
                } footer: {
                    if let loadedAt = results.loadedAt, results.state != nil {
                        FreshnessLabel(date: loadedAt)
                    }
                }

                Section {
                    LabeledContent("Status") {
                        StatusPill(
                            text: live.statusText,
                            tint: surveyStatusTint(live.statusText)
                        )
                    }
                    LabeledContent("Type") { Text(surveyTypeLabel(survey.type)) }
                    if let start = live.startDate {
                        LabeledContent("Launched") {
                            Text(start, format: .dateTime.year().month().day())
                        }
                    }
                    if let end = live.endDate {
                        LabeledContent("Stopped") {
                            Text(end, format: .dateTime.year().month().day())
                        }
                    }
                } footer: {
                    // The status word is the client's, and saying so is not
                    // pedantry: a survey carries no `status` field at all — 37
                    // keys and none of them is one — so "Running" here is derived
                    // from the two dates above it and the archived flag. Somebody
                    // comparing this screen with PostHog's own is comparing two
                    // derivations, not a value and a copy of it.
                    Text("PostHog doesn't store a status for a survey. This one is worked out from the dates above.")
                }

                lifecycleSection

                if let description = survey.description, !description.isEmpty {
                    Section {
                        Text(description).font(.callout)
                    } header: {
                        SectionLabel(text: "Description", systemImage: "text.alignleft")
                    }
                }

                Section {
                    if survey.questions.isEmpty {
                        Text("This survey has no questions defined.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(survey.questions.enumerated()), id: \.offset) { index, question in
                            SurveyQuestionRowView(
                                index: index,
                                question: question,
                                results: questionResults(at: index),
                                coverage: answerCoverage
                            )
                        }
                    }
                } header: {
                    SectionLabel(
                        text: "Questions (\(survey.questions.count))",
                        systemImage: "list.number"
                    )
                }

                if let webURL {
                    Section {
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    } footer: {
                        // Still says where the rest lives. What this screen now
                        // shows is the funnel and the per-question breakdown;
                        // targeting, branching and per-person responses remain
                        // on the web.
                        Text("GetHog reads a survey's results from its response events. Targeting, branching and individual respondents are on the PostHog web console.")
                    }
                }
            }
            .pageSurface()
            .navigationTitle(survey.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: survey.id) { await loadResults() }
            .refreshable { await loadResults() }
            .confirmationDialog(
                "Stop \(survey.name)?",
                isPresented: $isConfirmingStop,
                titleVisibility: .visible
            ) {
                Button("Stop collecting responses", role: .destructive) { commit(.stop) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    """
                    People stop seeing this survey\(projectSuffix) straight away. Every response \
                    already collected is kept, and you can resume it later.
                    """
                )
            }
            .confirmationDialog(
                "Launch \(survey.name)?",
                isPresented: $isConfirmingLaunch,
                titleVisibility: .visible
            ) {
                Button("Launch to live users", role: .destructive) { commit(.launch) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    """
                    This starts showing the survey to real people\(projectSuffix) straight away, to \
                    everyone its targeting matches. You can stop it again at any time.
                    """
                )
            }
            .confirmationDialog(
                "Resume \(survey.name)?",
                isPresented: $isConfirmingResume,
                titleVisibility: .visible
            ) {
                Button("Resume for live users", role: .destructive) { commit(.resume) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    """
                    This clears the survey's end date, so people start seeing it again\
                    \(projectSuffix). Responses from the earlier run are kept and counted with the \
                    new ones.
                    """
                )
            }
            .sensoryFeedback(.success, trigger: lifecycle.successCount)
            .sensoryFeedback(.error, trigger: lifecycle.failureCount)
            .sensoryFeedback(.warning, trigger: lifecycle.filedCount)
        }
    }

    // MARK: - Lifecycle

    private enum LifecycleAction { case stop, launch, resume }

    private var projectSuffix: String {
        model.selectedProject.map { " in \($0.name)" } ?? ""
    }

    /// Stop / launch / resume.
    ///
    /// Buttons on the detail sheet and never a swipe on the list, for the reason
    /// every other write in this app follows: reaching something that changes what
    /// real people are shown should cost a deliberate tap into the thing being
    /// changed.
    ///
    /// The three are mutually exclusive by construction — a survey is either a
    /// draft, running, or stopped — so at most one appears, and `Archived` shows
    /// none. That is not a simplification: `stop/` and `launch/` both 400 on an
    /// archived survey.
    @ViewBuilder
    private var lifecycleSection: some View {
        if lifecycle.canStop(survey) || lifecycle.canLaunch(survey) || lifecycle.canResume(survey) {
            Section {
                if lifecycle.canStop(survey) {
                    lifecycleButton("Stop survey", systemImage: "stop.circle", tint: Theme.accentWarm) {
                        isConfirmingStop = true
                    }
                }
                if lifecycle.canLaunch(survey) {
                    lifecycleButton("Launch survey", systemImage: "play.circle", tint: Theme.accent) {
                        isConfirmingLaunch = true
                    }
                }
                if lifecycle.canResume(survey) {
                    lifecycleButton("Resume survey", systemImage: "play.circle", tint: Theme.accent) {
                        isConfirmingResume = true
                    }
                }

                if let message = lifecycle.message {
                    WriteOutcomeMessageView(message: message) { lifecycle.dismissMessage() }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Lifecycle", systemImage: "slider.horizontal.3")
                    Spacer(minLength: 8)
                    if lifecycle.isBusy(survey) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving change")
                    }
                }
            } footer: {
                Text("Changes here are written to PostHog straight away and are visible to your whole team. You'll be asked to confirm first.")
            }
        }
    }

    private func lifecycleButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .disabled(lifecycle.isBusy(survey))
    }

    private func commit(_ action: LifecycleAction) {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            switch action {
            case .stop: await lifecycle.stop(survey, client: client, projectID: projectID)
            case .launch: await lifecycle.launch(survey, client: client, projectID: projectID)
            case .resume: await lifecycle.resume(survey, client: client, projectID: projectID)
            }
        }
    }

    @ViewBuilder
    private var resultsSummary: some View {
        if let failure = results.failure {
            SectionEmptyState(
                text: failure.summary,
                systemImage: "exclamationmark.triangle",
                detail: failure.detail,
                actionTitle: "Try again"
            ) {
                Task { await loadResults() }
            }
        } else if let state = results.state {
            SurveyResultsSummaryView(survey: survey, state: state)
        } else {
            // Placeholder of the right shape, so the sheet does not jump when
            // the counts arrive.
            SurveyResultsSummaryView(
                survey: survey,
                state: .measured(
                    SurveyResults(
                        summary: SurveyResultsSummary(
                            impressions: 0, responses: 0, partials: 0,
                            dismissals: 0, abandonments: 0
                        ),
                        questions: [],
                        submissions: [],
                        // An empty read of nothing: no rows, no ceiling reached,
                        // so the placeholder draws the funnel's shape and no
                        // coverage line. A skeleton that redacted a truncation
                        // notice would flash a caveat about data that has not
                        // arrived and then withdraw it.
                        coverage: SurveyAnswerCoverage(
                            rowsReturned: 0,
                            rowCap: SurveyResultsQuery.responseLimit,
                            envelopeHasMore: false,
                            submissionsRead: 0,
                            submissionsReported: 0
                        )
                    )
                )
            )
            .skeleton(true)
        }
    }

    /// The measured results for one question, or `nil` while they are still
    /// loading or when there are none to show.
    private func questionResults(at index: Int) -> SurveyQuestionResults? {
        guard case .measured(let results)? = results.state else { return nil }
        return results.questions.first { $0.index == index }
    }

    /// What every breakdown on this sheet was computed over, or `nil` when there
    /// is no measured reading to qualify.
    private var answerCoverage: SurveyAnswerCoverage? {
        guard case .measured(let results)? = results.state else { return nil }
        return results.coverage
    }

    private func loadResults() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await results.load(client: client, projectID: projectID, survey: survey)
    }
}

struct SurveyQuestionRowView: View {
    let index: Int
    let question: SurveyQuestion
    /// `nil` while results are loading, or when this survey has none — in which
    /// case the row falls back to the configuration it always showed.
    var results: SurveyQuestionResults?
    /// Travels with `results` and is `nil` in exactly the same cases.
    var coverage: SurveyAnswerCoverage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(index + 1). \(question.question ?? "Untitled question")")
                .font(.callout)

            if let type = question.type {
                StatusPill(text: questionTypeLabel(type), tint: .secondary)
            }

            if let results {
                SurveyQuestionResultsView(results: results, coverage: coverage)
                    .padding(.top, Theme.Space.xs)
            } else if let choices = question.choices, !choices.isEmpty {
                // The declared options, when there are no answers to show them
                // against. Once there are, the breakdown lists every option
                // including the ones nobody picked, so printing them twice would
                // only make the row longer.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(choices, id: \.self) { choice in
                        Text(choice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Choices: \(choices.joined(separator: ", "))")
            }
        }
        .padding(.vertical, 2)
    }

    private func questionTypeLabel(_ type: String) -> String {
        switch type {
        case "open": "Open text"
        case "single_choice": "Single choice"
        case "multiple_choice": "Multiple choice"
        case "rating": "Rating"
        case "link": "Link"
        default: type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Formatting
//
// File-private so concurrent work on other screens can't collide with these
// names; they are three lines each and not worth a shared surface.

/// The glyph says how a survey reaches people, which is what makes one survey a
/// different kind of thing from another. The type label travels beside it in
/// words — the icon is reinforcement, never the only carrier.
private func surveySymbol(_ type: String) -> String {
    switch type {
    case "popover": "bubble.left.fill"
    case "widget": "square.on.square"
    case "api": "curlybraces"
    case "external_survey": "arrow.up.forward.app"
    default: "text.bubble.fill"
    }
}

/// Chrome tint for a lifecycle status. The status word always travels with it —
/// in the pill and in the section header — so the colour never carries the
/// state on its own.
private func surveyStatusTint(_ status: String) -> Color {
    switch status {
    case "Running": Theme.Status.good
    case "Draft": Theme.accentWarm
    default: Color.secondary
    }
}

private func surveyStatusSymbol(_ status: String) -> String {
    switch status {
    case "Running": "play.circle"
    case "Draft": "pencil"
    case "Stopped": "stop.circle"
    case "Archived": "archivebox"
    // Anything PostHog starts reporting that we don't know about still gets a
    // header rather than a gap.
    default: "circle"
    }
}

private func surveyTypeLabel(_ type: String) -> String {
    switch type {
    case "popover": "Popover"
    case "widget": "Widget"
    case "api": "API"
    case "external_survey": "External"
    default: type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func surveyRangeText(start: Date?, end: Date?) -> String {
    let format = Date.FormatStyle.dateTime.year().month(.abbreviated).day()
    switch (start, end) {
    case (nil, _):
        return "Never launched"
    case (let start?, nil):
        return "Since \(start.formatted(format))"
    case (let start?, let end?):
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }
}
