import GetHogKit
import GetHogUI
import SwiftUI

// MARK: - List

/// Recent summaries produced by PostHog Replay Vision.
struct SessionSummariesRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = SessionSummariesStore()
    @State private var search = ""

    private var requestAuthority: ResourceRequestAuthority? {
        guard let client = model.client,
              let projectID = model.projectID,
              let authSessionID = model.authSessionID
        else { return nil }
        return .init(
            projectID: projectID,
            region: client.region,
            authSessionID: authSessionID
        )
    }

    private var selection: Binding<ReplayVisionSummaryDigest?> {
        Binding(
            get: { openDetails[.sessionSummaries] as? ReplayVisionSummaryDigest },
            set: { openDetails[.sessionSummaries] = $0.map(AnyHashable.init) }
        )
    }

    var body: some View {
        content
            .navigationTitle("Summaries")
            .toolbar {
                ProjectSwitcher()
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .projectSubtitle()
            #if !os(tvOS)
            .searchable(text: $search, prompt: "Search summaries")
            #endif
            .screenRefreshable { await load() }
            .onChange(of: requestAuthority, initial: true) { _, authority in
                store.prepare(authority: authority)
            }
            .task(id: requestAuthority) { await load() }
            .navigationDestination(item: selection) { row in
                ReplayVisionSummaryDetailView(row: row)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.sessions) {
            LockedCapabilityView(capability: .sessions, scope: model.lockedScope(for: .sessions)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.rows.isEmpty {
            EmptyStateView(
                title: "Couldn't load summaries",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if visible.isEmpty && !store.isLoading {
            EmptyStateView(
                title: store.rows.isEmpty ? "No summaries yet" : "Nothing under this filter",
                systemImage: "sparkles.rectangle.stack",
                message: store.rows.isEmpty
                    ? "Generate a summary from a session recording to see it here."
                    : "Clear the search or friction filter to see the rest."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: selection) {
            Section {
                ForEach(visible) { row in
                    NavigationLink(value: row) {
                        ReplayVisionSummaryRow(row: row)
                    }
                    .listRowBackground(cardRowBackground)
                    .listRowSeparator(.hidden)
                }
            } header: {
                SectionLabel(
                    text: "Replay Vision summaries",
                    systemImage: "text.append",
                    productMark: .session
                )
            } footer: {
                Text("Showing the most recent \(SessionSummariesStore.limit) summaries.")
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listRowSpacing(Theme.Space.xs)
        .accessibilityIdentifier("gethog.session-summaries-list")
        .pageSurface()
        .sparseCollectionSurface()
        .skeleton(store.isLoading && store.rows.isEmpty)
    }

    private var visible: [ReplayVisionSummaryDigest] {
        store.rows.filter { row in
            guard !store.frictionOnly || row.hasFriction else { return false }
            guard !search.isEmpty else { return true }
            return [row.title, row.summary, row.intent, row.outcome, row.id]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Toggle(
                "With friction only",
                isOn: Binding(
                    get: { store.frictionOnly },
                    set: { store.frictionOnly = $0 }
                )
            )
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter summaries")
    }

    private var cardRowBackground: some View {
        Theme.cardBackground
            .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
            .padding(.vertical, PlatformPresentationMetrics.listCardVerticalInset)
    }

    private func load() async {
        guard let client = model.client, let authority = requestAuthority else { return }
        await store.load(client: client, authority: authority)
    }
}

// MARK: - Row

struct ReplayVisionSummaryRow: View {
    let row: ReplayVisionSummaryDigest

    var body: some View {
        DataRow(
            glyph: row.hasFriction ? "exclamationmark.circle" : "text.append",
            tint: row.hasFriction ? Theme.accentWarm : Theme.accent,
            title: row.title.isEmpty ? (row.cardSummary ?? "Session summary") : row.title,
            subtitle: row.title.isEmpty || row.summary.isEmpty ? nil : row.summary,
            footnote: footnote,
            subtitleLineLimit: 2,
            accessory: .none
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var footnote: String {
        var parts: [String] = []
        if row.hasFriction { parts.append("Friction") }
        if let completedAt = row.completedAt {
            parts.append(completedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
        }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        var parts = [row.title.isEmpty ? (row.cardSummary ?? "Session summary") : row.title]
        if !row.summary.isEmpty { parts.append(row.summary) }
        if row.hasFriction { parts.append("Friction reported") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

struct ReplayVisionSummaryDetailView: View {
    let row: ReplayVisionSummaryDigest

    @Environment(AppModel.self) private var model

    private var replayWebURL: URL? {
        model.webURL(path: "replay/\(row.id)")
    }

    var body: some View {
        PageScaffold {
            summaryCard
            watchCard
            FreshnessLabel(date: row.completedAt)
        }
        .navigationTitle("Session summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if !os(tvOS)
            if let replayWebURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: replayWebURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share a link to this session")
                }
            }
            #endif
        }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Session summary", systemImage: "text.append")

                if !row.title.isEmpty {
                    Text(row.title).font(.headline)
                }
                if !row.summary.isEmpty {
                    Text(row.summary)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.intent.isEmpty { detail("Intent", row.intent) }
                if !row.outcome.isEmpty { detail("Outcome", row.outcome) }

                if row.hasFriction {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Label("Friction", systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Status.ink(for: Theme.accentWarm))
                        ForEach(row.frictionPoints, id: \.self) { point in
                            Text(point)
                                .font(.caption)
                                .foregroundStyle(Theme.Ink.secondary)
                        }
                    }
                }

                if let model = row.model, !model.isEmpty {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var watchCard: some View {
        #if !os(tvOS)
        if let replayWebURL {
            Card {
                Link(destination: replayWebURL) {
                    Label("Watch this session in PostHog", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        #endif
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Ink.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
