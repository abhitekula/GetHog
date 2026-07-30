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

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<Survey> = try await client.send(
                PostHogAPI.surveys(projectID: projectID)
            )
            surveys = page.results
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    var groups: [(status: String, surveys: [Survey])] {
        let grouped = Dictionary(grouping: surveys, by: \.statusText)
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
                message: "This project doesn't have any surveys yet."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(store.groups, id: \.status) { group in
                Section {
                    ForEach(group.surveys) { survey in
                        Button {
                            selected = survey
                        } label: {
                            SurveyRowView(survey: survey)
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
        await store.load(client: client, projectID: projectID)
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status") {
                        StatusPill(
                            text: survey.statusText,
                            tint: surveyStatusTint(survey.statusText)
                        )
                    }
                    LabeledContent("Type") { Text(surveyTypeLabel(survey.type)) }
                    if let start = survey.startDate {
                        LabeledContent("Launched") {
                            Text(start, format: .dateTime.year().month().day())
                        }
                    }
                    if let end = survey.endDate {
                        LabeledContent("Stopped") {
                            Text(end, format: .dateTime.year().month().day())
                        }
                    }
                }

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
                            SurveyQuestionRowView(index: index, question: question)
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
                        // Being blunt beats implying the app shows results it
                        // has never fetched.
                        Text("GetHog shows a survey's configuration. Responses and their breakdowns are only on the PostHog web console.")
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
        }
    }
}

struct SurveyQuestionRowView: View {
    let index: Int
    let question: SurveyQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(index + 1). \(question.question ?? "Untitled question")")
                .font(.callout)

            if let type = question.type {
                StatusPill(text: questionTypeLabel(type), tint: .secondary)
            }

            if let choices = question.choices, !choices.isEmpty {
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
