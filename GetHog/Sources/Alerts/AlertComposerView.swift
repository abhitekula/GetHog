import GetHogKit
import SwiftUI

/// Setting one PostHog alert on one insight.
///
/// A form rather than a wizard: everything on it fits on a phone at once, and the
/// only field that needs a decision the reader might not have is the threshold.
///
/// The two things it works hard at:
///
/// * **Saying who gets told, before the write, in the confirmation dialog.** An
///   alert is a promise to interrupt somebody, and this app's rule for a mutating
///   call is that the dialog names the object and the direction. Here the object
///   includes a person.
/// * **Never offering a control whose value it cannot fill in honestly.** The
///   cadence list omits PostHog's two plan-gated intervals; the series picker
///   appears only when the insight has more than one series to pick from; SQL and
///   metrics insights are refused with a reason rather than shown a disabled Save.
struct AlertComposerView: View {
    let insight: Insight
    /// Returns whether the alert now exists. The sheet stays open on `false` so
    /// the threshold the user typed is still there to retry with.
    let onSave: (AlertDraft) async -> Bool

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var direction: Direction = .below
    @State private var amount: Double = 0
    @State private var thresholdKind: AlertThreshold.Kind = .absolute
    @State private var condition: AlertCondition = .absoluteValue
    @State private var interval: AlertCalculationInterval = .daily
    @State private var seriesIndex: Int = 0
    @State private var funnelMetric: AlertConfig.FunnelMetric = .fromStart
    @State private var isConfirming = false
    @State private var isSaving = false

    /// Which bound the number fills in.
    ///
    /// `AlertThreshold` takes `lower` and `upper` independently and PostHog
    /// accepts both at once — "outside 100–500". That third case is not offered:
    /// it needs two number fields whose validity depends on each other, and a
    /// phone form that can produce `lower > upper` has to explain a rejection
    /// nobody expected. Two buttons and one field cannot.
    private enum Direction: String, CaseIterable, Identifiable {
        case below
        case above

        var id: String { rawValue }

