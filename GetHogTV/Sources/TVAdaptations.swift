import GetHogKit
import GetHogUI
import SwiftUI

// The tvOS twin of every API the *shared* screens name that this platform does
// not have. One rule decides what belongs here, and it is `MacAdaptations`':
// the iOS call sites stay byte-identical, and the tvOS meaning is either the
// honest equivalent or an honest no-op. Anything that needs real behaviour
// later replaces its shim, not its call sites.
//
// No `#if` inside — the file only compiles into this target. Module-local
// declarations shadow the imported-but-unavailable SwiftUI and UIKit symbols,
// which is the same mechanism `MacAdaptations` already relies on for
// `EditButton`.
//
// Two things are deliberately **not** twinned. There is no `UIPasteboard` shim
// and no `ShareLink` shim, because a Copy button that copies nothing and a
// Share button that shares nothing are lies rather than no-ops; those sites are
// seamed out of the shared files instead, so they are absent from the focus
// chain rather than present and inert.

// MARK: - List conveniences

extension View {
    /// tvOS lists draw no row separators, so there is none to hide.
    func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        self
    }

    /// Row spacing is an inset-grouped affordance a tvOS list does not have; it
    /// spaces its own focusable rows.
    func listRowSpacing(_ spacing: CGFloat?) -> some View { self }

    /// The TV navigation bar has exactly one title treatment, so there is
    /// nothing to choose between.
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }
}

/// Shadow of SwiftUI's `NavigationBarItem`, carrying just the enum the shared
/// call sites name.
///
/// The type exists on tvOS, which is why this was nearly not needed — but
/// `.large` is marked unavailable there (measured: `FlagDetailView:75` picks
/// between `.inline` and `.large` by size class), so the real enum cannot spell
/// what those call sites say. Same treatment the Mac's twin gives it.
enum NavigationBarItem {
    enum TitleDisplayMode {
        case automatic, inline, large
    }
}

extension ListStyle where Self == GroupedListStyle {
    /// `InsetListStyle` — the type, not merely the static — is unavailable on
    /// tvOS, so this cannot mirror the Mac's twin. Grouped is the platform's
    /// own settings-list shape, which is what the call sites are asking for.
    static var insetGrouped: GroupedListStyle { GroupedListStyle() }
}

/// Shadow of the iOS-only control. There is no edit mode on tvOS and no
/// reordering to enter one for, so the button contributes nothing.
struct EditButton: View {
    var body: some View { EmptyView() }
}

// MARK: - Text selection

/// Shadow of the unavailable selectability members, so `.textSelection(.enabled)`
/// at a shared call site resolves against the overload below.
///
/// There is no pointer and no cursor to select text with on this platform, so
/// the modifier's absence loses nothing that exists here.
struct TVTextSelectability {
    static let enabled = TVTextSelectability()
    static let disabled = TVTextSelectability()
}

extension View {
    func textSelection(_ selectability: TVTextSelectability) -> some View { self }
}

// MARK: - Search field placement

extension SearchFieldPlacement {
    /// The drawer is an iOS navigation-bar shape. tvOS puts the search field
    /// where `.automatic` lands it, which is the only place it goes.
    enum DrawerDisplayMode {
        case automatic, always
    }

    static func navigationBarDrawer(displayMode: DrawerDisplayMode) -> SearchFieldPlacement {
        .automatic
    }
}

// MARK: - Disclosure

/// Focus-driven expander standing in for the unavailable control.
///
/// A `Button` toggles the expansion rather than the content simply always being
/// open: a remote has to be able to *reach* the disclosure, and a row that is
/// permanently expanded is one the user cannot collapse to get past. The
/// chevron rotates so the state is told by more than position.
struct DisclosureGroup<Label: View, Content: View>: View {
    private let content: () -> Content
    private let label: () -> Label
    private let external: Binding<Bool>?
    @State private var internalExpansion: Bool
    @FocusState private var disclosureFocused: Bool

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.external = isExpanded
        self.content = content
        self.label = label
        _internalExpansion = State(initialValue: isExpanded.wrappedValue)
    }

    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.external = nil
        self.content = content
        self.label = label
        _internalExpansion = State(initialValue: false)
    }

    private var isExpanded: Bool { external?.wrappedValue ?? internalExpansion }

    var body: some View {
        Button {
            if let external {
                external.wrappedValue.toggle()
            } else {
                internalExpansion.toggle()
            }
        } label: {
            HStack {
                label()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // The label beside it already says what this expands.
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    // A low accent wash keeps every explicit ink in the shared
                    // card readable. The native TV button focus surface was
                    // nearly white, so pale labels vanished across the entire
                    // enclosing List row whenever this disclosure took focus.
                    .fill(disclosureFocused ? Theme.accent.opacity(0.14) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .stroke(disclosureFocused ? Theme.accent : .clear, lineWidth: 2)
            }
        }
        // `.plain` removes the native bright slab; the accent wash and outline
        // above replace it with a bounded focus state on the control itself.
        // The control remains a real Button, so Select and accessibility keep
        // the same expand/collapse behaviour.
        .buttonStyle(.plain)
        .focused($disclosureFocused)
        .focusEffectDisabled()
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

        if isExpanded {
            content()
        }
    }
}

