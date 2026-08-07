import GetHogKit
import GetHogUI
import SwiftUI

/// One person's most recent events, read straight from HogQL.
///
/// The persons endpoint doesn't carry activity, so this is a second, separate
/// request — kept in its own store so a failure here leaves the profile intact.
@MainActor
@Observable
final class PersonEventsStore {
    var events: [PersonEvent] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// The `LIMIT` this store's own query writes, kept as a constant so the
    /// number in the SQL, the number the footer states and the number the row
    /// count is compared against cannot drift apart.
    static let limit = 50

    /// Whether this person has more activity than the 50 rows below.
    ///
    /// **This read `response.isTruncated` alone, and the comment here asserted
    /// that the flag was "still worth reading with an explicit limit: it is the
    /// difference between 'this person has done 50 things' and 'here are the
    /// last 50 of more'". Measurement says the opposite**, and it is recorded on
    /// `QueryResponse.isTruncated` and again in `PostHogAPI+Groups.swift`:
    /// `hasMore` and `limit` come back **only when PostHog applied its own cap**.
    /// The same query with no `LIMIT` returned `hasMore: true, limit: 100` over
    /// 423 rows; written `LIMIT 200` it returned 200 rows of 423 with *neither
    /// field present*. This query has always written `LIMIT 50`, so the flag was
    /// silent at exactly the ceiling it was supposed to detect — the notice
    /// never appeared, and `scopeNote` went on to read the flag's falsity as
    /// evidence of completeness and say "PostHog reported no more" over a person
    /// with fifty thousand events. That is the failure mode the spec comment
    /// calls *more confidently wrong than never having looked*.
    ///
    /// Both signals now, because they cover disjoint cases: the row count is the
    /// only evidence at our own ceiling, and the flag is the only evidence if
    /// PostHog ever caps below it. `SessionTimelineStore` and `SchemaStore` are
    /// the worked examples this now matches.
    var isTruncated = false

    /// Rows PostHog returned, which is **not** `events.count`.
    ///
    /// `PersonEvent.init(row:)` is failable — it returns nil for any row without
    /// an `event` column — so counting decoded events puts a full page at 49
    /// against a ceiling of 50 and retires the notice precisely when the data is
    /// least trustworthy: a list that is both truncated and lossy, described as
    /// neither. Measured and corrected once already in `SessionTimelineStore`;
    /// `QueryTruncationTests` pins it there and now here.
    private(set) var rowsReturned = 0

    func load(client: PostHogClient, projectID: Int, distinctID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.hogql(projectID: projectID, sql: Self.query(distinctID: distinctID))
            )
            events = response.rows.compactMap(PersonEvent.init(row:))
            rowsReturned = response.rows.count
            isTruncated = response.isTruncated || rowsReturned >= Self.limit
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    static func query(distinctID: String) -> String {
        """
        SELECT event, timestamp, properties.$current_url
        FROM events
        WHERE distinct_id = '\(escapedForHogQL(distinctID))'
        ORDER BY timestamp DESC
        LIMIT \(limit)
        """
    }

