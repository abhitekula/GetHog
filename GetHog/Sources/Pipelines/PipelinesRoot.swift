import GetHogKit
import GetHogUI
import SwiftUI

@MainActor
@Observable
final class PipelinesStore {
    var functions: [HogFunction] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<HogFunction> = try await client.send(
                Self.hogFunctionsEndpoint(projectID: projectID)
            )
            functions = page.results
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Transformations then destinations, each alphabetical.
    var groups: [(kind: HogFunctionKind, functions: [HogFunction])] {
        HogFunctionKind.grouped(functions)
    }

    var enabledCount: Int { functions.filter(\.enabled).count }

    static func hogFunctionsEndpoint(projectID: Int, limit: Int = 100) -> Endpoint {
        Endpoint(
            path: "/api/projects/\(projectID)/hog_functions/",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            category: .crud
        )
    }
}

struct PipelinesRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenDetails.self) private var openDetails
    @State private var store = PipelinesStore()
    @State private var search = ""

    /// The open function. A sheet, not a second column: a function's detail is a
    /// short read-only summary, not a column's worth of content — but the sheet
    /// is presented by `RootView`, not here, because a sheet driven from inside
    /// a secondary screen does not survive a size-class change. See
    /// `RootView.presentedDetail`.
    private var selected: HogFunction? {
        get { openDetails[.pipelines] as? HogFunction }
        nonmutating set { openDetails[.pipelines] = newValue.map(AnyHashable.init) }
    }

    var body: some View {
        content
            .navigationTitle("Pipelines")
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $search, prompt: "Search pipelines")
            .screenRefreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.dashboards) {
            LockedCapabilityView(
                capability: .dashboards,
                scope: model.lockedScope(for: .dashboards)
            ) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.functions.isEmpty {
            EmptyStateView(
                title: "Couldn't load pipelines",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.functions.isEmpty && !store.isLoading {
            EmptyStateView(
                title: "No pipelines",
                systemImage: "arrow.triangle.branch",
                message: "A pipeline is either a transformation that rewrites events as they arrive or a destination that forwards them somewhere else. This project has neither, so events land in PostHog and stay there — which is all most projects ever ask of it."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(filteredGroups, id: \.kind) { group in
                Section {
                    ForEach(group.functions) { function in
                        Button {
                            selected = function
                        } label: {
                            PipelineRowView(function: function)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this pipeline's configuration")
                        .pipelinesRowCard()
                    }
                } header: {
                    SectionLabel(text: group.kind.title, systemImage: group.kind.systemImage)
                } footer: {
                    Text(footerText(for: group.kind))
                }
            }

            if filteredGroups.isEmpty {
                Text("No pipelines matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .listRowSpacing(Theme.Space.xs)
        .pageSurface()
        .skeleton(store.isLoading && store.functions.isEmpty)
    }

    private func footerText(for kind: HogFunctionKind) -> String {
        switch kind {
        case .transformation: "Run on every event as it is ingested."
        case .destination: "Forward matching events out of PostHog."
        case .other: "Other pipeline functions in this project."
        }
    }

    private var filteredGroups: [(kind: HogFunctionKind, functions: [HogFunction])] {
        guard !search.isEmpty else { return store.groups }
        return store.groups.compactMap { group in
            let matches = group.functions.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || ($0.description ?? "").localizedCaseInsensitiveContains(search)
            }
            return matches.isEmpty ? nil : (kind: group.kind, functions: matches)
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Row

struct PipelineRowView: View {
    let function: HogFunction

    var body: some View {
        DataRow(
            glyph: function.kind.systemImage,
            // Red when the function is in trouble, so the one row that needs
            // attention is findable in a column of pills that all say "Enabled".
            // The state's own words stay on the footnote line below, so the
            // colour is never carrying the meaning by itself.
            tint: isTroubled ? Theme.Status.critical : kindTint,
            title: function.name,
            subtitle: function.description,
            // Only surfaced when it is bad news; "healthy" on every row would be
            // noise that hides the one row that isn't.
            footnote: isTroubled ? function.state.title : nil,
            accessory: .pill(
                function.statusText,
                function.enabled ? Theme.Status.good : .secondary
            )
        )
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var isTroubled: Bool {
        function.state != .healthy && function.state != .unknown
    }

    /// Transformations and destinations do opposite things to an event, so they
    /// are told apart by tint as well as by section.
    private var kindTint: Color {
        switch function.kind {
        case .transformation: Theme.accent
        case .destination: Theme.accentWarm
        case .other: .secondary
        }
    }

    private var spokenSummary: String {
        var parts = [function.name, function.statusText]
        if let description = function.description { parts.append(description) }
        if function.state != .healthy && function.state != .unknown {
            parts.append(function.state.title)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

struct PipelineDetailSheet: View {
    let function: HogFunction
    let webURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailSheetContainer {
            List {
                Section {
                    LabeledContent("Status") { Text(function.statusText) }
                    LabeledContent("Kind") { Text(function.kind.title) }
                    // The raw type is shown as well as the group, because
                    // PostHog distinguishes `internal_destination` from
                    // `destination` and only the raw value matches the console.
                    LabeledContent("Type") {
                        Text(function.type).font(.caption.monospaced())
                    }
                    LabeledContent("Health") { Text(function.state.title) }
                    if let updated = function.updatedAt {
                        LabeledContent("Updated") {
                            Text(updated, format: .relative(presentation: .named))
                        }
                    }
                } header: {
                    SectionLabel(text: "Configuration", systemImage: function.kind.systemImage)
                }

                if let description = function.description {
                    Section {
                        Text(description).font(.callout)
                    } header: {
                        SectionLabel(text: "Description", systemImage: "text.alignleft")
                    }
                }

                Section {
                    if let webURL {
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    }
                } header: {
                    SectionLabel(text: "Editing", systemImage: "pencil")
                } footer: {
                    // Said plainly: this screen reads configuration. Editing Hog
                    // source, inputs or filters on a phone would be a worse
                    // version of the console's editor, not a smaller one.
                    Text("GetHog shows how this pipeline is configured. Editing its code, inputs and filters stays in the PostHog web console.")
                }
            }
            .pageSurface()
            .navigationTitle(function.name)
            .navigationBarTitleDisplayMode(.inline)
            // Sheet chrome, and only the sheet has it: on the Mac this detail is
            // pushed, where Done would duplicate the Back button.
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }
}

/// Best-effort deep link. The console groups functions by the same two buckets,
/// so an unrecognised type lands on the pipeline overview rather than a guessed
/// URL.
///
/// File scope rather than a method on the root: the sheet that needs it is
/// presented by `RootView`, one level above this screen. See
/// `RootView.presentedDetail`.
func pipelineWebPath(for function: HogFunction) -> String {
    switch function.kind {
    case .transformation: "pipeline/transformations"
    case .destination: "pipeline/destinations"
    case .other: "pipeline"
    }
}

// MARK: - Row chrome
//
// File-private so concurrent work on other screens can't collide with the name.

private extension View {
    /// The list treatment from the dashboards screen: every row is its own card
    /// on the page ground, with the system separator suppressed because the gap
    /// between cards already does that work.
    func pipelinesRowCard() -> some View {
        listRowBackground(
            Theme.cardBackground
                .clipShape(.rect(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.vertical, 1)
        )
        .listRowSeparator(.hidden)
    }
}
