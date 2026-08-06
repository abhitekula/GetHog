import GetHogKit
import GetHogUI
import SwiftUI

/// The session-recording filter, as much of it as belongs on a phone.
///
/// ## What is on the surface, and why
///
/// The web console's replay filter panel offers person, events and actions with
/// per-property sub-filters, duration, active duration, click and keypress
/// counts, console level *and* console content, feature-flag variant, device,
/// OS, country, and the three frustration signals. Reproducing that list on a
/// 390-point screen would produce a panel nobody could operate one-handed.
///
/// So the sheet is ordered by what somebody reaches for while holding a phone:
///
/// * **People** first, matching the console's project-configured exclusion for
///   internal and test users without trying to reproduce those definitions here.
/// * **What went wrong** next. It is the reason a replay list gets opened away
///   from a desk — a report came in and you want the sessions it happened in.
/// * **When**, because every other filter is meaningless without a window, and
///   because a narrow window is also the cheapest query.
/// * **How long**, carrying the total-versus-active distinction the console
///   makes and the old client-side picker did not.
/// * **Playable**, which is specific to this app: it cannot play mobile
///   recordings, and on a mobile-heavy project most of the list is unopenable.
/// * **Sort**, which changes the order rather than the contents.
///
/// Person search is *not* here. It lives in the navigation bar's search field,
/// which is the control a thumb finds without opening anything.
///
/// Under "More", because they are real but rarely the first move: page URL, and
/// any clause inherited from a saved filter that has no control of its own.
///
/// Deliberately absent, and the honest reasons:
///
/// * **Arbitrary events and actions with property sub-filters.** These need an
///   event-taxonomy browser and a per-property operator picker — a screen, not a
///   row. The four signals that matter are named individually instead.
/// * **Feature-flag variant, device, OS, country.** All person-property
///   equality filters. They need a property picker with server-side value
///   completion; the same screen, again. A saved filter that uses them is
///   carried through unchanged, so they are reachable, just not composable here.
/// * **Console log *content* search.** The API accepts it. PostHog's own saved
///   filter that uses it returns nothing — measured, `{key: message, operator:
///   gt, value: "5"}` turns three real results into zero. Shipping a control
///   that renders correct-looking empty lists is worse than not shipping it.
/// * **Click and keypress count thresholds.** Available as *sort* orders, where
///   they answer the same question ("show me the busy ones") without asking
///   somebody to guess a number.
struct SessionFilterSheet: View {
    @Binding var filter: SessionRecordingFilter
    @Environment(\.dismiss) private var dismiss
    @State private var showsMore = false

