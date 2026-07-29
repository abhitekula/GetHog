import GetHogKit
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

    func load(client: PostHogClient, projectID: Int, distinctID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: QueryResponse = try await client.send(
                PostHogAPI.hogql(projectID: projectID, sql: Self.query(distinctID: distinctID))
            )
            events = response.rows.compactMap(PersonEvent.init(row:))
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
        LIMIT 50
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

            if !person.distinctIDs.isEmpty {
                Section("Distinct IDs (\(person.distinctIDs.count))") {
                    ForEach(person.distinctIDs, id: \.self) { distinctID in
                        Text(distinctID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = distinctID
                                } label: {
                                    Label("Copy distinct ID", systemImage: "doc.on.doc")
                                }
                            }
                    }
                }
            }

            recentEventsSection
            propertiesSection
        }
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
            Text("Recent events")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let distinctID = queriedDistinctID, person.distinctIDs.count > 1 {
                    Text("Up to 50 most recent events for \(distinctID) only — this person has \(person.distinctIDs.count) distinct IDs.")
                } else {
                    Text("Up to 50 most recent events.")
                }
                FreshnessLabel(date: eventsStore.loadedAt)
            }
        }
    }

    // MARK: - Properties

    @ViewBuilder
    private var propertiesSection: some View {
        if let properties = person.properties, case .object(let dict) = properties, !dict.isEmpty {
            Section("Properties (\(dict.count))") {
                ForEach(dict.keys.sorted(), id: \.self) { key in
                    PropertyRow(key: key, value: dict[key] ?? .null)
                }
            }
        } else {
            Section("Properties") {
                Text("This person has no properties set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                // PostHog's $-prefixed events read as code, so they're monospaced.
                Text(event.event)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                Spacer()
                if let timestamp = event.timestamp {
                    Text(timestamp, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if let location {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Prefer the path — the host repeats on every row and buys nothing.
    private var location: String? {
        guard let url = event.currentURL, !url.isEmpty else { return nil }
        guard let path = URL(string: url)?.path, !path.isEmpty else { return url }
        return path
    }
}
