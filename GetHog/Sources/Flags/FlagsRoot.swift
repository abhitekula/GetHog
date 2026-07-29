import GetHogKit
import SwiftUI

/// How a flag is filed in the list. Archived wins over on/off, because an
/// archived flag isn't something you reason about as "currently live".
enum FlagStatusGroup: String, CaseIterable, Identifiable {
    case enabled, disabled, archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .archived: "Archived"
        }
    }

    /// Text first: the pill is the accessible carrier of status, the tint is
    /// only reinforcement.
    var tint: Color {
        switch self {
        case .enabled: Theme.Status.good
        case .disabled, .archived: Color.secondary
        }
    }
}

@MainActor
@Observable
final class FlagsStore {
    var flags: [FeatureFlag] = []
    var isLoading = false
    var error: String?
    var loadedAt: Date?

    /// Writes and their optimistic state live here so the list and the detail
    /// view agree instantly without either owning the other.
    let toggles = FlagToggleController()

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<FeatureFlag> = try await client.send(
                PostHogAPI.featureFlags(projectID: projectID)
            )
            flags = page.results
                .filter { !$0.deleted }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            toggles.reconcile(with: flags)
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    func group(for flag: FeatureFlag) -> FlagStatusGroup {
        if flag.archived { return .archived }
        return toggles.effectiveActive(flag) ? .enabled : .disabled
    }

    func flags(in group: FlagStatusGroup, search: String) -> [FeatureFlag] {
        flags.filter { self.group(for: $0) == group && matches($0, search: search) }
    }

    func matchCount(search: String) -> Int {
        flags.filter { matches($0, search: search) }.count
    }

    private func matches(_ flag: FeatureFlag, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        return flag.key.localizedCaseInsensitiveContains(search)
            || (flag.name ?? "").localizedCaseInsensitiveContains(search)
    }
}

struct FlagsRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = FlagsStore()
    @State private var selection: FeatureFlag?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            content
                .navigationTitle("Flags")
                .toolbar { ProjectSwitcher() }
                .searchable(text: $search, prompt: "Search flag key or name")
                .refreshable { await load() }
                .task(id: model.projectID) { await load() }
        } detail: {
            if let selection {
                FlagDetailView(flag: selection, controller: store.toggles)
                    .id(selection.id)
            } else {
                ContentUnavailableView(
                    "Select a flag",
                    systemImage: "flag",
                    description: Text("Pick a flag to see its release conditions.")
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable(.flags) {
            LockedCapabilityView(capability: .flags, scope: model.lockedScope(for: .flags)) {
                Task { await model.refreshCapabilities() }
            }
        } else if let error = store.error, store.flags.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load flags", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if store.flags.isEmpty && !store.isLoading {
            ContentUnavailableView(
                "No feature flags",
                systemImage: "flag",
                description: Text("This project doesn't have any feature flags yet.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(FlagStatusGroup.allCases) { group in
                let items = store.flags(in: group, search: search)
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { flag in
                            NavigationLink(value: flag) {
                                FlagRowView(flag: flag, group: group)
                            }
                        }
                    }
                }
            }
            if let loadedAt = store.loadedAt {
                FreshnessLabel(date: loadedAt)
                    .listRowBackground(Color.clear)
            }
        }
        .skeleton(store.isLoading && store.flags.isEmpty)
        .overlay {
            if !search.isEmpty && store.matchCount(search: search) == 0 {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

/// One flag in the list.
///
/// Read-only by design: there is no swipe action and no inline switch, because a
/// list is exactly the place where a production flag gets flipped by accident.
struct FlagRowView: View {
    let flag: FeatureFlag
    let group: FlagStatusGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(flag.key)
                    .font(.body.monospaced())
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusPill(text: group.title, tint: group.tint)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Only shown when it adds something: `displayName` falls back to the key.
    private var subtitle: String? {
        let name = flag.displayName
        return name == flag.key ? nil : name
    }

    private var facts: [String] {
        var parts: [String] = []
        if let rollout = flag.rolloutPercentage {
            parts.append("\(FlagFormat.percent(rollout)) rollout")
        }
        if flag.isMultivariate {
            parts.append("\(flag.variants.count) variants")
        }
        return parts
    }

    private var accessibilityDescription: String {
        ([flag.key, group.title] + (subtitle.map { [$0] } ?? []) + facts)
            .joined(separator: ", ")
    }
}

enum FlagFormat {
    /// Rollouts arrive as 0…100, not 0…1.
    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }
}
