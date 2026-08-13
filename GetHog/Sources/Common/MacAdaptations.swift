#if os(macOS)
import AppKit
import SwiftUI

// The Mac twin of every iOS-only API this codebase names from *shared* files.
// One rule decides what belongs here: the iOS call sites stay byte-identical,
// and the Mac meaning is either the honest equivalent (pasteboard, placements)
// or an honest no-op (iOS-only chrome with no Mac equivalent). Anything that
// needs real Mac behavior later replaces its shim, not its call sites.

// MARK: - Size classes

/// Shadow of the iOS-only type, driven by the Mac window's real content width.
enum UserInterfaceSizeClass: Equatable {
    case compact, regular
}

private struct MacHorizontalSizeClassKey: EnvironmentKey {
    static let defaultValue: UserInterfaceSizeClass? = .regular
}

extension EnvironmentValues {
    var horizontalSizeClass: UserInterfaceSizeClass? {
        get { self[MacHorizontalSizeClassKey.self] }
        set { self[MacHorizontalSizeClassKey.self] = newValue }
    }
}

enum MacWindowLayout {
    static let compactContentWidth: CGFloat = 720

    static func sizeClass(forContentWidth width: CGFloat) -> UserInterfaceSizeClass {
        width < compactContentWidth ? .compact : .regular
    }
}

/// Stable encoding for the source-list groups a person leaves expanded.
/// Unknown ids are filtered through `AppTab.sections`, so renamed or removed
/// sections cannot return as invisible persisted state.
struct MacSidebarExpansion: Equatable {
    static let storageKey = "macSidebarExpandedSections"
    static let defaultExpandedSectionIDs: Set<String> = ["Analyze", "Monitor"]

    private(set) var expandedSectionIDs: Set<String>

    init(persistedValue: String?) {
        guard let persistedValue else {
            expandedSectionIDs = Self.defaultExpandedSectionIDs
            return
        }

        let validIDs = Set(AppTab.sections.map(\.id))
        expandedSectionIDs = Set(
            persistedValue
                .split(separator: ",")
                .map(String.init)
                .filter(validIDs.contains)
        )
    }

    static var defaultPersistedValue: String {
        Self(expandedSectionIDs: defaultExpandedSectionIDs).persistedValue
    }

    var persistedValue: String {
        AppTab.sections
            .map(\.id)
            .filter(expandedSectionIDs.contains)
            .joined(separator: ",")
    }

    func contains(_ sectionID: String) -> Bool {
        expandedSectionIDs.contains(sectionID)
    }

    mutating func setExpanded(_ isExpanded: Bool, for sectionID: String) {
        guard AppTab.sections.contains(where: { $0.id == sectionID }) else { return }
        if isExpanded {
            expandedSectionIDs.insert(sectionID)
        } else {
            expandedSectionIDs.remove(sectionID)
        }
    }

    mutating func reset() {
        expandedSectionIDs = Self.defaultExpandedSectionIDs
    }

    /// Makes a programmatic destination a real sidebar selection.
    ///
    /// Clicking a row can only select an already-visible row. Go, a link,
    /// restoration, and debug launch do not have that precondition, so their
    /// shared open path expands the one owner before asking the source list to
    /// reveal the stable tab id. Inserting preserves every unrelated choice.
    @discardableResult
    mutating func reconcileOpening(_ tab: AppTab) -> AppTab {
        if let sectionID = tab.sidebarSectionID {
            setExpanded(true, for: sectionID)
        }
        return tab
    }

    private init(expandedSectionIDs: Set<String>) {
        self.expandedSectionIDs = expandedSectionIDs
    }
}

/// Per-window truth for the Mac shell's rendered source list and its command.
/// Keeping the action title on the same value makes the invalid combinations
/// (visible + "Show", hidden + "Hide") unrepresentable.
enum MacSidebarPresentation: String, Equatable {
    case visible
    case hidden

    var commandTitle: String {
        switch self {
        case .visible: "Hide Sidebar"
        case .hidden: "Show Sidebar"
        }
    }

    var toggled: Self {
        self == .visible ? .hidden : .visible
    }
}

