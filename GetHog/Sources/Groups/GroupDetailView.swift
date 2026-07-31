import GetHogKit
import SwiftUI

/// The window every section of this screen asks about.
///
/// One window, not one per section, so the three answers can be read against
/// each other — "2,222 events, 5 people, 4 recordings" only means anything if
/// all three were measured over the same days. Thirty days also matches the
/// window PostHog's own taxonomy query is fixed to, so the Groups and Taxonomy
/// screens do not quietly disagree about what "recently" means.
///
/// It is stated on screen rather than assumed. A group that was busy last
/// quarter and silent this month reads as empty here, and that is a true
/// statement about thirty days rather than about the group.
private let activityWindow: TimeInterval = 30 * 24 * 60 * 60

@MainActor
@Observable
final class GroupActivityStore {
    var breakdown: [GroupEventBreakdownRow] = []
    var people: [GroupPersonRow] = []
    var recordings: [SessionRecording] = []
    /// True when the recordings list said another page exists. There is no
    /// count on that endpoint at all, so this is the only thing that can be
    /// said about what is not shown.
    var hasMoreRecordings = false

    /// Three failures, kept apart. The event breakdown and the people list are
    /// `/query/` and need `query:read`; the recordings list is its own endpoint
    /// on the analytics budget and can be refused on its own. Folding them into
    /// one error would blank two working sections because the third was denied,
    /// which is the mistake `TaxonomyStore` already documents.
    var activityError: LoadFailure?
    var peopleError: LoadFailure?
    var recordingsError: LoadFailure?

    var isLoading = false
    var loadedAt: Date?

    /// Distinguishes "loaded and empty" from "not loaded yet". Without it the
    /// empty state renders for a beat before the first response arrives and
    /// claims the group did nothing.
    var hasLoaded = false

    /// Three requests per group opened: two `.query`, one `.analytics`. That is
    /// the whole cost of this screen, it is paid once on open and again only on
    /// pull-to-refresh, and it is why the breakdown is one query carrying its
    /// own totals rather than a query per number on screen.
    func load(client: PostHogClient, projectID: Int, groupTypeIndex: Int, groupKey: String) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let since = Date().addingTimeInterval(-activityWindow)

        async let breakdownTask = Self.fetch {
            try await client.send(
                PostHogAPI.groupEventBreakdown(
                    projectID: projectID,
                    groupTypeIndex: groupTypeIndex,
                    groupKey: groupKey,
                    since: since
                )
            ) as QueryResponse
        }

        async let peopleTask = Self.fetch {
            try await client.send(
                PostHogAPI.groupPeople(
                    projectID: projectID,
                    groupTypeIndex: groupTypeIndex,
                    groupKey: groupKey,
                    since: since
                )
            ) as QueryResponse
        }

        async let recordingsTask = Self.fetch {
            try await client.send(
                PostHogAPI.groupRecordings(
                    projectID: projectID,
                    groupTypeIndex: groupTypeIndex,
                    groupKey: groupKey
                )
            ) as RecordingList
        }

        switch await breakdownTask {
        case .success(let response):
            breakdown = response.rows.compactMap(GroupEventBreakdownRow.init(row:))
            activityError = nil
        case .failure(let error):
            activityError = LoadFailure(error, loading: "this group's activity")
        }

        switch await peopleTask {
        case .success(let response):
            people = response.rows.compactMap(GroupPersonRow.init(row:))
            peopleError = nil
        case .failure(let error):
            peopleError = LoadFailure(error, loading: "the people in this group")
        }

        switch await recordingsTask {
        case .success(let list):
            recordings = list.results
            hasMoreRecordings = list.hasNext
            recordingsError = nil
        case .failure(let error):
            recordingsError = LoadFailure(error, loading: "this group's recordings")
        }

