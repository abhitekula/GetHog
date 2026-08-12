import GetHogUI
import Observation
import GetHogKit
import SwiftUI

extension View {
    /// Lets the charts inside offer a drill-down, and presents it.
    ///
    /// One modifier so the environment and the sheet cannot get out of step —
    /// an affordance whose presentation was forgotten is an affordance that does
    /// nothing.
    func insightPeople(for insight: Insight?) -> some View {
        modifier(InsightPeoplePresentation(insight: insight))
    }
}

private struct InsightPeoplePresentation: ViewModifier {
    let insight: Insight?

    @State private var request: InsightDrillRequest?

    private var context: InsightDrillContext? {
        guard let insight else { return nil }
        return InsightDrillContext(insight: insight) { request = $0 }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.insightDrill, context)
            .sheet(item: $request) { request in
                if let context {
                    InsightPeopleSheet(request: request, source: context.source)
                }
            }
    }
}

// MARK: - Naming a drill so two of them can be told apart

/// `InsightDrill.title` is what the reader *tapped* — a day, a series, a
/// breakdown value, a funnel step's name — and on every axis but one that is
/// enough to identify the drill on its own.
///
/// A funnel step is the exception, and it is the sharpest case in the app rather
/// than a cosmetic one. Tapping step 2 of a funnel offers **two** drills, and
/// both are titled with the step's name, so the picker read
///
///     Second page view · 45
///     Second page view · 92
///
/// — two entries spelled identically, distinguished only by numbers the reader
/// has no way to interpret. They are converted and dropped-off for the same
/// step, and they are complements: 92 = 137 − 45. Whichever was chosen, the
/// sheet's title then said "Second page view" too, so having chosen, you could
/// not tell which of the two you were looking at. On a screen whose entire
/// purpose is answering "who dropped out", that is the one question it must
/// never leave open.
///
/// `FunnelDrillOutcome` already carries the distinction; nothing was reading it.
extension InsightDrill {

    /// The outcome in two or three words, or `nil` on an axis where the drill's
    /// own title is already unique.
    ///
    /// Shorter than `FunnelDrillOutcome.title` ("Completed this step" /
    /// "Dropped off here") because it has to sit *alongside* the step name in a
    /// title bar that also holds two buttons, and the same wording is used in
    /// both places so the entry a reader picks and the screen they land on say
    /// the same word.
    var outcomeLabel: String? {
        guard case .funnelStep(_, let outcome) = kind else { return nil }
        switch outcome {
        case .converted: return "Completed"
        case .droppedOff: return "Dropped off"
        }
    }

    /// The row in the sibling picker.
    ///
    /// The step name is dropped here rather than added to: every entry in this
    /// picker belongs to the *same* step, so repeating it is the part that
    /// carries no information, and the picker is already labelled "Outcome". The
    /// step is named on the sheet the menu hangs off, which is where the reader
    /// came from and where they land.
    var pickerTitle: String { outcomeLabel ?? title }

    /// The sheet's navigation title.
    ///
    /// Outcome first, and for a reason beyond matching the picker: an inline
    /// title truncates from the tail, and it shares a 44pt bar with a filter
    /// button and a Done button. Leading with the step name would put the one
    /// word that distinguishes the two drills in exactly the position that gets
    /// cut — which is the same failure, one screen further on.
    var screenTitle: String {
        guard let outcomeLabel else { return title }
        return "\(outcomeLabel) · \(title)"
    }
}

// MARK: - Loading

@MainActor
@Observable
final class InsightActorsStore {

    private(set) var actors: [InsightActor] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var failure: LoadFailure?
    private(set) var hasMore = false
    /// How many actors PostHog could not resolve to a person record.
    private(set) var missingCount = 0
    private(set) var loadedAt: Date?

    private var seenIDs: Set<String> = []
    /// Which drill the current rows answer, so a re-entered `.task` cannot fire
    /// the same billed request twice.
    private var loadedDrill: InsightDrillKind?