/// One shell-wide width policy for the Mac source list. Product destinations
/// never participate: every selected root receives the remainder proposed by
/// `MacSidebarShell`.
enum MacSidebarShellLayout {
    static let minimumWidth: CGFloat = 190
    static let defaultWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 260
    static let visibleSeparatorWidth: CGFloat = 1
    static let separatorHitWidth: CGFloat = 8
    static let keyboardResizeStep: CGFloat = 10

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }

    /// The width that chooses a shared root's navigation topology. It is the
    /// detail width the root receives with the source list shown, even while
    /// that list is temporarily hidden. A visibility command can therefore
    /// reveal canvas without crossing compact/regular branches and rebuilding
    /// the selected root; resizing the window or divider still can.
    static func adaptiveDetailWidth(
        forShellWidth shellWidth: CGFloat,
        preferredSidebarWidth: CGFloat
    ) -> CGFloat {
        max(
            0,
            shellWidth
                - clampedWidth(preferredSidebarWidth)
                - visibleSeparatorWidth
        )
    }

    static func sourceListWidth(
        presentation: MacSidebarPresentation,
        preferredWidth: CGFloat,
        resizeTranslation: CGFloat = 0
    ) -> CGFloat {
        guard presentation == .visible else { return 0 }
        return clampedWidth(preferredWidth + resizeTranslation)
    }

    static func separatorWidth(presentation: MacSidebarPresentation) -> CGFloat {
        presentation == .visible ? visibleSeparatorWidth : 0
    }

    static func isRevealable(sourceListWidth: CGFloat) -> Bool {
        sourceListWidth >= minimumWidth - 1
    }
}

/// Resizable two-pane structure for a regular Mac product root.
///
/// `NavigationSplitView` treats its column-width modifiers as preferences and
/// can compress a split nested inside the app-wide source-list shell below the
/// declared minimum. This split gives pointer drag and accessibility adjustment
/// the same scene binding, so remounting the selected root cannot reset one path.
struct MacRegularListDetailSplit<Sidebar: View, Detail: View>: View {
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    @Binding private var preferredListWidth: Double
    let minimumListWidth: CGFloat
    let idealListWidth: CGFloat
    let maximumListWidth: CGFloat
    private let sidebar: Sidebar
    private let detail: Detail
    @GestureState private var resizeTranslation: CGFloat = 0

    init(
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        minimumListWidth: CGFloat,
        idealListWidth: CGFloat,
        maximumListWidth: CGFloat,
        preferredListWidth: Binding<Double>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        _preferredListWidth = preferredListWidth
        self.minimumListWidth = minimumListWidth
        self.idealListWidth = idealListWidth
        self.maximumListWidth = maximumListWidth
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        let listWidth = MacRegularListWidth.clamped(
            preferredListWidth + Double(resizeTranslation),
            defaultWidth: idealListWidth,
            minimumWidth: minimumListWidth,
            maximumWidth: maximumListWidth
        )

        HStack(spacing: 0) {
            sidebar
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)

            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .accessibilityHidden(true)

                Color.clear
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($resizeTranslation) { value, state, _ in
                                state = value.translation.width
                            }
                            .onEnded { value in
                                preferredListWidth = Double(
                                    MacRegularListWidth.dragged(
                                        preferredListWidth,
                                        translation: value.translation.width,
                                        defaultWidth: idealListWidth,
                                        minimumWidth: minimumListWidth,
                                        maximumWidth: maximumListWidth
                                    )
                                )
                            }
                    )
                    .accessibilityHidden(true)

                MacRegularDividerAccessibilityProxy(
                    identifier: accessibilityIdentifier,
                    label: accessibilityLabel,
                    minimumWidth: minimumListWidth,
                    maximumWidth: maximumListWidth,
                    width: Binding(
                        get: { Double(listWidth) },
                        set: { value in
                            preferredListWidth = Double(
                                MacRegularListWidth.clamped(
                                    value,
                                    defaultWidth: idealListWidth,
                                    minimumWidth: minimumListWidth,
                                    maximumWidth: maximumListWidth
                                )
                            )
                        }
                    )
                )
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .frame(width: 1)
            .frame(maxHeight: .infinity)

            detail
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
    }
}

/// A semantic control only: SwiftUI owns the divider's pixels and pointer
/// gesture, while AppKit supplies the Mac accessibility contract SwiftUI drops
/// from narrow adjustable overlays on Tahoe.
private struct MacRegularDividerAccessibilityProxy: NSViewRepresentable {
    let identifier: String
    let label: String
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    @Binding var width: Double

    func makeNSView(context: Context) -> MacRegularDividerAccessibilitySlider {
        MacRegularDividerAccessibilitySlider()
    }

    func updateNSView(
        _ slider: MacRegularDividerAccessibilitySlider,
        context: Context
    ) {
        slider.configure(
            identifier: identifier,
            label: label,
            value: width,
            minimumValue: Double(minimumWidth),
            maximumValue: Double(maximumWidth),
            increment: MacRegularListWidth.accessibilityAdjustment,
            onChange: { width = $0 }
        )
    }
}