        loadedAt = Date()
    }

    /// Total events in the window, taken from the window function in the query
    /// rather than by summing the rows on screen — the rows are the top twelve
    /// names and their sum is not the group's total.
    var totalOccurrences: Int? { breakdown.first?.totalOccurrences }
    var distinctEvents: Int? { breakdown.first?.distinctEvents }
    var distinctPeople: Int? { people.first?.distinctPeople }

    /// `nonisolated` so the three `async let`s above actually overlap rather than
    /// queueing behind the main actor before each one reaches its `await`.
    ///
    /// A `Result` rather than a `throws`, because `async let` binds a value and
    /// three independent failures have to be caught separately — one `try` over
    /// the group would let the first failure cancel the other two.
    nonisolated private static func fetch<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}

/// One group: what it is called, what it carries, and — the part that makes it
/// worth opening — what actually happened inside it.
///
/// Read-only throughout. PostHog's own group page also adds, edits and deletes
/// group properties; none of that is here, and not because it was hard. Every
/// mutation in this app goes through a confirmation naming the object and the
/// direction, an inline property editor is the opposite of that, and the key
/// this was built against cannot write anyway.
struct GroupDetailView: View {
    let group: GroupRow
    let groupType: GroupType

    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = GroupActivityStore()

    /// A recording opened from inside a group — level 2 of the Groups screen,
    /// under the type at level 0 and the group at level 1.
    ///
    /// Same reason as the two above it: this whole subtree is discarded when the
    /// size class swaps hosts, so a `@State` here would drop the player a reader
    /// had open. Three levels restore in order because each one registers its
    /// own `navigationDestination(item:)` against its own slot.
    private var openRecording: Binding<SessionRecording?> {
        Binding(
            get: { openDetails[.groups, level: 2] as? SessionRecording },
            set: {
                openDetails[.groups, level: 2] = $0.map(AnyHashable.init)
                // Two destinations hang off this one screen, so opening either
                // has to close the other. Both being set at once would leave
                // which one presents up to SwiftUI.
                if $0 != nil { openDetails[.groups, level: 3] = nil }
            }
        )
    }

    /// The open event feed — level 3, a sibling of the recording rather than
    /// beneath it. Both are pushed from this screen, from different sections.
    private var openEventFeed: Binding<GroupEventFeedTarget?> {
        Binding(
            get: { openDetails[.groups, level: 3] as? GroupEventFeedTarget },
            set: {
                openDetails[.groups, level: 3] = $0.map(AnyHashable.init)
                if $0 != nil { openDetails[.groups, level: 2] = nil }
            }
        )
    }

    private func feedTarget(event: String?) -> GroupEventFeedTarget {
        GroupEventFeedTarget(
            groupTypeIndex: groupType.index,
            groupKey: group.key,
            groupTitle: group.displayName,
            eventName: event
        )
    }

    var body: some View {
        List {
            identitySection
            activitySection
            peopleSection
            recordingsSection
            propertiesSection

            if let url = model.webURL(path: "groups/\(groupType.index)/\(webEncodedKey)") {
                Section {
                    Link(destination: url) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                    }
                }
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .pageSurface()
        .navigationTitle(group.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: openRecording) { recording in
            SessionDetailView(recording: recording)
        }
        .navigationDestination(item: openEventFeed) { target in
            GroupEventListView(target: target, since: Date().addingTimeInterval(-activityWindow))
        }
        .refreshable { await load() }
        .task(id: group.key) { await load() }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            LabeledContent("Name") {
                Text(group.hasDisplayName ? group.displayName : "Not set")
                    .foregroundStyle(group.hasDisplayName ? .primary : .secondary)
            }
            LabeledContent("Key") {
                Text(group.key)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Created") {
                Text(group.createdAt.map {
                    $0.formatted(.dateTime.day().month().year())
                } ?? "Unknown")
            }
            LabeledContent("Type") {
                Text(groupType.groupType).font(.caption.monospaced())
            }
        } header: {
            SectionLabel(text: groupType.singularName, systemImage: "building.2")
        }
    }

    // MARK: - Activity