    /// The first page.
    ///
    /// Only ever called from an explicit tap. One `query`-category slot per
    /// call, against a budget shared organisation-wide with the user's
    /// production integrations — which is why nothing here runs on appear,
    /// on hover, or speculatively for a drill the user has not asked for.
    func load(client: PostHogClient, projectID: Int, source: JSONValue, drill: InsightDrill) async {
        guard !isLoading, loadedDrill != drill.kind else { return }
        isLoading = true
        loadedDrill = drill.kind
        // Cleared up front: these rows answered a *different* question, and
        // leaving them under a new heading while the request is in flight would
        // state something untrue for as long as it takes.
        actors = []
        seenIDs = []
        hasMore = false
        missingCount = 0
        failure = nil
        defer { isLoading = false }

        guard let endpoint = PostHogAPI.insightActors(
            projectID: projectID, source: source, drill: drill
        ) else {
            failure = LoadFailure(
                summary: "This point can't be looked up.",
                detail: "The insight's saved query isn't in a shape PostHog's people query accepts."
            )
            return
        }

        do {
            let page = try await ActorsPage.decode(from: client.data(for: endpoint))
            actors = page.actors
            seenIDs = Set(page.actors.map(\.id))
            hasMore = page.hasMore
            missingCount = page.missingActorsCount
            loadedAt = Date()
            failure = nil
        } catch {
            failure = LoadFailure(error, loading: "people")
            // Released so "Try again" is not a no-op. `loadedDrill` exists to
            // stop a re-entered `.task` firing the same billed request twice;
            // after a failure there is nothing to protect, and leaving it set
            // would give the reader a retry button that silently does nothing.
            loadedDrill = nil
        }
    }

    func loadMore(
        client: PostHogClient, projectID: Int, source: JSONValue, drill: InsightDrill
    ) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        guard let endpoint = PostHogAPI.insightActors(
            projectID: projectID, source: source, drill: drill, offset: actors.count
        ) else { return }

        do {
            let page = try await ActorsPage.decode(from: client.data(for: endpoint))
            // De-duplicated on id: paging an actors query is offset-based, and
            // an offset page can repeat a row when the underlying set shifts
            // between requests. A repeated id would crash the `List`.
            let fresh = page.actors.filter { !seenIDs.contains($0.id) }
            actors += fresh
            seenIDs.formUnion(fresh.map(\.id))
            hasMore = page.hasMore && !fresh.isEmpty
            loadedAt = Date()
        } catch {
            failure = LoadFailure(error, loading: "more people")
            hasMore = false
        }
    }
}

// MARK: - The screen

/// The people behind one point of one chart.
struct InsightPeopleSheet: View {
    let request: InsightDrillRequest
    let source: JSONValue

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = InsightActorsStore()
    @State private var drill: InsightDrill

    init(request: InsightDrillRequest, source: JSONValue) {
        self.request = request
        self.source = source
        _drill = State(initialValue: request.selected)
    }

