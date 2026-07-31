import GetHogKit
import SwiftUI

/// What a breakdown row pushes: a group, optionally narrowed to one event name.
///
/// The name is optional because the same screen serves both "everything this
/// group did" and "every time this group sent `$rageclick`", and splitting them
/// into two screens would duplicate the paging and the empty states.
struct GroupEventFeedTarget: Hashable {
    let groupTypeIndex: Int
    let groupKey: String
    let groupTitle: String
    /// `nil` for the whole feed.
    let eventName: String?
}

@MainActor
@Observable
final class GroupEventFeedStore {
    var events: [EventRow] = []
    var error: LoadFailure?
    var isLoading = false
    var loadedAt: Date?
    var hasLoaded = false
    /// True when the page came back full, which is the only evidence of more.
    ///
    /// A HogQL query that writes its own `LIMIT` gets no `hasMore` back — the
    /// flag is only set when PostHog applied a cap of its own — so a full page
    /// is all this can say, and it says exactly that rather than a count.
    var pageWasFull = false

    private let pageSize = 50

    func load(client: PostHogClient, projectID: Int, target: GroupEventFeedTarget, since: Date) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.groupEvents(
                    projectID: projectID,
                    groupTypeIndex: target.groupTypeIndex,
                    groupKey: target.groupKey,
                    eventName: target.eventName,
                    since: since,
                    limit: pageSize
                )
            )
            events = response.rows.compactMap(EventRow.init(row:))
            pageWasFull = response.rows.count >= pageSize
            error = nil
            loadedAt = Date()
        } catch {
            self.error = LoadFailure(error, loading: "this group's events")
        }
    }
}

/// One group's events, newest first.
///
/// The breakdown one screen up says how much of each name there is; this is the
/// events themselves, and it is the reason the breakdown rows are tappable
/// rather than being a chart you can only look at.
struct GroupEventListView: View {
    let target: GroupEventFeedTarget
    /// The same window every other section of the group screen asked about, so
    /// a reader arriving from a "1,067 events" row is not shown a different set.
    let since: Date

    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = GroupEventFeedStore()

    /// Level 3 of the Groups screen: type, group, feed, event.
    private var openEvent: Binding<EventRow?> {
        Binding(
            get: { openDetails[.groups, level: 4] as? EventRow },
            set: { openDetails[.groups, level: 4] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        content
            .navigationTitle(target.eventName ?? target.groupTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: openEvent) { event in
                EventDetailView(event: event)
            }
            .refreshable { await load() }
            .task(id: "\(target.groupKey)|\(target.eventName ?? "")") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.events.isEmpty {
            LoadFailureState(title: "Couldn't load events", failure: error) {
                Task { await load() }
            }
        } else if store.events.isEmpty && store.hasLoaded {
            // Says what was asked. Not "this group has no events" — the query
            // was bounded to a window and, on this route, often to one name.
            EmptyStateView(
                title: "Nothing in this window",
                systemImage: "bolt.slash",
                message: target.eventName.map {
                    "No “\($0)” events carried this group's key in the last 30 days."
                } ?? "No events carried this group's key in the last 30 days."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.events) { event in
                    Button {
                        openEvent.wrappedValue = event
                    } label: {
                        EventRowView(event: event)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        Theme.cardBackground
                            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                            .padding(.vertical, 1)
                    )
                    .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(text: "\(store.events.count) loaded", systemImage: "bolt")
            } footer: {
                // A full page is evidence of more and nothing else. There is no
                // count on this query and no `hasMore` on a self-limited HogQL
                // response, so "50 of N" would be a number nobody supplied.
                Text(store.pageWasFull
                    ? "Newest first, over the last 30 days. This page is full, so there are more."
                    : "Newest first, over the last 30 days.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.events.isEmpty)
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID, target: target, since: since)
    }
}