    /// What the group did, by event name, as shares of its own traffic.
    @ViewBuilder
    private var activitySection: some View {
        Section {
            if let error = store.activityError {
                SectionFailure(failure: error) { Task { await load() } }
            } else if !store.hasLoaded {
                ForEach(0..<3, id: \.self) { index in
                    GroupEventShareRow(row: Self.placeholderBreakdown(index))
                }
                .skeleton(true)
            } else if store.breakdown.isEmpty {
                // Not "this group has no events". Thirty days is what was asked
                // about, and a group created two years ago that went quiet last
                // spring looks exactly like this.
                Text("No events carried this \(groupType.singularName.lowercased())'s key in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.breakdown) { row in
                    Button {
                        openEventFeed.wrappedValue = feedTarget(event: row.event)
                    } label: {
                        GroupEventShareRow(row: row)
                    }
                    .buttonStyle(.plain)
                }

                // Always present, not only when the breakdown was truncated. The
                // mixed chronological feed is a different reading of the same
                // data — what this group did, in order — and a group with nine
                // event names deserves it as much as one with forty. When the
                // breakdown *was* truncated the row also says by how much, which
                // is what stops "N more" from being a dead end.
                let hidden = GroupEventBreakdownRow.hiddenEventCount(store.breakdown)
                Button {
                    openEventFeed.wrappedValue = feedTarget(event: nil)
                } label: {
                    Label(
                        hidden > 0
                            ? "All events — \(hidden) more name\(hidden == 1 ? "" : "s") than shown"
                            : "All events, newest first",
                        systemImage: "list.bullet"
                    )
                    .font(.caption)
                }
            }
        } header: {
            SectionLabel(text: activityHeader, systemImage: "bolt")
        } footer: {
            Text("Events whose \(PostHogAPI.groupColumn(index: groupType.index)) is this group's key, over the last 30 days. Percentages are of the group's own total, not of the project's. Tap a name for the events themselves.")
        }
    }

    private var activityHeader: String {
        guard let total = store.totalOccurrences, let names = store.distinctEvents else {
            return "Activity"
        }
        return "\(Double(total).compactFormatted) events · \(names) name\(names == 1 ? "" : "s")"
    }

    // MARK: - People