    var body: some View {
        NavigationStack {
            content
                .pageSurface()
                .navigationTitle(drill.screenTitle)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: PersonSummary.self) { person in
                    PersonDetailView(person: person)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    if request.siblings.count > 1 {
                        ToolbarItem(placement: .topBarLeading) { siblingPicker }
                    }
                }
                // Keyed on the drill, so switching to a sibling reloads. Each
                // switch is one more `query`-category request, which is why it
                // is a deliberate choice from a menu and not a swipe.
                .task(id: drill.kind) { await load() }
        }
    }

    /// The other answers to the same question.
    private var siblingPicker: some View {
        Menu {
            Picker(request.axisLabel, selection: $drill) {
                ForEach(request.siblings) { sibling in
                    Text("\(sibling.pickerTitle) · \(Int(sibling.expectedCount))")
                        .tag(sibling)
                }
            }
        } label: {
            Label(request.axisLabel, systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Change \(request.axisLabel.lowercased())")
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.actors.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = store.failure, store.actors.isEmpty {
            LoadFailureState(title: "Couldn't load these people", failure: failure) {
                Task { await load() }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.actors) { actor in
                    row(for: actor)
                }
                if store.hasMore {
                    loadMoreRow
                }
            } header: {
                Text(headline)
                    .textCase(nil)
            } footer: {
                footer
            }
        }
        .listRowSpacing(Theme.Space.xs)
        .overlay {
            if store.actors.isEmpty && !store.isLoading {
                EmptyStateView(
                    title: "No people here",
                    systemImage: "person.slash",
                    message: emptyMessage
                )
            }
        }
    }

    @ViewBuilder
    private func row(for actor: InsightActor) -> some View {
        // An unresolved actor has no person record to open, so it is a plain row
        // rather than a link that would push a blank screen.
        if let person = actor.personSummary, !actor.isUnresolved {
            NavigationLink(value: person) {
                InsightActorRow(actor: actor)
            }
            .listRowBackground(rowBackground)
            .listRowSeparator(.hidden)
        } else {
            InsightActorRow(actor: actor)
                .listRowBackground(rowBackground)
                .listRowSeparator(.hidden)
        }
    }

    private var rowBackground: some View {
        Theme.cardBackground
            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
    }

    private var loadMoreRow: some View {
        Button {
            Task {
                guard let client = model.client, let projectID = model.projectID else { return }
                await store.loadMore(
                    client: client, projectID: projectID, source: source, drill: drill
                )
            }
        } label: {
            HStack {
                Spacer()
                if store.isLoadingMore {
                    ProgressView()
                } else {
                    Text("Load more")
                        .font(Theme.Typography.body.weight(.medium))
                }
                Spacer()
            }
            // A 44pt target, because a list row's natural height is not one.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(store.isLoadingMore)
        .listRowBackground(rowBackground)
        .listRowSeparator(.hidden)
    }

    /// What the chart claims, stated before the list rather than instead of it.
    private var headline: String {
        let expected = Int(drill.expectedCount.rounded())
        return expected == 1 ? "1 person on this chart" : "\(expected) people on this chart"
    }

    /// The two honest caveats, and they are separate facts.
    ///
    /// `missingCount` is PostHog's own count of actors it could not resolve to a
    /// person record — measured at 3 of 5 on a live trends drill and 184 of 186
    /// on a retention one. Without stating it, a list of two rows under a
    /// heading claiming 186 people reads as a bug in this app.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if store.missingCount > 0 {
                Text(
                    store.missingCount == 1
                        ? "1 of these has no person record left in PostHog and can't be listed."
                        : "\(store.missingCount) of these have no person record left in PostHog and can't be listed."
                )
            }
            if store.hasMore {
                Text("Showing the first \(store.actors.count).")
            }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Ink.tertiary)
    }

    private var emptyMessage: String {
        store.missingCount > 0
            ? "PostHog counted \(store.missingCount) here but has no person records left for them."
            : "PostHog returned no people for this point."
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, source: source, drill: drill)
    }
}

struct InsightActorRow: View {
    let actor: InsightActor

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            // The avatar is a fixed 34pt that does not scale, so past the
            // accessibility threshold it stops being a small decoration and
            // becomes a quarter of the row's width taken from the only part
            // that carries information. Rendered at AX5 it left "Nina…llano"
            // and "nina.….com" — a name and an email truncated to the point of
            // being unusable, in a list whose entire job is to say who these
            // people are. The initials only ever repeated the name anyway.
            if !dynamicTypeSize.isAccessibilitySize {
                PersonAvatar(initials: actor.initials)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(actor.displayName)
                    .font(Theme.Typography.body)
                    .lineLimit(lineLimit)
                    // Either end of a distinct id can be the distinguishing
                    // part, and a UUID's tail is the only part that differs.
                    .truncationMode(.middle)
                if let subtitle = actor.subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(lineLimit)
                        .truncationMode(.middle)
                }
                if actor.isUnresolved {
                    // Never by colour alone, and never silently: this row is a
                    // real person PostHog counted and can no longer describe.
                    Label("No person record", systemImage: "person.fill.questionmark")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
            // Nothing here is prose. A person is identified by an email or a
            // distinct id, and SwiftUI's default typesetting language inherits
            // the app locale — whose English hyphenation dictionary rendered
            // sample.user@example.org` at accessibility sizes. A hyphen
            // inside an address changes what the address *is*, so this is a
            // wrong string rather than an ugly one.
            .typesettingLanguage(Locale.Language(identifier: "zxx"))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var lineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }
}

// MARK: - Bridging to the person screen

extension InsightActor {
    /// The same person, in the shape the people screens already take.
    ///
    /// Round-tripped through JSON rather than reaching for a memberwise
    /// initialiser, because the actors response embeds the *whole* person object
    /// that `/persons/` returns — so decoding it is not a conversion, it is the
    /// same decode that screen already does, and it cannot drift from it.
    var personSummary: PersonSummary? {
        guard let data = try? JSONEncoder().encode(raw) else { return nil }
        return try? JSONDecoder().decode(PersonSummary.self, from: data)
    }
}