private final class MacRegularDividerAccessibilitySlider: NSSlider {
    private var increment = MacRegularListWidth.accessibilityAdjustment
    private var onChange: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isContinuous = true
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isContinuous = true
        setAccessibilityElement(true)
    }

    func configure(
        identifier: String,
        label: String,
        value: Double,
        minimumValue: Double,
        maximumValue: Double,
        increment: Double,
        onChange: @escaping (Double) -> Void
    ) {
        minValue = minimumValue
        maxValue = maximumValue
        doubleValue = min(max(value, minimumValue), maximumValue)
        self.increment = increment
        self.onChange = onChange
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        updateAccessibilityNumericContract()
        updateAccessibilityValueDescription()
    }

    override func draw(_ dirtyRect: NSRect) {}

    override func accessibilityRole() -> NSAccessibility.Role? {
        .slider
    }

    override func accessibilityPerformIncrement() -> Bool {
        applyAccessibilityAdjustment(increment)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        applyAccessibilityAdjustment(-increment)
        return true
    }

    private func applyAccessibilityAdjustment(_ delta: Double) {
        doubleValue = min(max(doubleValue + delta, minValue), maxValue)
        updateAccessibilityNumericContract()
        updateAccessibilityValueDescription()
        onChange?(doubleValue)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func updateAccessibilityNumericContract() {
        setAccessibilityValue(NSNumber(value: doubleValue))
        setAccessibilityMinValue(NSNumber(value: minValue))
        setAccessibilityMaxValue(NSNumber(value: maxValue))
    }

    private func updateAccessibilityValueDescription() {
        setAccessibilityValueDescription("\(Int(doubleValue)) points")
    }
}

enum MacRegularListWidth {
    static let accessibilityAdjustment: Double = 10

    static func clamped(
        _ width: Double,
        defaultWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat {
        guard width.isFinite else {
            return min(max(defaultWidth, minimumWidth), maximumWidth)
        }
        return min(max(CGFloat(width), minimumWidth), maximumWidth)
    }

    static func dragged(
        _ width: Double,
        translation: CGFloat,
        defaultWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat {
        let renderedWidth = clamped(
            width,
            defaultWidth: defaultWidth,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth
        )
        return clamped(
            Double(renderedWidth + translation),
            defaultWidth: defaultWidth,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth
        )
    }

    static func adjusted(
        _ width: Double,
        direction: AccessibilityAdjustmentDirection,
        defaultWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat {
        let delta: Double
        switch direction {
        case .increment: delta = accessibilityAdjustment
        case .decrement: delta = -accessibilityAdjustment
        @unknown default: delta = 0
        }
        return clamped(
            width + delta,
            defaultWidth: defaultWidth,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth
        )
    }
}

/// Serialized by the owning scene, not app defaults, so independently restored
/// windows and product destinations never borrow each other's divider choice.
struct MacRegularSplitWidthState: Equatable {
    private var widths: [AppTab: Double]

    init(persistedValue: String?) {
        widths = [:]
        for component in persistedValue?.split(separator: ",") ?? [] {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2,
                  let tab = AppTab(rawValue: pair[0]),
                  tab.ownsRegularNestedSplit,
                  let width = Double(pair[1]),
                  width.isFinite
            else { continue }
            widths[tab] = width
        }
    }

    var persistedValue: String {
        AppTab.allCases
            .compactMap { tab -> String? in
                guard let width = widths[tab], width.isFinite else { return nil }
                return "\(tab.rawValue)=\(width)"
            }
            .joined(separator: ",")
    }

    func width(for tab: AppTab, defaultWidth: Double) -> Double {
        widths[tab] ?? defaultWidth
    }

    mutating func set(width: Double, for tab: AppTab) {
        guard tab.ownsRegularNestedSplit else { return }
        if width.isFinite {
            widths[tab] = width
        } else {
            widths[tab] = nil
        }
    }
}

private struct MacRegularListWidthBindingKey: EnvironmentKey {
    static let defaultValue = Binding<Double>.constant(.nan)
}

extension EnvironmentValues {
    var macRegularListWidth: Binding<Double> {
        get { self[MacRegularListWidthBindingKey.self] }
        set { self[MacRegularListWidthBindingKey.self] = newValue }
    }
}

// MARK: - Navigation bar title display mode

/// Shadow of SwiftUI's unavailable-on-macOS `NavigationBarItem`, carrying just
/// the enum the shared call sites name.
enum NavigationBarItem {
    enum TitleDisplayMode {
        case automatic, inline, large
    }
}

extension View {
    /// macOS has no large-title navigation bar; the toolbar title is already
    /// inline.
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }
}

// MARK: - Toolbar placements

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

// MARK: - List conveniences

extension View {
    /// SwiftUI explicitly marks `listRowSpacing` unavailable on macOS, so
    /// shared list call sites need this compile twin. Mac rows that require a
    /// measured gap use native `listRowInsets` at the row owner.
    func listRowSpacing(_ spacing: CGFloat?) -> some View { self }
}

extension ListStyle where Self == InsetListStyle {
    /// iOS's grouped inset style, read as the Mac's inset list.
    static var insetGrouped: InsetListStyle { InsetListStyle() }
}

/// Shadow of the iOS-only control. Reordering a Mac list needs no edit mode —
/// drag works directly — so the button contributes nothing.
struct EditButton: View {
    var body: some View { EmptyView() }
}

// MARK: - Text input

/// The iOS keyboard kinds named at shared call sites. There is no software
/// keyboard to configure on the Mac.
enum UIKeyboardType {
    case `default`, URL, decimalPad, numbersAndPunctuation
}

extension View {
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
}

/// Shadow of the iOS-only type; hardware keyboards do not autocapitalise.
struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

extension View {
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        self
    }
}

// MARK: - Search placement

extension SearchFieldPlacement {
    enum DrawerDisplayMode {
        case automatic, always
    }

