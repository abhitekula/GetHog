import GetHogKit
import GetHogUI
import SwiftUI

/// Where a `.sidebarAdaptable` sidebar row on the TV goes.
///
/// Deliberately **not** `AppTab`: the TV compiles a curated subset of the
/// catalog, and a shell keyed on the full enum would either need a 35-way
/// switch over screens that are not in the binary or a filter that silently
/// disagreed with `project.yml`. Naming the seven destinations that exist is
/// the version of that list a compiler can check.
///
/// `rawValue` is the `@SceneStorage` contract — a restored scene reads back a
/// string — so the spellings are pinned by `TVDestinationTests`.
enum TVDestination: String, CaseIterable, Hashable {
    case dashboards
    case insights
    case events
    case sessions
    case flags
    case ambient
    case settings

    /// The shared tab this destination stands for, for the five product
    /// surfaces plus Settings that have one.
    ///
    /// `nil` for `.ambient`, which is TV-only: there is no phone screen it
    /// corresponds to, because a phone that idles goes dark rather than
    /// becoming a wallboard.
    var tab: AppTab? {
        switch self {
        case .dashboards: .dashboards
        case .insights: .insights
        case .events: .events
        case .sessions: .sessions
        case .flags: .flags
        case .settings: .settings
        case .ambient: nil
        }
    }

    var title: String {
        switch self {
        case .ambient: "Ambient"
        default: tab?.title ?? ""
        }
    }

    var systemImage: String {
        switch self {
        case .ambient: "tv.badge.wifi"
        default: tab?.systemImage ?? "square"
        }
    }

    init(topShelfDestination: TopShelfRoute.Destination) {
        switch topShelfDestination {
        case .dashboards: self = .dashboards
        }
    }
}

/// The tvOS shell.
///
/// The same `.sidebarAdaptable` architecture as the iPad, Mac and Vision
/// shells, over the curated subset rather than `AppTab.sections`. Three
/// deliberate differences, each commented where it happens: the tabs are flat
/// rather than grouped into `TabSection`s; there is no customization binding;
/// and every product tab is hosted below the compact size-class boundary.
struct TVRootView: View {
    @Environment(AppModel.self) private var model

    /// `rawValue`-backed because `@SceneStorage` stores primitives; the
    /// round-trip is what `TVDestinationTests` pins.
    @SceneStorage("selectedTab") private var selectedRaw: String = TVDestination.dashboards.rawValue

    /// Ambient is one TabView child among many, and TabView may retain it after
    /// a sidebar change. The shell therefore owns the wake entitlement: it is
    /// the only layer that can release it before any selection changes.
    @State private var ambientAwake = TVScreenAwake()

    /// Read by several of the ridden roots through
    /// `@Environment(OpenDetails.self)`. None of the six screens here is a
    /// `presentsDetailAsSheet` screen, so nothing hoists a detail into it — but
    /// a missing `@Observable` environment is a crash rather than a nil, so it
    /// is provided regardless.
    @State private var openDetails = OpenDetails()

    #if DEBUG
    @State private var hasAppliedDebugTab = false
    #endif

    private var selected: Binding<TVDestination> {
        Binding(
            get: { TVDestination(rawValue: selectedRaw) ?? .dashboards },
            set: { select($0) }
        )
    }

    /// Changes the selected destination, synchronously releasing a retained
    /// Ambient tab before the sidebar moves away from it. All selection paths
    /// — the TabView binding, DebugLaunch, and Ambient's Select/Menu exit —
    /// use this one transition.
    private func select(_ destination: TVDestination) {
        guard selectedRaw != destination.rawValue else { return }
        if selectedRaw == TVDestination.ambient.rawValue {
            ambientAwake.leave()
            ambientAwake.applyIdleTimerHold()
        }
        selectedRaw = destination.rawValue
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: Theme.Space.m) {
                    BrandConnectingAccent()
                    ProgressView("Connecting…")
                        .controlSize(.large)
                }

            case .onboarding:
                TVKeyEntryView()

            case .ready:
                tabs
            }
        }
        .onOpenURL { url in
            guard let destination = TopShelfRoute.destination(for: url) else { return }
            select(TVDestination(topShelfDestination: destination))
        }
    }

    private var tabs: some View {
        TabView(selection: selected) {
            // Flat `Tab`s, not `TabSection`s. Seven rows need no grouping, and
            // `TabSection` under `.sidebarAdaptable` has a known focus defect on
            // tvOS — the sidebar can swallow the focus that should move into the
            // content. Designing around it costs nothing at this length.
            ForEach(TVDestination.allCases, id: \.self) { destination in
                Tab(destination.title, systemImage: destination.systemImage, value: destination) {
                    content(for: destination)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // No `.tabViewCustomization` and no `@AppStorage("sidebarCustomization")`:
        // `TabViewCustomization` is unavailable on tvOS. The three other shells
        // share that key precisely so one stored arrangement cannot come to mean
        // two things; there is no fourth arrangement to store here, and
        // `SettingsRoot` leaves out the section that would claim otherwise.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .environment(openDetails)
        #if DEBUG
        .onAppear {
            // What makes a per-tab screenshot scriptable. `GETHOG_TAB` carries
            // an `AppTab` raw value for the five product screens and Settings,
            // plus the literal "ambient", which has no `AppTab` to name it.
            guard !hasAppliedDebugTab else { return }
            hasAppliedDebugTab = true
            guard let raw = DebugLaunch.initialTab else { return }
            if let destination = TVDestination(rawValue: raw) {
                select(destination)
            } else if let tab = AppTab(rawValue: raw),
                      let destination = TVDestination.allCases.first(where: { $0.tab == tab }) {
                select(destination)
            }
        }
        #endif
    }

    @ViewBuilder
    private func content(for destination: TVDestination) -> some View {
        switch destination {
        case .ambient:
            TVAmbientView(exit: { select(.dashboards) }, awake: $ambientAwake)
        default:
            NavigationStack {
                root(for: destination)
            }
            // Deliberate, and the one place this shell diverges from the Vision
            // one on purpose rather than by necessity. The seven split-view
            // roots build their **plain list** shape below this boundary, which
            // is the one-column, push-a-detail arrangement a remote can drive.
            // Left to the live environment a TV answers `.regular`, and a
            // `NavigationSplitView` nested inside a `.sidebarAdaptable` sidebar
            // is two sidebars deep — the second one unreachable, because focus
            // has to cross the first to get to it.
            .environment(\.horizontalSizeClass, .compact)
        }
    }

    /// The six-way switch. `TabRootView`'s 35-way one is not compiled into this
    /// target, and could not be: most of its arms name screens the curated
    /// subset leaves out.
    @ViewBuilder
    private func root(for destination: TVDestination) -> some View {
        switch destination {
        case .dashboards: DashboardsRoot()
        case .insights: InsightsRoot()
        case .events: EventsRoot()
        case .sessions: SessionsRoot()
        case .flags: FlagsRoot()
        case .settings: SettingsRoot()
        case .ambient: EmptyView()
        }
    }
}