    var body: some View {
        NavigationStack {
            Form {
                peopleSection
                signalSection
                whenSection
                durationSection
                playableSection
                sortSection
                moreSection
            }
            // The app's ground, for the measured reason `AnnotationComposerView`
            // gives: a `Form` paints its own background over anything behind it,
            // so without this the sheet comes up on the system's grouped grey.
            // Sampled off `session-filter-sheet.png` on iPhone 17 Pro —
            // `#F2F2F7` in light and `#1C1C1E` in dark, against the app's
            // `#F2EFE9` / `#151413`. The annotation composer beside it already
            // carries this, which is why the two read as different apps.
            //
            // The sheet's own header and footer prose moves with the ground
            // rather than staying on the system's `.secondary`. That is not
            // tidying: `.secondary` composites to `#85858B` on the grouped grey
            // for **3.29:1** in light, below the 4.5:1 floor already, and
            // painting the same alpha ink on the cream ground would land it at
            // 3.26:1 — i.e. this change would have made a failing number
            // marginally worse. `Theme.Ink.secondary` is opaque and is the
            // token that exists for exactly this, at 6.95:1 on the light ground
            // and 10.09:1 on the dark one.
            .pageSurface()
            .navigationTitle("Filter sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Absent rather than disabled when nothing is narrowed.
                //
                // Measured on the rendered sheet: a disabled toolbar button
                // draws in the system's disabled ink, `#A4A4A7` on `#EBEBEF`
                // for **2.09:1** in light and `#656567` on `#1E1E20` for
                // **2.86:1** in dark, against a 4.5:1 floor. WCAG exempts an
                // inactive control from that floor, so this was not strictly a
                // violation — it was a word nobody could read, occupying the
                // leading slot of a sheet, describing an action with nothing to
                // act on. `filter.isNarrowed` is exactly "there is something to
                // clear", so the honest rendering of `false` is no button.
                ToolbarItem(placement: .topBarLeading) {
                    if filter.isNarrowed {
                        Button("Clear", role: .destructive) { filter.clear() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - People

    private var peopleSection: some View {
        Section {
            Toggle("Filter out internal and test users", isOn: $filter.filterTestAccounts)
        } header: {
            SectionLabel(text: "People")
        } footer: {
            Text("Uses the internal and test-user filters configured for this project in PostHog.")
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    // MARK: - What went wrong

    /// One signal, not a set of tick boxes.
    ///
    /// Measured, and the reason this is a `Picker` rather than a row of toggles:
    /// asking for two signals at once requires `operand=OR`, and `operand` is
    /// global — it ORs the person, URL and console clauses away at the same
    /// time. A multi-select here would silently widen every other filter on the
    /// sheet. One at a time is the shape the API can actually honour.
    private var signalSection: some View {
        Section {
            Picker("Signal", selection: $filter.signal) {
                Text("Any").tag(SessionRecordingFilter.Signal?.none)
                ForEach(SessionRecordingFilter.Signal.allCases) { signal in
                    Label(signal.title, systemImage: signal.systemImage)
                        .tag(SessionRecordingFilter.Signal?.some(signal))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            SectionLabel(text: "What went wrong")
        } footer: {
            Text("One at a time. PostHog applies a single combining rule to the whole filter, so asking for two signals would also widen everything else here.")
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    // MARK: - When

    private var whenSection: some View {
        Section {
            Picker("Time range", selection: $filter.dateWindow) {
                ForEach(SessionRecordingFilter.DateWindow.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
        } header: {
            SectionLabel(text: "When")
        }
    }

    // MARK: - How long

    private var durationSection: some View {
        Section {
            Picker("Longer than", selection: minimumDuration) {
                ForEach(Self.durationChoices, id: \.self) { seconds in
                    Text(Self.durationTitle(seconds)).tag(seconds)
                }
            }

            // Segmented controls shrink their labels to slivers at accessibility
            // text sizes, so past that threshold the same choice becomes a menu
            // — `adaptivePickerStyle`, which is the adaptation `PeopleRoot`
            // documents, named once in `DesignKit`. "Total length" and "Active
            // time" are the two longest labels on this sheet.
            Picker("Measured as", selection: $filter.durationMetric) {
                ForEach(SessionRecordingFilter.DurationMetric.allCases, id: \.self) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .adaptivePickerStyle()
            .disabled((filter.minimumDuration ?? 0) <= 0)
        } header: {
            SectionLabel(text: "How long")
        } footer: {
            // These are genuinely different numbers and can be minutes apart.
            // The old picker filtered on wall-clock time without saying so.
            Text("Total length is wall-clock time from first event to last. Active time counts only the parts somebody was interacting — they are often minutes apart.")
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private static let durationChoices: [Double] = [0, 30, 120, 600, 1800]

    private static func durationTitle(_ seconds: Double) -> String {
        switch seconds {
        case 0: "Any"
        case 30: "30 seconds"
        case 120: "2 minutes"
        case 600: "10 minutes"
        default: "30 minutes"
        }
    }

    private var minimumDuration: Binding<Double> {
        Binding(
            get: { filter.minimumDuration ?? 0 },
            set: { filter.minimumDuration = $0 <= 0 ? nil : $0 }
        )
    }

    // MARK: - Playable

    private var playableSection: some View {
        Section {
            Toggle("Only recordings this app can play", isOn: Binding(
                get: { filter.source == .web },
                set: { filter.source = $0 ? .web : nil }
            ))
        } footer: {
            Text("Mobile recordings need a transform PostHog has not published, so this app lists them but cannot play them.")
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    // MARK: - Sort

    private var sortSection: some View {
        Section {
            Picker("Sort by", selection: $filter.order) {
                ForEach(SessionRecordingFilter.Order.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        } header: {
            SectionLabel(text: "Sort")
        }
    }

    // MARK: - More

    @ViewBuilder
    private var moreSection: some View {
        Section(isExpanded: $showsMore) {
            LabeledContent("Page URL contains") {
                TextField("path or host", text: Binding(
                    get: { filter.urlSearch ?? "" },
                    set: { filter.urlSearch = $0.isEmpty ? nil : $0 }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            }

            if filter.inheritedProperties.isEmpty {
                Text("Filters carried in from a saved filter appear here.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            } else {
                // Shown rather than silently applied. These come from a saved
                // filter made in the web console and are re-sent verbatim; the
                // list is running a narrower query than the controls above
                // describe, and it should say so.
                ForEach(Array(filter.inheritedProperties.enumerated()), id: \.offset) { _, clause in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clause.key)
                            .font(.footnote.monospaced())
                            // A property key re-sent verbatim to PostHog, so a
                            // hyphen invented here would misstate what the query
                            // is actually asking for. `zxx` is the ISO code for
                            // "no linguistic content".
                            .typesettingLanguage(Locale.Language(identifier: "zxx"))
                        Text("from a saved filter · \(clause.op ?? "exact")")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(clause.key), inherited from a saved filter")
                }

                Button("Remove inherited filters", role: .destructive) {
                    filter.inheritedProperties.removeAll()
                }
            }
        } header: {
            Text("More").foregroundStyle(Theme.Ink.secondary)
        }
    }
}