    /// The navigation-bar drawer is an iOS shape; the Mac puts the field in
    /// the toolbar where `.automatic` already lands it.
    static func navigationBarDrawer(displayMode: DrawerDisplayMode) -> SearchFieldPlacement {
        .automatic
    }
}

// MARK: - Replay window

enum MacReplayWindowMetrics {
    static let defaultSize = CGSize(width: 1_100, height: 760)
    static let minimumSize = CGSize(width: 640, height: 480)
}

/// One native owner for one expanded replay window.
///
/// The hosted view receives the existing replay loader from its caller. This
/// controller owns presentation only: it creates no API client and performs no
/// fetch, so expanding cannot fork the replay's networking path.
@MainActor
final class MacReplayWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow

    private let onFinish: () -> Void
    private var didFinish = false

    init(title: String, onFinish: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: MacReplayWindowMetrics.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = MacReplayWindowMetrics.minimumSize
        window.isReleasedWhenClosed = false

        self.window = window
        self.onFinish = onFinish
        super.init()
        window.delegate = self
    }

    func present<Content: View>(_ content: Content) {
        window.contentViewController = NSHostingController(rootView: content)
        // Installing a hosting controller lets AppKit adopt the hosted view's
        // fitting size. Reassert the replay's native default after attachment
        // so compact SwiftUI content cannot collapse a newly opened window to
        // its minimum size.
        window.setContentSize(MacReplayWindowMetrics.defaultSize)
        show()
    }

    func show() {
        MacMenuBar.activateRegular()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.performClose(nil)
    }

    func finishOnce() {
        guard !didFinish else { return }
        didFinish = true
        onFinish()
    }

    func windowWillClose(_ notification: Notification) {
        finishOnce()
    }
}

// MARK: - Navigation transition

extension NavigationTransition where Self == AutomaticNavigationTransition {
    /// The zoom transition is iOS-only; the Mac keeps the default transition
    /// and loses nothing but motion.
    static func zoom(sourceID: some Hashable, in namespace: Namespace.ID) -> AutomaticNavigationTransition {
        .automatic
    }
}

// MARK: - Pasteboard

/// Twin of the UIKit pasteboard over `NSPasteboard`, so the nine shared
/// screens that copy text or URLs compile unchanged.
@MainActor
final class UIPasteboard {
    static let general = UIPasteboard()

    private init() {}

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            guard let newValue else { return }
            NSPasteboard.general.setString(newValue, forType: .string)
        }
    }

    var url: URL? {
        get { NSPasteboard.general.string(forType: .string).flatMap(URL.init(string:)) }
        set {
            NSPasteboard.general.clearContents()
            guard let newValue else { return }
            NSPasteboard.general.setString(newValue.absoluteString, forType: .string)
        }
    }
}

// MARK: - Excluded-file twins

/// No-op twin of the iOS home screen quick actions (the real one is
/// `App/QuickActions.swift`, excluded from this target). macOS has no home
/// screen icon menu; a Dock menu can adopt these entry points later.
@MainActor
enum QuickActions {
    static func recordPinnedDashboard(id: Int, title: String, projectID: Int) {}
    static func recordVisit(_ link: PostHogLink, title: String, projectID: Int) {}
    static func refresh(projectID: Int?) {}
    static func clear() {}
}

/// Mac twin of the iOS BGTaskScheduler wrapper (excluded from this target).
///
/// The Mac schedules through `NSBackgroundActivityScheduler` rather than
/// `BGTaskScheduler`, so this forwards to `MacBackgroundRefresh` — which is in
/// this target — instead of standing in for it. `AppModel.signOut` calls
/// `cancel()` on both platforms and needs to know nothing about either.
@MainActor
enum BackgroundRefresh {
    static func cancel() { MacBackgroundRefresh.shared.stop() }
}
#endif