    @ViewBuilder
    private var peopleSection: some View {
        Section {
            if let error = store.peopleError {
                SectionFailure(failure: error) { Task { await load() } }
            } else if !store.hasLoaded {
                ForEach(0..<2, id: \.self) { index in
                    GroupPersonRowView(person: Self.placeholderPerson(index))
                }
                .skeleton(true)
            } else if store.people.isEmpty {
                Text("Nobody sent an event for this \(groupType.singularName.lowercased()) in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.people) { person in
                    GroupPersonRowView(person: person)
                }

                let hidden = GroupPersonRow.hiddenPersonCount(store.people)
                if hidden > 0 {
                    Text("\(hidden) more person\(hidden == 1 ? "" : "s") not shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(text: peopleHeader, systemImage: "person.2")
        } footer: {
            // Says what the relationship is, because it is weaker than the word
            // "related" suggests and the difference matters when someone is
            // reading this as an account roster.
            Text("People who sent an event carrying this group's key in the last 30 days. PostHog stores no membership list, so this is what was observed rather than who belongs.")
        }
    }

    private var peopleHeader: String {
        guard let count = store.distinctPeople else { return "People" }
        return "\(count) \(count == 1 ? "person" : "people")"
    }

    // MARK: - Recordings

    @ViewBuilder
    private var recordingsSection: some View {
        Section {
            if let error = store.recordingsError {
                SectionFailure(failure: error) { Task { await load() } }
            } else if !store.hasLoaded {
                ForEach(0..<2, id: \.self) { _ in
                    GroupRecordingRowView(recording: nil)
                }
                .skeleton(true)
            } else if store.recordings.isEmpty {
                Text("No recordings from sessions that touched this \(groupType.singularName.lowercased()) in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.recordings) { recording in
                    Button {
                        openRecording.wrappedValue = recording
                    } label: {
                        GroupRecordingRowView(recording: recording)
                    }
                    .buttonStyle(.plain)
                }

                if store.hasMoreRecordings {
                    // Deliberately not "N more". The recordings endpoint returns
                    // no count of any kind — `has_next` is all it says — so a
                    // number here would be invented.
                    Text("More recordings matched than are shown here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionLabel(text: recordingsHeader, systemImage: "play.rectangle")
        } footer: {
            Text("Recordings whose session emitted an event for this group. The recording list defaults to about three days when no window is given, so this one asks for thirty explicitly.")
        }
    }

    /// Never a total. `RecordingList` has no `count`, so the header says how
    /// many are on screen and lets `has_next` say the rest.
    private var recordingsHeader: String {
        guard store.hasLoaded, !store.recordings.isEmpty else { return "Recordings" }
        return "\(store.recordings.count) recording\(store.recordings.count == 1 ? "" : "s") shown"
    }

    // MARK: - Properties

    @ViewBuilder
    private var propertiesSection: some View {
        if case .object(let dict) = group.properties, !dict.isEmpty {
            Section {
                ForEach(dict.keys.sorted(), id: \.self) { key in
                    PropertyRow(key: key, value: dict[key] ?? .null)
                }
            } header: {
                SectionLabel(text: "Properties (\(dict.count))", systemImage: "tag")
            } footer: {
                // The one place this screen has to say what it is not. PostHog's
                // own group page edits these in place.
                Text("Read-only. GetHog does not edit group properties.")
            }
        } else {
            Section {
                Text("This \(groupType.singularName.lowercased()) has no properties set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionLabel(text: "Properties", systemImage: "tag")
            }
        }
    }

    // MARK: - Plumbing

    /// Group keys are opaque strings that may contain characters a path segment
    /// cannot carry verbatim.
    private var webEncodedKey: String {
        group.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? group.key
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(
            client: client,
            projectID: projectID,
            groupTypeIndex: groupType.index,
            groupKey: group.key
        )
    }

    /// Placeholder rows rather than a spinner, so the sections keep their height
    /// and the list does not jump when three responses land at different times.
    private static func placeholderBreakdown(_ index: Int) -> GroupEventBreakdownRow {
        GroupEventBreakdownRow(row: QueryRow(
            columns: ["event", "occurrences", "people", "total_occurrences", "distinct_events"],
            values: [
                .string("$placeholder_event"),
                .number(Double(120 - index * 30)),
                .number(3),
                .number(400),
                .number(6),
            ]
        ))!
    }

    private static func placeholderPerson(_ index: Int) -> GroupPersonRow {
        GroupPersonRow(row: QueryRow(
            columns: ["person_id", "email", "occurrences", "distinct_people"],
            values: [
                .string("placeholder-\(index)"),
                .string("placeholder@example.com"),
                .number(Double(90 - index * 20)),
                .number(4),
            ]
        ))!
    }
}

// MARK: - Rows

/// An event name inside a group, drawn as a share of the group's own traffic.
struct GroupEventShareRow: View {
    let row: GroupEventBreakdownRow

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            header

            // Only when there is a real denominator. A bar with no share behind
            // it is decoration that looks like data.
            if let share = row.share {
                ShareBar(fraction: share)
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Space.xs)
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.event)
        .accessibilityValue(spokenValue)
    }

    /// Name and count side by side normally, stacked at accessibility sizes —
    /// the count is fixed furniture and at AX5 it left the event name a few
    /// characters wide.
    @ViewBuilder
    private var header: some View {
        let name = Text(row.event)
            .font(.subheadline)
            .lineLimit(2)
            .truncationMode(.middle)
        let count = Text(Double(row.occurrences).compactFormatted)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                name
                count
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                name
                Spacer(minLength: Theme.Space.s)
                count
            }
        }
    }

    private var footnote: String {
        var parts: [String] = []
        if let share = row.share {
            parts.append(ShareFormat.text(share))
        }
        parts.append("\(row.people) \(row.people == 1 ? "person" : "people")")
        if let last = row.lastSeen {
            parts.append("last \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private var spokenValue: String {
        var parts = ["\(row.occurrences.formatted()) events"]
        if let share = row.share {
            parts.append(ShareFormat.spoken(share) + " of this group")
        }
        parts.append("\(row.people) \(row.people == 1 ? "person" : "people")")
        if let last = row.lastSeen {
            parts.append("last seen \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ", ")
    }
}

struct GroupPersonRowView: View {
    let person: GroupPersonRow

    var body: some View {
        DataRow(
            glyph: "person",
            title: person.displayName,
            subtitle: person.hasHumanName ? person.distinctID : "No name or email recorded",
            footnote: footnote,
            isSubtitleMonospaced: person.hasHumanName,
            accessory: .metric(Double(person.occurrences).compactFormatted)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var footnote: String {
        guard let last = person.lastSeen else { return "Last seen unknown" }
        return "Last seen \(last.formatted(.relative(presentation: .named)))"
    }

    private var spokenSummary: String {
        var parts = [person.displayName]
        if !person.hasHumanName { parts.append("no name or email recorded") }
        parts.append("\(person.occurrences.formatted()) events in this group")
        parts.append(footnote)
        return parts.joined(separator: ", ")
    }
}

/// A recording row. `nil` draws the skeleton, so the placeholder and the real
/// row are the same view and cannot drift apart in height.
struct GroupRecordingRowView: View {
    let recording: SessionRecording?

    var body: some View {
        DataRow(
            glyph: recording?.isReplayable == false ? "iphone" : "play.rectangle",
            title: recording?.personDisplayName ?? "placeholder@example.com",
            subtitle: recording?.pathComponent ?? "/placeholder",
            footnote: footnote,
            isSubtitleMonospaced: true,
            accessory: .metric(recording?.durationText ?? "0:00")
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var footnote: String {
        guard let recording else { return "placeholder" }
        var parts: [String] = []
        if let start = recording.startTime {
            parts.append(start.formatted(.relative(presentation: .named)))
        }
        // Says so rather than letting a reader tap into a player that cannot
        // draw anything: mobile replay needs a transform PostHog has not
        // published, which `SessionRecording.isReplayable` already encodes.
        if !recording.isReplayable {
            parts.append("mobile — not playable here")
        }
        if recording.hasErrors {
            parts.append("\(recording.consoleErrorCount) console error\(recording.consoleErrorCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        guard let recording else { return "Loading" }
        return "\(recording.personDisplayName), \(recording.durationText), \(footnote)"
    }
}

// MARK: - Shared pieces

/// How a share is written, in the one place both screens read it from.
///
/// Exists because of a rendered defect rather than a theory: `$browser` on the
/// live project has a value with 4 of 28,966 events, and
/// `.percent.precision(.fractionLength(0...1))` typeset that as **`0%`** — a
/// share that is not zero, printed as zero, next to a bar that is visibly not
/// empty. Four events being 0% of anything is a claim the data does not make.
///
/// Anything below the smallest figure the format can show becomes `<0.1%`, and
/// a genuine zero still prints `0%`.
enum ShareFormat {
    static func text(_ share: Double) -> String {
        if share > 0 && share < 0.001 { return "<0.1%" }
        return share.formatted(.percent.precision(.fractionLength(0...1)))
    }

    /// The spoken form. Same rule, said as words — VoiceOver reads `<` as "less
    /// than" inconsistently across voices, so it is spelled out.
    static func spoken(_ share: Double) -> String {
        if share > 0 && share < 0.001 { return "less than 0.1 percent" }
        return share.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

/// A proportion bar.
///
/// The fill is clipped by the **track's** shape rather than its own, because a
/// `Capsule` fill at the `max(2, …)` floor resolves its radius in its own
/// coordinate space: a 2pt-wide capsule is a 1pt circle, and it escapes the
/// corner of the track it is supposed to sit inside.
struct ShareBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    Rectangle()
                        .fill(SeriesPalette.color(at: 0))
                        .frame(width: max(2, geo.size.width * min(fraction, 1)))
                }
            }
        }
        .frame(height: height)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// A failure that belongs to one section rather than to the screen.
///
/// `EmptyStateView` paints its own ground and centres itself, which is right for
/// a whole screen and wrong for one section of a list that still has three
/// working ones above and below it.
struct SectionFailure: View {
    let failure: LoadFailure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(failure.summary, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
            // The verbatim fault stays behind a disclosure for the same reason
            // `LoadFailureState` keeps it there: the sentence is what the screen
            // says, and a `DecodingError` dump is one tap away for whoever can
            // use it rather than being the thing a reader is shown.
            if let detail = failure.detail {
                FailureDetail(text: detail)
            }
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