// MARK: - Excluded-file twins

/// No-op twin of the iOS home-screen quick actions (the real one is
/// `App/QuickActions.swift`, which this target does not compile). tvOS has no
/// icon shortcut menu; the Top Shelf is the platform's equivalent surface and
/// it reads the App Group snapshot rather than a recorded visit.
@MainActor
enum QuickActions {
    static func recordPinnedDashboard(id: Int, title: String, projectID: Int) {}
    static func recordVisit(_ link: PostHogLink, title: String, projectID: Int) {}
    static func refresh(projectID: Int?) {}
    static func clear() {}
}

/// Twin of the iOS `BGTaskScheduler` wrapper (excluded from this target).
///
/// tvOS *does* have BackgroundTasks, so this could become real. Nothing in this
/// shell schedules a wake today, so there is nothing to cancel and `cancel()`
/// is a true no-op rather than a stubbed-out one — `AppModel.signOut` calls it
/// on every platform and needs to know nothing about any of them.
@MainActor
enum BackgroundRefresh {
    static func cancel() {}
}

/// No-op twin of the Siri/Shortcuts donations (`Intents/` is not compiled into
/// this target). tvOS has App Intents, but nothing on this platform surfaces a
/// donated shortcut, and donating an action no suggestion can offer teaches the
/// system a lie.
@MainActor
enum IntentDonations {
    static func dashboardOpened(_ dashboard: DashboardSummary) {}
    static func metricRead(_ insight: Insight) {}
    static func flagSet(
        _ flag: FeatureFlag,
        enabled: Bool,
        scope: FlagQuickToggle.Scope,
        expectedAuthSessionID: UUID
    ) {}
}

/// Twin of the out-of-process project handshake. Nothing runs out of process
/// against this app on tvOS — no intents, no widgets — so there is no second
/// writer for the app to adopt a selection from, and `nil` is the true answer
/// rather than a placeholder.
enum IntentDependencies {
    static func storedProjectID() -> Int? { nil }
    static func persistSelectedProject(_ id: Int) {}
}

/// Twin of the Spotlight indexer. `CoreSpotlight` exists on tvOS, but the
/// platform has no Spotlight surface to search from, so indexing would spend
/// three organisation-wide API calls to fill an index nobody can query.
enum SpotlightIndexer {
    static func reindex(projectID: Int) async {}
}

/// Case-for-case shadow of `Intents/IntentDependencies.swift`'s enum, because
/// `App/LinkInbox.swift` — which this target *does* compile — extends it and
/// switches over every case.
///
/// Only the shape is reproduced. Nothing on tvOS writes one of these, so the
/// static request/consume plumbing the real type carries has no caller here.
enum IntentNavigationTarget: Equatable, Sendable {
    case dashboard(id: Int)
    case insight(id: Int)
    case featureFlag(id: Int)
    case events(search: String)
    case search(term: String)
}

// MARK: - Player twin

/// There is no replay player on tvOS: `ReplayPlayerView` imports WebKit, and
/// WebKit is not in the tvOS SDK at all, so that file is excluded from the
/// target rather than seamed. `SessionDetailView` embeds `TVReplayTimelineView`
/// in its place.
///
/// This type still has to exist, because `SessionSummaryCard` and
/// `SessionTimelineView` read `player.isReady` for their `canSeek`, and
/// `retryReplay()` calls `resetForRetry()`. `isReady` is a constant `false`,
/// which is the truth: nothing can seek, so every seek affordance on those
/// screens stays honestly disabled rather than offering a jump that does
/// nothing.
@MainActor
@Observable
final class ReplayPlayerController {
    let isReady = false
    func seek(to offset: TimeInterval, resume: Bool) {}
    func resetForRetry() {}
}
