import GetHogKit
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
    @State private var store = PipelinesStore()
    @State private var selected: HogFunction?
    @State private var search = ""

    var body: some View {
        // NavigationStack with a sheet, not a split view: a function's detail is
        // a short read-only summary, not a second column's worth of content.
        NavigationStack {
            content
                .navigationTitle("Pipelines")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search pipelines")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
        }
        .sheet(item: $selected) { function in
            PipelineDetailSheet(
                function: function,
                webURL: model.webURL(path: webPath(for: function))
            )
        }
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
            ContentUnavailableView {
                Label("Couldn't load pipelines", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.functions.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No pipelines",
                systemImage: "arrow.triangle.branch",
                description: Text(
                    "This project has no transformations or destinations configured."
                )
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
                    }
                } header: {
                    Label(group.kind.title, systemImage: group.kind.systemImage)
                } footer: {
                    Text(footerText(for: group.kind))
                }
            }

            if filteredGroups.isEmpty {
                Text("No pipelines matched “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            FreshnessLabel(date: store.loadedAt)
                .listRowBackground(Color.clear)
        }
        .skeleton(store.isLoading && store.functions.isEmpty)
    }

    private func footerText(for kind: HogFunctionKind) -> String {
        switch kind {
        case .transformation: "Run on every event as it is ingested."
        case .destination: "Forward matching events out of PostHog."
        case .other: "Other pipeline functions in this project."
        }
    }

    /// Best-effort deep link. The console groups functions by the same two
    /// buckets, so an unrecognised type lands on the pipeline overview rather
    /// than a guessed URL.
    private func webPath(for function: HogFunction) -> String {
        switch function.kind {
        case .transformation: "pipeline/transformations"
        case .destination: "pipeline/destinations"
        case .other: "pipeline"
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(function.name)
                    .font(.body)
                    .lineLimit(2)

                Spacer(minLength: 8)

                StatusPill(
                    text: function.statusText,
                    tint: function.enabled ? Theme.Status.good : .secondary
                )
            }

            if let description = function.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Only surfaced when it is bad news; "healthy" on every row would be
            // noise that hides the one row that isn't.
            if function.state != .healthy && function.state != .unknown {
                Text(function.state.title)
                    .font(.caption2)
                    .foregroundStyle(Theme.Status.critical)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
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
        NavigationStack {
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
                }

                if let description = function.description {
                    Section("Description") {
                        Text(description).font(.callout)
                    }
                }

                Section {
                    if let webURL {
                        Link(destination: webURL) {
                            Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        }
                    }
                } header: {
                    Text("Editing")
                } footer: {
                    // Said plainly: this screen reads configuration. Editing Hog
                    // source, inputs or filters on a phone would be a worse
                    // version of the console's editor, not a smaller one.
                    Text("GetHog shows how this pipeline is configured. Editing its code, inputs and filters stays in the PostHog web console.")
                }
            }
            .navigationTitle(function.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