        var title: String {
            switch self {
            case .below: "Drops below"
            case .above: "Rises above"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let reason = AlertableInsight.unavailableReason(sourceKind: insight.sourceKind) {
                    EmptyStateView(
                        title: "Can't set this one from here",
                        systemImage: "bell.slash",
                        message: reason
                    )
                } else {
                    form
                }
            }
            .navigationTitle("New alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set alert") { isConfirming = true }
                        .disabled(draft?.isSendable != true || isSaving)
                }
            }
            // Confirmation naming the object and the direction, exactly as
            // `setFlagActive` does. It is not ceremony here: the sentence is the
            // only place the reader is told the alert e-mails a person and sends
            // nothing to this phone.
            .confirmationDialog(
                "Set this alert?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Set alert") { save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(draft?.confirmation(insightTitle: insight.title) ?? "")
            }
            .onAppear(perform: seedIfNeeded)
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
            } header: {
                SectionLabel(text: "Name", systemImage: "tag")
            } footer: {
                Text("PostHog puts this in the subject line of the e-mail it sends, so it is worth naming what went wrong rather than what is being watched.")
            }

            Section {
                Picker("When the value", selection: $direction) {
                    ForEach(Direction.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent(thresholdKind == .percentage ? "Percent" : "Value") {
                    TextField("Value", value: $amount, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }

                Picker("Measured as", selection: $thresholdKind) {
                    ForEach(AlertThreshold.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                Picker("Compared against", selection: $condition) {
                    ForEach(AlertCondition.allCases) { condition in
                        Text(condition.title).tag(condition)
                    }
                }
            } header: {
                SectionLabel(text: "Threshold", systemImage: "slider.horizontal.3")
            } footer: {
                Text(thresholdFooter)
            }

            if let seriesLabels, seriesLabels.count > 1 {
                Section {
                    Picker("Series", selection: $seriesIndex) {
                        ForEach(Array(seriesLabels.enumerated()), id: \.offset) { index, label in
                            Text(label).tag(index)
                        }
                    }
                } header: {
                    SectionLabel(text: "Which line", systemImage: "chart.xyaxis.line")
                } footer: {
                    Text("An alert watches one series. This insight draws \(seriesLabels.count).")
                }
            }

            if insight.sourceKind == "FunnelsQuery" {
                Section {
                    Picker("Conversion", selection: $funnelMetric) {
                        ForEach(AlertConfig.FunnelMetric.allCases) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                } header: {
                    SectionLabel(text: "Which conversion", systemImage: "arrow.down.right")
                } footer: {
                    Text("The overall last step is what's watched. PostHog can also watch one step in the middle — set that one up in PostHog.")
                }
            }

            Section {
                Picker("Checked", selection: $interval) {
                    ForEach(AlertCalculationInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
            } header: {
                SectionLabel(text: "How often", systemImage: "clock")
            } footer: {
                Text("PostHog also offers real time and every 15 minutes on its paid plans. GetHog can't see which plan this organization is on, so it doesn't offer a cadence that might be refused.")
            }

            Section {
                LabeledContent("E-mails", value: recipientName)
            } header: {
                SectionLabel(text: "Who gets told", systemImage: "envelope")
            } footer: {
                Text(recipientFooter)
            }
        }
        .pageSurface()
    }

    // MARK: - Words

    private var thresholdFooter: String {
        guard let threshold else {
            return "Enter a number. PostHog needs at least one bound — an alert with none is one it can never evaluate."
        }
        let measured = thresholdKind == .percentage
            ? "a percentage change from the previous interval"
            : "the metric's own units"
        var text = "\(threshold.summary), read as \(measured)."
        if amount == 0, direction == .below {
            // Legal, and almost certainly not what was meant. Said rather than
            // blocked: a count that genuinely can go negative exists, and a form
            // that refuses a valid bound is worse than one that questions it.
            text += " A count can't drop below zero, so this alert would never fire."
        }
        if currentReading == nil {
            text += " This insight has no computed numbers yet, so there was nothing to start the field from."
        }
        return text
    }

    private var recipientName: String {
        model.me?.displayName ?? "you"
    }

    private var recipientFooter: String {
        guard model.me?.userID != nil else {
            // The one field this form cannot fill in, said plainly rather than
            // discovered as a refused Save. `subscribed_users` takes numeric user
            // ids and `/api/users/@me/` is the only place this app learns one.
            return "GetHog hasn't been told your PostHog user id yet, and an alert needs at least one person to tell. Pull to refresh on any screen, or set this one up in PostHog."
        }
        return "Alerts are e-mailed by PostHog to the people subscribed to them. GetHog can only subscribe you — adding colleagues, a Slack channel or a webhook is done in PostHog."
    }

    // MARK: - Draft

    private var threshold: AlertThreshold? {
        switch direction {
        case .below: AlertThreshold(kind: thresholdKind, lower: amount, upper: nil)
        case .above: AlertThreshold(kind: thresholdKind, lower: nil, upper: amount)
        }
    }

    /// The insight's series labels, when the saved query carries them.
    ///
    /// Read off the **raw** source rather than the decoded model: `QuerySource`
    /// keeps `kind` and the display type and nothing else, and the series are
    /// exactly the part it discards. `nil` means the node had no `series` array at
    /// all, which is different from having one — a funnel has series too, and the
    /// picker is only shown for the kind that indexes them.
    private var seriesLabels: [String]? {
        guard insight.sourceKind == "TrendsQuery",
              case .array(let series)? = insight.rawSource?["series"]
        else { return nil }
        return series.enumerated().map { index, node in
            node["custom_name"]?.stringValue
                ?? node["name"]?.stringValue
                ?? node["event"]?.stringValue
                ?? "Series \(index + 1)"
        }
    }

    private var config: AlertConfig {
        insight.sourceKind == "FunnelsQuery"
            ? .funnel(metric: funnelMetric, step: nil)
            : .trends(seriesIndex: seriesIndex)
    }

    private var draft: AlertDraft? {
        guard let threshold, let userID = model.me?.userID else { return nil }
        return AlertDraft(
            insightID: insight.id,
            name: name,
            subscribedUserIDs: [userID],
            threshold: threshold,
            condition: condition,
            config: config,
            interval: interval
        )
    }

    // MARK: - Actions

    /// Names the alert after the insight, and starts the threshold at the number
    /// the insight is currently reading.
    ///
    /// The name half: a blank name is refused by this app's own draft validation,
    /// and an unnamed alert on PostHog's side falls back to the insight's name in
    /// the list — so an empty field would have been a required field with no
    /// default, for a value the screen already knows.
    ///
    /// The threshold starts at the insight's current value. Here the default
    /// direction is *below*, so a zero is a bad default: "drops below 0" is a perfectly
    /// legal alert that a count metric can essentially never satisfy, and the Set
    /// button was live over it. Photographed at zero before this existed
    /// (`build/Screenshots/…/insight-alert-composer.png`, 2026-07-31).
    ///
    /// Left at zero when the insight has no drawable number, which is a real
    /// state — this project's saved insights arrive with `result: null` until
    /// something computes them — and the footer then says what a bound of zero
    /// means rather than pretending to a reading.
    private func seedIfNeeded() {
        guard name.isEmpty else { return }
        name = String(insight.title.prefix(255))

        guard let reading = currentReading else { return }
        amount = reading.value
        thresholdKind = reading.isFraction ? .percentage : .absolute
    }

    /// What the insight reads right now, in the units its alert would be written
    /// in.
    ///
    /// A funnel's alert watches its **conversion**, which `FunnelGroup.conversionRate`
    /// gives as a fraction of one — the same scale `AlertThreshold.Kind.percentage`
    /// is read on, and the same scale `InsightAlert.summarise` multiplies by 100
    /// on the way out. So the two agree by construction rather than by a factor
    /// written twice.
    private var currentReading: (value: Double, isFraction: Bool)? {
        switch insight.renderModel {
        case .bigNumber(let number):
            return (number.value.rounded(), false)
        case .timeSeries(let series, _):
            // The series the alert will actually watch, not the first — the two
            // differ the moment a trends insight draws more than one line, and
            // seeding from the wrong one is a number that looks measured.
            guard series.indices.contains(seriesIndex),
                  let last = series[seriesIndex].points.last
            else { return nil }
            return (last.value.rounded(), false)
        case .barValue(let bars):
            guard let top = bars.max(by: { $0.value < $1.value }) else { return nil }
            return (top.value.rounded(), false)
        case .funnel(let groups):
            guard let group = groups.first, group.conversionRate > 0 else { return nil }
            return (group.conversionRate, true)
        // Not composable anyway — `AlertableInsight` refuses these kinds before
        // this form is drawn — but stated rather than defaulted, so a kind added
        // to `composable` later has to answer this question too.
        case .hogQL, .lifecycle, .retention, .stickiness, .paths, .unsupported:
            return nil
        }
    }

    private func save() {
        guard let draft else { return }
        isSaving = true
        Task {
            let saved = await onSave(draft)
            isSaving = false
            if saved { dismiss() }
        }
    }
}