    /// Distinct IDs are user-controlled strings that arrive from the API, so a
    /// stray quote must not be able to close the literal and change the query.
    ///
    /// Backslashes are escaped **first**: doing quotes first would then
    /// double-escape the backslash this step just introduced.
    static func escapedForHogQL(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

struct PersonEvent: Identifiable, Hashable {
    let id: String
    let event: String
    let timestamp: Date?
    let currentURL: String?

    init?(row: QueryRow) {
        guard let event = row.string("event") else { return nil }
        self.event = event
        self.timestamp = row.date("timestamp")
        // PostHog labels the projected column `$current_url`, but older
        // responses echo the full path expression back.
        self.currentURL = row.string("$current_url") ?? row.string("properties.$current_url")
        self.id = "\(event)|\(row.string("timestamp") ?? UUID().uuidString)"
    }
}

struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    let person: PersonSummary

    @State private var eventsStore = PersonEventsStore()

    /// The query filters on a single distinct ID, and a merged person can own
    /// several. Which one is used is stated in the UI rather than papered over.
    private var queriedDistinctID: String? { person.distinctIDs.first }

    var body: some View {
        List {
            Section { header }

            countsRow

            if !person.distinctIDs.isEmpty {
                Section {
                    ForEach(person.distinctIDs, id: \.self) { distinctID in
                        Text(distinctID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            #if !os(tvOS)
                            // The menu's one item is a pasteboard copy, and
                            // tvOS has no pasteboard to copy to.
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = distinctID
                                } label: {
                                    Label("Copy distinct ID", systemImage: "doc.on.doc")
                                }
                            }
                            #endif
                    }
                } header: {
                    SectionLabel(
                        text: "Distinct IDs (\(person.distinctIDs.count))",
                        systemImage: "number"
                    )
                }
            }

            recentEventsSection
            propertiesSection
        }
        .pageSurface()
        // Every label/value pair below stops at a readable measure instead of
        // spanning the window. See `Theme.Measure.pair`.
        .measuredPairs()
        .navigationTitle(person.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.projectID ?? 0)|\(person.id)") { await loadEvents() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            PersonAvatar(initials: person.initials, size: 56, font: .title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(person.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    // The same defect `PersonRowView` was fixed for, on the
                    // screen that states the identity rather than lists it, and
                    // it survived there because nothing had photographed this
                    // header at an accessibility size. Measured on
                    // `build/Screenshots/iPhone 17 Pro/ax5/person-detail.png`:
                    // `nina.drill.0729@example.com` wrapped as `nina.-` /
                    // `drill.0…`, so the headline of a person's profile carried
                    // a hyphen that is not in their address. `zxx` is "no
                    // linguistic content", so no hyphenation dictionary applies
                    // and the string breaks only where it already allows.
                    .typesettingLanguage(Locale.Language(identifier: "zxx"))

                StatusPill(
                    text: person.isIdentified ? "Identified" : "Anonymous",
                    tint: person.isIdentified ? Theme.accent : .secondary
                )

                if let created = person.createdAt {
                    Text("First seen \(created, format: .dateTime.year().month().day().hour().minute())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The three counts that frame everything below: how many identities this
    /// person merges, how much is known about them, and how much activity the
    /// events query actually returned. The last is capped at 50 — the section's
    /// own footer says so rather than the tile implying a total.
    private var countsRow: some View {
        StatStrip {
            MetricTile(
                label: "Distinct IDs",
                value: person.distinctIDs.count.formatted(),
                compact: true
            )
            MetricTile(label: "Properties", value: propertyCount.formatted(), compact: true)
            MetricTile(
                label: "Recent events",
                value: eventsStore.events.count.formatted(),
                compact: true
            )
        }
        // The strip is chrome, not a row: it sits on the page ground and brings
        // its own insets.
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var propertyCount: Int {
        guard let properties = person.properties, case .object(let dict) = properties else {
            return 0
        }
        return dict.count
    }

    // MARK: - Recent events

    @ViewBuilder
    private var recentEventsSection: some View {
        Section {
            if !model.isAvailable(.events) {
                Text("Recent events need the query:read scope on your API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = eventsStore.error, eventsStore.events.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await loadEvents() } }
                        .font(.caption)
                }
            } else if eventsStore.events.isEmpty && !eventsStore.isLoading {
                Text("No events recorded for this distinct ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(eventsStore.events) { event in
                    PersonEventRowView(event: event)
                }
                .skeleton(eventsStore.isLoading && eventsStore.events.isEmpty)
            }
        } header: {
            SectionLabel(text: "Recent events", systemImage: "clock")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // "Up to 50" was true of the *request* and said nothing about
                // the answer: 50 rows from a person with 50 events and 50 rows
                // from a person with 50,000 were the same sentence. What tells
                // them apart is the row count against this query's own `LIMIT`,
                // not the envelope flag — see `PersonEventsStore.isTruncated`.
                Text(scopeNote)
                if let distinctID = queriedDistinctID, person.distinctIDs.count > 1 {
                    Text("From \(distinctID) only — this person has \(person.distinctIDs.count) distinct IDs.")
                }
                FreshnessLabel(date: eventsStore.loadedAt)
            }
        }
    }

    /// What the events section is, and is not, a complete answer to.
    ///
    /// Reports the rows that came back rather than the events that decoded, for
    /// the reason `PersonEventsStore.rowsReturned` records: the two differ
    /// exactly when a row could not be read, and naming the smaller one would
    /// quietly shrink the page in the sentence that exists to describe it.
    private var scopeNote: String {
        if eventsStore.isTruncated {
            let count = eventsStore.rowsReturned
            return "The \(count) most recent events for this ID. This query stops at \(PersonEventsStore.limit) and filled it, so there are older events it did not read."
        }
        if eventsStore.events.isEmpty { return "Up to \(PersonEventsStore.limit) most recent events." }
        let count = eventsStore.rowsReturned
        // Not "all this person's events", and no longer "PostHog reported no
        // more" either — that sentence was drawn from a flag this query cannot
        // make speak, so it claimed completeness on no evidence at all. What is
        // actually known is that the page came back short of its own ceiling.
        return "\(count) recent \(count == 1 ? "event" : "events") — fewer than this query's ceiling of \(PersonEventsStore.limit), so this is everything the events table still holds for this ID."
    }

    // MARK: - Properties

    @ViewBuilder
    private var propertiesSection: some View {
        if let properties = person.properties, case .object(let dict) = properties, !dict.isEmpty {
            Section {
                ForEach(dict.keys.sorted(), id: \.self) { key in
                    PropertyRow(key: key, value: dict[key] ?? .null)
                }
            } header: {
                SectionLabel(text: "Properties (\(dict.count))", systemImage: "tag")
            }
        } else {
            Section {
                Text("This person has no properties set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionLabel(text: "Properties", systemImage: "tag")
            }
        }
    }

    private func loadEvents() async {
        guard model.isAvailable(.events),
              let client = model.client,
              let projectID = model.projectID,
              let distinctID = queriedDistinctID
        else { return }
        await eventsStore.load(client: client, projectID: projectID, distinctID: distinctID)
    }
}

struct PersonEventRowView: View {
    let event: PersonEvent

    var body: some View {
        DataRow(
            glyph: isPostHogGenerated ? "bolt.horizontal.fill" : "bolt.fill",
            // PostHog's $-prefixed events are SDK exhaust; the warm secondary
            // separates them from the events the team chose to send, which is
            // the distinction worth scanning a timeline for.
            tint: isPostHogGenerated ? Theme.accentWarm : Theme.accent,
            title: event.event,
            subtitle: location,
            // A path is an identifier: monospacing is what lets a column of them
            // be compared without reading each one.
            isSubtitleMonospaced: true,
            accessory: accessory
        )
    }

    private var isPostHogGenerated: Bool { event.event.hasPrefix("$") }

    /// Ages read down the column, so the timestamp is the row's metric rather
    /// than a tertiary aside.
    private var accessory: RowAccessory {
        guard let timestamp = event.timestamp else { return .none }
        return .metric(
            timestamp.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
        )
    }

    /// Prefer the path — the host repeats on every row and buys nothing.
    private var location: String? {
        guard let url = event.currentURL, !url.isEmpty else { return nil }
        guard let path = URL(string: url)?.path, !path.isEmpty else { return url }
        return path
    }
}
